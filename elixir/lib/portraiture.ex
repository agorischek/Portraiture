defmodule Portraiture do
  @moduledoc """
  Capture stdout and stderr from external environment-collection commands,
  processes, and scripts.

  Portraiture launches a target, collects its output, applies failure policy
  (stderr policy, nonzero-exit policy, timeout), optionally parses the output,
  and returns a `Portraiture.Result` struct. Captured targets never depend on
  Portraiture; they are plain commands and scripts.

  ## Quick start

      iex> result = Portraiture.capture_command("printf hello")
      iex> result.ok
      true
      iex> result.value
      "hello"

  Use `new/1` to build a reusable configuration with defaults. Per-call
  options always override constructor defaults:

      iex> portraiture = Portraiture.new(stderr: :fail)
      iex> portraiture.stderr
      :fail

  ## Design note: the temp-file wrapper

  This implementation is deliberately zero-dependency. Erlang ports cannot
  separate a child's stdout from its stderr (`:stderr_to_stdout` merges them;
  without it, stderr leaks to the VM's tty), so Portraiture runs every target
  through a small POSIX `sh` wrapper that redirects the target's stdout and
  stderr into per-capture temporary files, records the exit status, and exits
  with it. The wrapper looks like:

      { <target>
      } < <stdin file or /dev/null> > <stdout file> 2> <stderr file>
      portraiture_status=$?
      printf '%s' "$portraiture_status" > <status file> 2> /dev/null
      exit "$portraiture_status"

  The target is wrapped in a brace group so compound commands (`;`, `&&`,
  newlines, trailing comments) and user redirections such as `>&2` behave
  exactly as they would in a terminal. Tradeoffs of this design:

  * **No live streaming.** Output is read from the files after the process
    exits (or at timeout). Logger `:stdout` / `:stderr` events are emitted
    post-mortem, not as the data arrives.
  * **No cross-stream interleaving.** `output` is stdout followed by stderr,
    and `chunks` contains at most one chunk per stream. The contract
    explicitly permits this: exact interleaving is best-effort.
  * **POSIX only.** See the Windows note below.

  In exchange, stdout and stderr are captured separately and completely with
  no NIFs, no external packages, and no risk of port data loss.

  ## Semantics and limitations

  * **`value` without a parser is the combined output string** (stdout
    followed by stderr), matching the cross-language contract. Ordering
    between the two streams is not preserved (see above).
  * **Environment variables augment the parent environment.** Variables given
    via `env:` are added to (or override entries in) the environment
    Portraiture itself was started with; the rest of the parent environment
    is inherited unchanged.
  * **Timeouts kill the OS process.** On timeout Portraiture looks up the
    wrapper's OS pid, sends `SIGTERM` to the wrapper and its descendants
    (discovered via `pgrep -P`), and escalates to `SIGKILL` after a short
    grace period. Output written before the timeout remains available on the
    result. Limitations: descendant discovery is a best-effort snapshot, so a
    target that spawns new processes at exactly the wrong moment, detaches
    into a new session, or ignores both signals between sweeps can still
    leak; `pgrep`/`kill` executables must be on `PATH` (they are on stock
    macOS and Linux).
  * **Windows is not supported.** The wrapper requires a POSIX `sh`. On
    `{:win32, _}` every capture returns a structured `:spawn` failure rather
    than attempting to run.
  * **`signal` is always `nil`.** The Erlang port API reports an exit status
    but not the terminating signal.
  * **Spawn vs exit for shell commands.** For `capture_process/2..4` and
    `capture_script/2..4` the resolved executable is checked before launch,
    and a missing or non-executable target is reported as a `:spawn` failure;
    all nonzero exits from a target that did launch are `:exit` failures
    (collectable with `fail_on_nonzero_exit: false`), including codes 126 and
    127. For `capture_command/1..3` the command string is interpreted by the
    shell, so command-not-found surfaces the way the shell reports it: an
    `:exit` failure with code 127. Only a failure to start the shell itself
    is a `:spawn` failure.
  * **There is no `shell:` option.** Command capture is inherently
    shell-interpreted and process/script capture always quotes arguments
    literally, so a shell toggle would either be a no-op or a duplicate of
    another capture method. Passing `shell:` raises `ArgumentError` instead
    of being silently ignored. (Earlier revisions accepted and ignored it.)
  * **No struct-level blanket `interpreter:` default.** The contract
    describes per-call interpreters and by-extension defaults; a
    configuration-wide interpreter applied to every script is neither, so it
    was removed. Use per-call `interpreter:` or the `interpreters:` map.

  ## Options

  Constructor defaults (`new/1`) and per-call options share these keys:

  * `:cwd` — working directory for the launched process only.
  * `:env` — map or keyword of environment variables (augment semantics).
  * `:fail_on_nonzero_exit` — default `true`; set `false` to collect nonzero
    exits as data.
  * `:logger` — a 1-arity function receiving lifecycle event maps
    (`:start`, `:stdout`, `:stderr`, `:finish`). Logger crashes never change
    the capture result. Stream events are emitted post-mortem.
  * `:parse_input` — `:stdout` (default), `:stderr`, or `:combined`.
  * `:stderr` — `:capture` (default) or `:fail`.
  * `:stdin` — text written to the target's standard input. When absent,
    stdin is redirected from `/dev/null` so stdin-reading targets do not
    hang.
  * `:timeout_ms` — positive integer milliseconds.
  * `:interpreters` — map of file extension (with or without the leading
    dot) to interpreter, used by `capture_script` when no per-call
    `interpreter:` is given.

  Per-call only:

  * `:parser` — a 1-arity (`text`) or 2-arity (`text, context`) function.
    Parsers may return `{:ok, value}`, `{:error, reason}`, or a raw value;
    raised exceptions become `:parse` failures.
  * `:interpreter` — script capture only; `%{command: ..., args: [...]}`, a
    command string, or a `{command, args}` tuple.

  Unknown option keys raise `ArgumentError`.
  """

  alias Portraiture.{Failure, Result}

  defstruct cwd: nil,
            env: nil,
            fail_on_nonzero_exit: true,
            logger: nil,
            parse_input: :stdout,
            stderr: :capture,
            stdin: nil,
            timeout_ms: nil,
            interpreters: %{}

  @typedoc "What kind of target a capture launched."
  @type target_kind :: :command | :process | :script

  @typedoc "An output stream name."
  @type stream :: :stdout | :stderr

  @typedoc "Which captured text is handed to the parser."
  @type parse_input :: :stdout | :stderr | :combined

  @typedoc "How non-empty stderr is treated."
  @type stderr_policy :: :capture | :fail

  @typedoc "A best-effort output chunk."
  @type chunk :: %{stream: stream(), text: String.t()}

  @typedoc "A normalized script interpreter."
  @type interpreter :: %{command: String.t(), args: [String.t()]}

  @typedoc "Anything accepted where an interpreter is expected."
  @type interpreter_spec ::
          interpreter() | String.t() | {String.t(), [String.t()]} | %{command: String.t()}

  @typedoc "Metadata describing what a capture launched."
  @type target :: %{
          optional(:script) => String.t(),
          optional(:interpreter) => interpreter(),
          kind: target_kind(),
          command: String.t(),
          args: [String.t()]
        }

  @typedoc "A lifecycle event map passed to the logger function."
  @type logger_event :: %{required(:type) => :start | :stdout | :stderr | :finish, optional(atom()) => term()}

  @typedoc "A per-call parser function."
  @type parser :: (String.t() -> term()) | (String.t(), map() -> term())

  @typedoc "Per-call capture options as a keyword list or plain map."
  @type options :: keyword() | %{optional(atom()) => term()}

  @type t :: %__MODULE__{
          cwd: String.t() | nil,
          env: Enumerable.t() | nil,
          fail_on_nonzero_exit: boolean(),
          logger: (logger_event() -> any()) | nil,
          parse_input: parse_input(),
          stderr: stderr_policy(),
          stdin: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          interpreters: %{optional(String.t() | atom()) => interpreter_spec()}
        }

  @common_option_keys [
    :cwd,
    :env,
    :fail_on_nonzero_exit,
    :logger,
    :parse_input,
    :parser,
    :stderr,
    :stdin,
    :timeout_ms
  ]
  @script_option_keys @common_option_keys ++ [:interpreter, :interpreters]

  @kill_grace_ms 500

  defguardp is_options(opts) when is_list(opts) or (is_map(opts) and not is_struct(opts))

  @doc """
  Builds a reusable Portraiture configuration.

  Accepts the shared option keys documented in the module docs. Unknown keys
  raise (via `struct!/2`).

  ## Examples

      iex> portraiture = Portraiture.new(cwd: "/tmp", timeout_ms: 5_000)
      iex> portraiture.timeout_ms
      5000
  """
  @spec new(options()) :: t()
  def new(opts \\ []) when is_options(opts) do
    struct!(__MODULE__, normalize_options(opts))
  end

  @doc """
  Runs a shell command string and captures its output.

  The string is interpreted by `/bin/sh`, so pipes, redirections, compound
  commands, and comments behave as they would in a terminal.

  ## Examples

      iex> result = Portraiture.capture_command("printf hello")
      iex> {result.ok, result.value, result.exit_code}
      {true, "hello", 0}
  """
  @spec capture_command(String.t()) :: Result.t()
  def capture_command(command) when is_binary(command) do
    capture_command(new(), command, [])
  end

  @doc """
  Runs a shell command string with per-call options, or with a `Portraiture`
  configuration when the first argument is a struct built by `new/1`.
  """
  @spec capture_command(t() | String.t(), String.t() | options()) :: Result.t()
  def capture_command(%__MODULE__{} = portraiture, command) when is_binary(command) do
    capture_command(portraiture, command, [])
  end

  def capture_command(command, opts) when is_binary(command) and is_options(opts) do
    capture_command(new(), command, opts)
  end

  def capture_command(command, opts) when is_binary(command) do
    raise_options_error(opts)
  end

  @doc """
  Runs a shell command string using a `Portraiture` configuration plus
  per-call options. Per-call options override configuration defaults.
  """
  @spec capture_command(t(), String.t(), options()) :: Result.t()
  def capture_command(%__MODULE__{} = portraiture, command, opts)
      when is_binary(command) and is_options(opts) do
    call_options = normalize_call_options!(opts, :command)
    target = %{kind: :command, command: command, args: []}
    run_capture(portraiture, target, call_options)
  end

  def capture_command(%__MODULE__{}, command, opts) when is_binary(command) do
    raise_options_error(opts)
  end

  @doc """
  Runs an executable with literal arguments, without shell interpretation of
  the arguments.
  """
  @spec capture_process(String.t()) :: Result.t()
  def capture_process(program) when is_binary(program) do
    capture_process(new(), program, [], [])
  end

  @doc """
  Runs an executable with literal arguments (`capture_process(program, args)`).
  """
  @spec capture_process(String.t(), [term()]) :: Result.t()
  def capture_process(program, args) when is_binary(program) and is_list(args) do
    capture_process(new(), program, args, [])
  end

  def capture_process(program, args) when is_binary(program) do
    raise_args_error(args)
  end

  @doc """
  Runs an executable with literal arguments and per-call options, or with a
  `Portraiture` configuration when the first argument is a struct.
  """
  @spec capture_process(t() | String.t(), String.t() | [term()], [term()] | options()) ::
          Result.t()
  def capture_process(%__MODULE__{} = portraiture, program, args)
      when is_binary(program) and is_list(args) do
    capture_process(portraiture, program, args, [])
  end

  def capture_process(%__MODULE__{}, program, args) when is_binary(program) do
    raise_args_error(args)
  end

  def capture_process(program, args, opts)
      when is_binary(program) and is_list(args) and is_options(opts) do
    capture_process(new(), program, args, opts)
  end

  def capture_process(program, args, opts) when is_binary(program) and is_list(args) do
    raise_options_error(opts)
  end

  def capture_process(program, args, _opts) when is_binary(program) do
    raise_args_error(args)
  end

  @doc """
  Runs an executable with literal arguments using a `Portraiture`
  configuration plus per-call options.
  """
  @spec capture_process(t(), String.t(), [term()], options()) :: Result.t()
  def capture_process(%__MODULE__{} = portraiture, program, args, opts)
      when is_binary(program) and is_list(args) and is_options(opts) do
    call_options = normalize_call_options!(opts, :process)
    target = %{kind: :process, command: program, args: Enum.map(args, &to_string/1)}
    run_capture(portraiture, target, call_options)
  end

  def capture_process(%__MODULE__{}, program, args, opts)
      when is_binary(program) and is_list(args) do
    raise_options_error(opts)
  end

  def capture_process(%__MODULE__{}, program, args, _opts) when is_binary(program) do
    raise_args_error(args)
  end

  @doc """
  Runs a script file directly. The file should be executable and carry an
  appropriate shebang; use the `interpreter:` option or configured
  `interpreters:` defaults to launch it through a specific runtime instead.
  """
  @spec capture_script(String.t()) :: Result.t()
  def capture_script(path) when is_binary(path) do
    capture_script(new(), path, [], [])
  end

  @doc """
  Runs a script file with arguments (`capture_script(path, args)`).
  """
  @spec capture_script(String.t(), [term()]) :: Result.t()
  def capture_script(path, args) when is_binary(path) and is_list(args) do
    capture_script(new(), path, args, [])
  end

  def capture_script(path, args) when is_binary(path) do
    raise_args_error(args)
  end

  @doc """
  Runs a script file with arguments and per-call options, or with a
  `Portraiture` configuration when the first argument is a struct.
  """
  @spec capture_script(t() | String.t(), String.t() | [term()], [term()] | options()) ::
          Result.t()
  def capture_script(%__MODULE__{} = portraiture, path, args)
      when is_binary(path) and is_list(args) do
    capture_script(portraiture, path, args, [])
  end

  def capture_script(%__MODULE__{}, path, args) when is_binary(path) do
    raise_args_error(args)
  end

  def capture_script(path, args, opts)
      when is_binary(path) and is_list(args) and is_options(opts) do
    capture_script(new(), path, args, opts)
  end

  def capture_script(path, args, opts) when is_binary(path) and is_list(args) do
    raise_options_error(opts)
  end

  def capture_script(path, args, _opts) when is_binary(path) do
    raise_args_error(args)
  end

  @doc """
  Runs a script file using a `Portraiture` configuration plus per-call
  options. Interpreter resolution order: per-call `interpreter:`, then the
  merged `interpreters:` by-extension maps (per-call entries win), then
  direct execution.
  """
  @spec capture_script(t(), String.t(), [term()], options()) :: Result.t()
  def capture_script(%__MODULE__{} = portraiture, path, args, opts)
      when is_binary(path) and is_list(args) and is_options(opts) do
    call_options = normalize_call_options!(opts, :script)
    target = script_target(portraiture, path, Enum.map(args, &to_string/1), call_options)
    run_capture(portraiture, target, call_options)
  end

  def capture_script(%__MODULE__{}, path, args, opts)
      when is_binary(path) and is_list(args) do
    raise_options_error(opts)
  end

  def capture_script(%__MODULE__{}, path, args, _opts) when is_binary(path) do
    raise_args_error(args)
  end

  ## Capture pipeline

  defp run_capture(%__MODULE__{} = portraiture, target, call_options) do
    options = resolve_options(portraiture, call_options)
    started_at = System.monotonic_time(:millisecond)
    log(options.logger, %{type: :start, target: target})

    case preflight(target, options) do
      {:error, message} ->
        fail(target, options.logger, empty_context(started_at), :spawn, message, nil)

      :ok ->
        case run_target(target, options) do
          {:ok, raw} ->
            context = capture_context(raw, started_at)
            emit_stream_logs(options.logger, target, context)
            finish(target, options, context)

          {:error, :spawn, error} ->
            context = empty_context(started_at)
            fail(target, options.logger, context, :spawn, Exception.message(error), error)

          {:error, :timeout, raw} ->
            context = capture_context(raw, started_at)
            emit_stream_logs(options.logger, target, context)

            fail(
              target,
              options.logger,
              context,
              :timeout,
              "Capture timed out after #{options.timeout_ms} ms.",
              nil
            )
        end
    end
  end

  defp preflight(target, options) do
    case :os.type() do
      {:win32, _} ->
        {:error,
         "Portraiture's Elixir implementation requires a POSIX shell and is not supported on Windows."}

      _ ->
        check_executable(target, options)
    end
  end

  # :command strings are interpreted by the shell; the shell reports missing
  # commands itself (exit 127), which surfaces as an :exit failure.
  defp check_executable(%{kind: :command}, _options), do: :ok

  defp check_executable(%{command: command}, options) do
    if String.contains?(command, "/") do
      path = Path.expand(command, options.cwd || File.cwd!())

      cond do
        not File.regular?(path) ->
          {:error, "Capture target not found: #{command}"}

        not executable_file?(path) ->
          {:error, "Capture target is not executable: #{command}"}

        true ->
          :ok
      end
    else
      case System.find_executable(command) do
        nil -> {:error, "Capture target not found on PATH: #{command}"}
        _path -> :ok
      end
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp finish(target, options, context) do
    cond do
      options.stderr == :fail and context.stderr != "" ->
        fail(target, options.logger, context, :stderr, "Capture wrote to stderr.", nil)

      options.fail_on_nonzero_exit and context.exit_code not in [nil, 0] ->
        fail(
          target,
          options.logger,
          context,
          :exit,
          "Capture exited with code #{context.exit_code}.",
          nil
        )

      true ->
        parse(target, options, context)
    end
  end

  defp parse(target, options, context) do
    case options.parser do
      nil ->
        # Without a parser, value is the combined output string.
        succeed(target, options.logger, context, context.output)

      parser ->
        input = parser_input(context, options.parse_input)

        case run_parser(parser, input, context) do
          {:ok, value} ->
            succeed(target, options.logger, context, value)

          {:error, reason} ->
            fail(target, options.logger, context, :parse, parse_message(reason), reason)
        end
    end
  end

  ## Process execution

  defp run_target(target, options) do
    temporary_directory = temporary_directory()
    File.mkdir_p!(temporary_directory)

    paths = %{
      stdout: Path.join(temporary_directory, "stdout"),
      stderr: Path.join(temporary_directory, "stderr"),
      status: Path.join(temporary_directory, "status"),
      stdin: Path.join(temporary_directory, "stdin")
    }

    if is_binary(options.stdin) do
      File.write!(paths.stdin, options.stdin)
    end

    script = wrapper_script(target, paths, is_binary(options.stdin))

    port_options =
      [
        :binary,
        :exit_status,
        # Route the wrapper shell's own diagnostics (syntax errors and the
        # like) into port data instead of leaking them to the host tty.
        :stderr_to_stdout,
        {:args, [~c"-c", to_charlist(script)]}
      ] ++ cd_option(options.cwd) ++ env_option(options.env)

    try do
      port = Port.open({:spawn_executable, ~c"/bin/sh"}, port_options)
      os_pid = port_os_pid(port)

      case wait_for_port(port, options.timeout_ms) do
        {:ok, port_status, diagnostics} ->
          {:ok, read_raw_capture(paths, port_status, diagnostics)}

        {:timeout, diagnostics} ->
          # Kill the wrapper and its descendants, and only read/delete the
          # temp files once the process tree is dead.
          kill_process_tree(port, os_pid)
          raw = read_raw_capture(paths, nil, diagnostics)
          close_port(port)
          flush_port(port)
          {:error, :timeout, raw}
      end
    rescue
      error in ErlangError ->
        {:error, :spawn, error}
    after
      File.rm_rf(temporary_directory)
    end
  end

  defp wrapper_script(target, paths, has_stdin?) do
    stdin_source = if has_stdin?, do: shell_quote(paths.stdin), else: "/dev/null"

    # The brace group makes compound commands, trailing comments, and user
    # redirections (such as `>&2`) behave exactly as in a terminal, while the
    # group-level redirections capture the streams into files.
    """
    { #{target_line(target)}
    } < #{stdin_source} > #{shell_quote(paths.stdout)} 2> #{shell_quote(paths.stderr)}
    portraiture_status=$?
    printf '%s' "$portraiture_status" > #{shell_quote(paths.status)} 2> /dev/null
    exit "$portraiture_status"
    """
  end

  defp target_line(%{kind: :command, command: command}), do: command

  defp target_line(%{command: command, args: args}) do
    Enum.map_join([command | args], " ", &shell_quote/1)
  end

  defp wait_for_port(port, timeout_ms) do
    deadline =
      if is_integer(timeout_ms) do
        System.monotonic_time(:millisecond) + timeout_ms
      end

    wait_for_port(port, deadline, [])
  end

  defp wait_for_port(port, deadline, data) do
    remaining =
      case deadline do
        nil -> :infinity
        deadline -> max(deadline - System.monotonic_time(:millisecond), 0)
      end

    receive do
      {^port, {:exit_status, status}} -> {:ok, status, collected_data(data)}
      {^port, {:data, chunk}} -> wait_for_port(port, deadline, [chunk | data])
    after
      remaining -> {:timeout, collected_data(data)}
    end
  end

  defp collected_data(data) do
    data |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  defp kill_process_tree(_port, nil), do: :ok

  defp kill_process_tree(port, os_pid) do
    signal_tree(os_pid, "TERM")

    unless wait_for_exit(port, @kill_grace_ms) do
      signal_tree(os_pid, "KILL")
      wait_for_exit(port, @kill_grace_ms)
    end

    :ok
  end

  defp wait_for_exit(port, grace_ms) do
    receive do
      {^port, {:exit_status, _status}} -> true
    after
      grace_ms -> false
    end
  end

  defp signal_tree(os_pid, signal) do
    pids = descendant_pids(os_pid) ++ [os_pid]

    Enum.each(pids, fn pid ->
      safe_cmd("kill", ["-s", signal, Integer.to_string(pid)])
    end)
  end

  defp descendant_pids(os_pid) do
    case safe_cmd("pgrep", ["-P", Integer.to_string(os_pid)]) do
      {:ok, output} ->
        children =
          output
          |> String.split(~r/\s+/, trim: true)
          |> Enum.flat_map(fn token ->
            case Integer.parse(token) do
              {pid, ""} -> [pid]
              _ -> []
            end
          end)

        Enum.flat_map(children, &descendant_pids/1) ++ children

      :error ->
        []
    end
  end

  defp safe_cmd(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp read_raw_capture(paths, fallback_status, diagnostics) do
    %{
      stdout: read_file(paths.stdout),
      stderr: read_file(paths.stderr) <> diagnostics,
      exit_code: read_exit_code(paths.status, fallback_status)
    }
  end

  ## Context and results

  defp capture_context(raw, started_at) do
    chunks =
      []
      |> append_chunk(:stdout, raw.stdout)
      |> append_chunk(:stderr, raw.stderr)

    %{
      stdout: raw.stdout,
      stderr: raw.stderr,
      output: raw.stdout <> raw.stderr,
      chunks: chunks,
      exit_code: raw.exit_code,
      signal: nil,
      duration_ms: System.monotonic_time(:millisecond) - started_at
    }
  end

  defp empty_context(started_at) do
    %{
      stdout: "",
      stderr: "",
      output: "",
      chunks: [],
      exit_code: nil,
      signal: nil,
      duration_ms: System.monotonic_time(:millisecond) - started_at
    }
  end

  defp succeed(target, logger, context, value) do
    result = build_result(target, context, true, value, nil)
    log(logger, finish_event(target, result))
    result
  end

  defp fail(target, logger, context, kind, message, cause) do
    error = %Failure{kind: kind, message: message, cause: cause}
    result = build_result(target, context, false, nil, error)
    log(logger, finish_event(target, result))
    result
  end

  defp build_result(target, context, ok, value, error) do
    %Result{
      ok: ok,
      value: value,
      error: error,
      stdout: context.stdout,
      stderr: context.stderr,
      output: context.output,
      chunks: context.chunks,
      exit_code: context.exit_code,
      signal: context.signal,
      duration_ms: context.duration_ms,
      target: target
    }
  end

  defp finish_event(target, result) do
    %{
      type: :finish,
      target: target,
      ok: result.ok,
      duration_ms: result.duration_ms,
      exit_code: result.exit_code,
      signal: result.signal
    }
  end

  # Stream log events are emitted after the process exits; this
  # implementation does not stream output live (see the module docs).
  defp emit_stream_logs(logger, target, context) do
    Enum.each(context.chunks, fn chunk ->
      log(logger, %{type: chunk.stream, target: target, text: chunk.text})
    end)
  end

  defp log(nil, _event), do: :ok

  defp log(logger, event) when is_function(logger, 1) do
    logger.(event)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  ## Parsing

  defp run_parser(parser, input, context) do
    raw =
      cond do
        is_function(parser, 1) -> parser.(input)
        is_function(parser, 2) -> parser.(input, context)
      end

    case raw do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      value -> {:ok, value}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp parse_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp parse_message(reason), do: inspect(reason)

  defp parser_input(context, :combined), do: context.output
  defp parser_input(context, :stderr), do: context.stderr
  defp parser_input(context, :stdout), do: context.stdout

  ## Script interpreters

  defp script_target(portraiture, path, args, call_options) do
    case resolve_interpreter(portraiture, path, call_options) do
      nil ->
        %{kind: :script, command: path, args: args, script: path}

      interpreter ->
        %{
          kind: :script,
          command: interpreter.command,
          args: interpreter.args ++ [path] ++ args,
          script: path,
          interpreter: interpreter
        }
    end
  end

  defp resolve_interpreter(portraiture, path, call_options) do
    case Map.get(call_options, :interpreter) do
      nil ->
        extension = Path.extname(path)
        extension_without_dot = String.trim_leading(extension, ".")

        interpreters =
          Map.merge(
            normalize_interpreter_map(portraiture.interpreters),
            normalize_interpreter_map(Map.get(call_options, :interpreters))
          )

        interpreter =
          Map.get(interpreters, extension) || Map.get(interpreters, extension_without_dot)

        normalize_interpreter(interpreter)

      interpreter ->
        normalize_interpreter(interpreter)
    end
  end

  defp normalize_interpreter_map(nil), do: %{}

  defp normalize_interpreter_map(interpreters) do
    Map.new(interpreters, fn {extension, interpreter} -> {to_string(extension), interpreter} end)
  end

  defp normalize_interpreter(nil), do: nil

  defp normalize_interpreter(command) when is_binary(command) do
    %{command: command, args: []}
  end

  defp normalize_interpreter({command, args}) when is_binary(command) and is_list(args) do
    %{command: command, args: Enum.map(args, &to_string/1)}
  end

  defp normalize_interpreter(%{command: command} = interpreter) when is_binary(command) do
    %{command: command, args: Enum.map(Map.get(interpreter, :args, []), &to_string/1)}
  end

  ## Options

  defp resolve_options(%__MODULE__{} = portraiture, call_options) do
    %{
      cwd: option(portraiture.cwd, Map.get(call_options, :cwd)),
      env: merge_env(portraiture.env, Map.get(call_options, :env)),
      fail_on_nonzero_exit:
        option(portraiture.fail_on_nonzero_exit, Map.get(call_options, :fail_on_nonzero_exit)),
      logger: option(portraiture.logger, Map.get(call_options, :logger)),
      parse_input: option(portraiture.parse_input, Map.get(call_options, :parse_input)) || :stdout,
      parser: Map.get(call_options, :parser),
      stderr: option(portraiture.stderr, Map.get(call_options, :stderr)) || :capture,
      stdin: option(portraiture.stdin, Map.get(call_options, :stdin)),
      timeout_ms: option(portraiture.timeout_ms, Map.get(call_options, :timeout_ms))
    }
  end

  defp option(default, nil), do: default
  defp option(_default, value), do: value

  defp normalize_call_options!(opts, kind) do
    options = normalize_options(opts)

    allowed =
      case kind do
        :script -> @script_option_keys
        _ -> @common_option_keys
      end

    case Map.keys(options) -- allowed do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown capture option(s) #{inspect(unknown)} for #{kind} capture; " <>
                "allowed options are #{inspect(allowed)}"
    end

    validate_option_values!(options)
    options
  end

  defp validate_option_values!(options) do
    parse_input = Map.get(options, :parse_input)

    if parse_input != nil and parse_input not in [:stdout, :stderr, :combined] do
      raise ArgumentError,
            "invalid :parse_input #{inspect(parse_input)}; expected :stdout, :stderr, or :combined"
    end

    stderr = Map.get(options, :stderr)

    if stderr != nil and stderr not in [:capture, :fail] do
      raise ArgumentError, "invalid :stderr policy #{inspect(stderr)}; expected :capture or :fail"
    end

    parser = Map.get(options, :parser)

    if parser != nil and not is_function(parser, 1) and not is_function(parser, 2) do
      raise ArgumentError,
            "invalid :parser #{inspect(parser)}; expected a 1-arity (text) or 2-arity (text, context) function"
    end

    timeout_ms = Map.get(options, :timeout_ms)

    if timeout_ms != nil and (not is_integer(timeout_ms) or timeout_ms <= 0) do
      raise ArgumentError,
            "invalid :timeout_ms #{inspect(timeout_ms)}; expected a positive integer"
    end

    :ok
  end

  defp normalize_options(opts) when is_options(opts), do: Map.new(opts)

  @spec raise_options_error(term()) :: no_return()
  defp raise_options_error(opts) do
    raise ArgumentError,
          "capture options must be a keyword list or map, got: #{inspect(opts)}"
  end

  @spec raise_args_error(term()) :: no_return()
  defp raise_args_error(args) do
    raise ArgumentError,
          "capture arguments must be a list of strings, got: #{inspect(args)}"
  end

  ## Environment

  defp merge_env(defaults, overrides) do
    defaults = normalize_env(defaults)
    overrides = normalize_env(overrides)

    cond do
      defaults == nil and overrides == nil -> nil
      defaults == nil -> overrides
      overrides == nil -> defaults
      true -> Map.merge(defaults, overrides)
    end
  end

  defp normalize_env(nil), do: nil

  defp normalize_env(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  # Port {:env, ...} augments the parent environment: listed variables are
  # added or overridden, everything else is inherited.
  defp env_option(nil), do: []

  defp env_option(env) do
    [{:env, Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)}]
  end

  defp cd_option(nil), do: []
  defp cd_option(cwd), do: [{:cd, to_charlist(cwd)}]

  ## Small helpers

  defp append_chunk(chunks, _stream, ""), do: chunks
  defp append_chunk(chunks, stream, text), do: chunks ++ [%{stream: stream, text: text}]

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  defp read_exit_code(path, fallback_status) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.trim()
        |> Integer.parse()
        |> case do
          {code, ""} -> code
          _ -> fallback_status
        end

      {:error, _} ->
        fallback_status
    end
  end

  defp temporary_directory do
    Path.join(System.tmp_dir!(), "portraiture-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
