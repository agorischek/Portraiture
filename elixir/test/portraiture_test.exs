defmodule PortraitureTest do
  use ExUnit.Case, async: true

  doctest Portraiture

  @moduletag :tmp_dir

  defp find!(name), do: System.find_executable(name) || flunk("#{name} not found on PATH")

  defp write_script(directory, name, contents, mode \\ 0o700) do
    path = Path.join(directory, name)
    File.write!(path, contents)
    File.chmod!(path, mode)
    path
  end

  defp alive?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  defp eventually_dead?(os_pid, attempts \\ 40) do
    cond do
      not alive?(os_pid) -> true
      attempts <= 0 -> false
      true ->
        Process.sleep(50)
        eventually_dead?(os_pid, attempts - 1)
    end
  end

  describe "capture_command/1..3" do
    test "captures stdout and returns structs" do
      result = Portraiture.capture_command("printf hello")

      assert %Portraiture.Result{} = result
      assert result.ok
      assert result.value == "hello"
      assert result.stdout == "hello"
      assert result.stderr == ""
      assert result.output == "hello"
      assert result.exit_code == 0
      assert result.signal == nil
      assert is_integer(result.duration_ms) and result.duration_ms >= 0
      assert result.target.kind == :command
      assert result.error == nil
    end

    test "value without a parser is the combined output string" do
      result = Portraiture.capture_command("printf out; printf err >&2")

      assert result.ok
      assert result.stdout == "out"
      assert result.stderr == "err"
      assert result.value == "outerr"
      assert result.value == result.output
    end

    test "compound commands and user redirections are fully captured" do
      result = Portraiture.capture_command("printf one; printf two && printf three >&2")

      assert result.ok
      assert result.stdout == "onetwo"
      assert result.stderr == "three"
    end

    test "trailing comments do not swallow the capture redirections" do
      result = Portraiture.capture_command("echo hi # note")

      assert result.ok
      assert result.stdout == "hi\n"
      assert result.value == "hi\n"
    end
  end

  describe "capture_process/1..4" do
    test "passes literal args without shell interpretation" do
      result = Portraiture.capture_process(find!("printf"), ["%s", "hello; echo nope"])

      assert result.ok
      assert result.value == "hello; echo nope"
      assert result.target.kind == :process
    end

    test "bare program names are resolved on PATH" do
      result = Portraiture.capture_process("printf", ["%s", "bare"])

      assert result.ok
      assert result.value == "bare"
    end
  end

  describe "capture_script/1..4" do
    test "runs an executable script directly with no interpreter", %{tmp_dir: tmp_dir} do
      script =
        write_script(tmp_dir, "direct.sh", """
        #!/bin/sh
        printf 'direct:%s' "$1"
        """)

      result = Portraiture.capture_script(script, ["one"])

      assert result.ok
      assert result.value == "direct:one"
      assert result.target.kind == :script
      assert result.target.command == script
      assert result.target.script == script
      refute Map.has_key?(result.target, :interpreter)
    end

    test "supports an explicit interpreter", %{tmp_dir: tmp_dir} do
      script = write_script(tmp_dir, "explicit.portraiture-sh", "printf \"$1\"")

      result =
        Portraiture.capture_script(script, ["via-interpreter"],
          interpreter: %{command: "/bin/sh", args: []}
        )

      assert result.ok
      assert result.value == "via-interpreter"
      assert result.target.command == "/bin/sh"
      assert result.target.script == script
    end

    test "reusable config supports default interpreters by extension", %{tmp_dir: tmp_dir} do
      script = write_script(tmp_dir, "default.portraiture-sh", "printf \"$1\"")

      portraiture =
        Portraiture.new(
          interpreters: %{
            "portraiture-sh" => %{command: "/bin/sh", args: []}
          }
        )

      result = Portraiture.capture_script(portraiture, script, ["from-default"])

      assert result.ok
      assert result.value == "from-default"
      assert result.target.command == "/bin/sh"
    end

    test "per-call interpreters map overrides configured defaults", %{tmp_dir: tmp_dir} do
      script = write_script(tmp_dir, "override.psh", "printf 'per-call'")

      portraiture =
        Portraiture.new(interpreters: %{".psh" => %{command: "/nonexistent/interpreter"}})

      result =
        Portraiture.capture_script(portraiture, script, [],
          interpreters: %{".psh" => %{command: "/bin/sh", args: []}}
        )

      assert result.ok
      assert result.value == "per-call"
    end
  end

  describe "parsers" do
    test "parser reads stdout by default" do
      result =
        Portraiture.capture_command("printf '{\"hostname\":\"local\"}'",
          parser: fn text, _context ->
            if String.contains?(text, "\"hostname\":\"local\"") do
              {:ok, %{hostname: "local"}}
            else
              {:error, :bad_json}
            end
          end
        )

      assert result.ok
      assert result.value.hostname == "local"
    end

    test "arity-1 parsers receive just the text" do
      result = Portraiture.capture_command("printf hello", parser: fn text -> String.upcase(text) end)

      assert result.ok
      assert result.value == "HELLO"
    end

    test "parse_input can parse combined output" do
      result =
        Portraiture.capture_command("printf out; printf err >&2",
          parse_input: :combined,
          parser: fn text, _context -> text end
        )

      assert result.ok
      assert result.value == "outerr"
    end

    test "parse_input can parse stderr" do
      result =
        Portraiture.capture_command("printf out; printf err >&2",
          parse_input: :stderr,
          parser: fn text -> text end
        )

      assert result.ok
      assert result.value == "err"
    end

    test "parser {:error, _} returns parse failures" do
      result =
        Portraiture.capture_command("printf not-json",
          parser: fn _text, _context -> {:error, :nope} end
        )

      refute result.ok
      assert %Portraiture.Failure{} = result.error
      assert result.error.kind == :parse
      assert result.error.cause == :nope
      assert result.stdout == "not-json"
    end

    test "raising parsers return parse failures" do
      result =
        Portraiture.capture_command("printf not-json",
          parser: fn _text, _context -> raise "boom" end
        )

      refute result.ok
      assert result.error.kind == :parse
      assert result.error.message =~ "boom"
      assert %RuntimeError{} = result.error.cause
      assert result.stdout == "not-json"
    end
  end

  describe "stderr policy" do
    test "stderr is captured as data by default" do
      result = Portraiture.capture_command("printf warn >&2")

      assert result.ok
      assert result.stderr == "warn"
    end

    test "stderr can be promoted to failure and stays available" do
      result = Portraiture.capture_command("printf warn >&2", stderr: :fail)

      refute result.ok
      assert result.error.kind == :stderr
      assert result.stderr == "warn"
      assert result.stdout == ""
    end
  end

  describe "exit policy" do
    test "nonzero exits fail by default and preserve output" do
      result = Portraiture.capture_command("printf before; printf bad >&2; exit 7")

      refute result.ok
      assert result.error.kind == :exit
      assert result.exit_code == 7
      assert result.stdout == "before"
      assert result.stderr == "bad"
    end

    test "nonzero exits can be collected as successful data" do
      result = Portraiture.capture_command("printf data; exit 7", fail_on_nonzero_exit: false)

      assert result.ok
      assert result.exit_code == 7
      assert result.value == "data"
    end

    test "command-not-found inside the shell is exit 127, not spawn" do
      result = Portraiture.capture_command("definitely_missing_portraiture_command_xyz")

      refute result.ok
      assert result.error.kind == :exit
      assert result.exit_code == 127
    end

    test "exit codes 126 and 127 can be collected as data" do
      missing =
        Portraiture.capture_command("definitely_missing_portraiture_command_xyz",
          fail_on_nonzero_exit: false
        )

      assert missing.ok
      assert missing.exit_code == 127
      assert missing.stderr =~ "definitely_missing_portraiture_command_xyz"
    end

    test "non-executable command targets exit 126 and can be collected", %{tmp_dir: tmp_dir} do
      script = write_script(tmp_dir, "not-executable.sh", "printf nope", 0o600)

      result =
        Portraiture.capture_command(Portraiture.new(), "'#{script}'",
          fail_on_nonzero_exit: false
        )

      assert result.ok
      assert result.exit_code == 126
    end
  end

  describe "spawn failures" do
    test "missing process executables return spawn failures" do
      result = Portraiture.capture_process("__portraiture_missing_executable__", [])

      refute result.ok
      assert result.error.kind == :spawn
      assert result.error.message =~ "__portraiture_missing_executable__"
      assert result.exit_code == nil
    end

    test "missing script paths return spawn failures", %{tmp_dir: tmp_dir} do
      result = Portraiture.capture_script(Path.join(tmp_dir, "missing.sh"))

      refute result.ok
      assert result.error.kind == :spawn
    end

    test "non-executable script files return spawn failures", %{tmp_dir: tmp_dir} do
      script = write_script(tmp_dir, "plain.sh", "printf nope", 0o600)
      result = Portraiture.capture_script(script)

      refute result.ok
      assert result.error.kind == :spawn
      assert result.error.message =~ "not executable"
    end

    test "spawn failures emit failure log events" do
      parent = self()

      result =
        Portraiture.capture_process("__portraiture_missing_executable__", [],
          logger: fn event -> send(parent, {:event, event}) end
        )

      refute result.ok
      assert_received {:event, %{type: :start}}
      assert_received {:event, %{type: :finish, ok: false}}
    end
  end

  describe "timeouts" do
    test "timeouts return timeout failures" do
      result = Portraiture.capture_command("sleep 5", timeout_ms: 50)

      refute result.ok
      assert result.error.kind == :timeout
      assert result.error.message =~ "50"
    end

    test "output produced before the timeout remains available" do
      result = Portraiture.capture_command("printf started; sleep 5", timeout_ms: 300)

      refute result.ok
      assert result.error.kind == :timeout
      assert result.stdout == "started"
    end

    test "timeout kills the spawned process tree", %{tmp_dir: tmp_dir} do
      pidfile = Path.join(tmp_dir, "sleep.pid")

      result =
        Portraiture.capture_command("sleep 30 & echo $! > '#{pidfile}'; wait", timeout_ms: 300)

      refute result.ok
      assert result.error.kind == :timeout

      os_pid = pidfile |> File.read!() |> String.trim() |> String.to_integer()
      assert eventually_dead?(os_pid), "expected process #{os_pid} to be killed after timeout"
    end
  end

  describe "stdin" do
    test "stdin is sent to the process" do
      result = Portraiture.capture_process(find!("cat"), [], stdin: "hello stdin")

      assert result.ok
      assert result.value == "hello stdin"
    end

    test "stdin-reading targets return when no stdin is given" do
      result = Portraiture.capture_process(find!("cat"), [], timeout_ms: 5_000)

      assert result.ok
      assert result.value == ""
    end
  end

  describe "environment" do
    test "per-call env augments the parent environment" do
      result =
        Portraiture.capture_command("printf '%s|%s' \"$PORTRAITURE_TEST_VAR\" \"$PATH\"",
          env: %{"PORTRAITURE_TEST_VAR" => "augmented"}
        )

      assert result.ok
      assert [value, path] = String.split(result.value, "|", parts: 2)
      assert value == "augmented"
      assert path != "", "expected the parent PATH to be preserved"
    end

    test "constructor env merges with per-call env, per-call winning" do
      portraiture =
        Portraiture.new(env: %{"PORTRAITURE_A" => "default-a", "PORTRAITURE_B" => "default-b"})

      result =
        Portraiture.capture_command(portraiture, "printf '%s %s' \"$PORTRAITURE_A\" \"$PORTRAITURE_B\"",
          env: %{"PORTRAITURE_A" => "override-a"}
        )

      assert result.ok
      assert result.value == "override-a default-b"
    end
  end

  describe "logging" do
    test "logger receives lifecycle and stream events" do
      parent = self()

      result =
        Portraiture.capture_command("printf out; printf err >&2",
          logger: fn event -> send(parent, {:event, event.type}) end
        )

      assert result.ok
      assert_received {:event, :start}
      assert_received {:event, :stdout}
      assert_received {:event, :stderr}
      assert_received {:event, :finish}
    end

    test "logger exceptions do not change the capture result" do
      result =
        Portraiture.capture_command("printf ok",
          logger: fn _event -> raise "logger failed" end
        )

      assert result.ok
      assert result.value == "ok"
    end
  end

  describe "working directory" do
    test "reusable config can set default working directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "marker.txt"), "default")

      portraiture = Portraiture.new(cwd: tmp_dir)
      result = Portraiture.capture_process(portraiture, find!("cat"), ["marker.txt"])

      assert result.ok
      assert result.value == "default"
    end

    test "per-call cwd overrides reusable config default", %{tmp_dir: tmp_dir} do
      default_directory = Path.join(tmp_dir, "default")
      override_directory = Path.join(tmp_dir, "override")
      File.mkdir_p!(default_directory)
      File.mkdir_p!(override_directory)
      File.write!(Path.join(default_directory, "marker.txt"), "default")
      File.write!(Path.join(override_directory, "marker.txt"), "override")

      portraiture = Portraiture.new(cwd: default_directory)

      result =
        Portraiture.capture_process(portraiture, find!("cat"), ["marker.txt"],
          cwd: override_directory
        )

      assert result.ok
      assert result.value == "override"
    end
  end

  describe "constructor defaults and per-call overrides" do
    test "stderr policy default applies and per-call overrides it" do
      portraiture = Portraiture.new(stderr: :fail)

      failed = Portraiture.capture_command(portraiture, "printf warn >&2")
      refute failed.ok
      assert failed.error.kind == :stderr

      collected = Portraiture.capture_command(portraiture, "printf warn >&2", stderr: :capture)
      assert collected.ok
      assert collected.stderr == "warn"
    end

    test "fail_on_nonzero_exit default applies and per-call overrides it" do
      portraiture = Portraiture.new(fail_on_nonzero_exit: false)

      collected = Portraiture.capture_command(portraiture, "exit 3")
      assert collected.ok
      assert collected.exit_code == 3

      failed = Portraiture.capture_command(portraiture, "exit 3", fail_on_nonzero_exit: true)
      refute failed.ok
      assert failed.error.kind == :exit
    end

    test "timeout_ms default applies and per-call overrides it" do
      portraiture = Portraiture.new(timeout_ms: 100)

      timed_out = Portraiture.capture_command(portraiture, "sleep 5")
      refute timed_out.ok
      assert timed_out.error.kind == :timeout

      relaxed = Portraiture.capture_command(portraiture, "sleep 0.3; printf done", timeout_ms: 10_000)
      assert relaxed.ok
      assert relaxed.value == "done"
    end

    test "logger default applies and per-call overrides it" do
      parent = self()
      portraiture = Portraiture.new(logger: fn event -> send(parent, {:default, event.type}) end)

      Portraiture.capture_command(portraiture, "printf hi")
      assert_received {:default, :start}

      Portraiture.capture_command(portraiture, "printf hi",
        logger: fn event -> send(parent, {:override, event.type}) end
      )

      assert_received {:override, :start}
      refute_received {:default, :start}
    end

    test "parse_input default applies and per-call overrides it" do
      portraiture = Portraiture.new(parse_input: :stderr)

      from_stderr =
        Portraiture.capture_command(portraiture, "printf out; printf err >&2",
          parser: fn text -> text end
        )

      assert from_stderr.value == "err"

      from_stdout =
        Portraiture.capture_command(portraiture, "printf out; printf err >&2",
          parse_input: :stdout,
          parser: fn text -> text end
        )

      assert from_stdout.value == "out"
    end
  end

  describe "option validation" do
    test "non-list, non-map options raise ArgumentError" do
      assert_raise ArgumentError, ~r/keyword list or map/, fn ->
        Portraiture.capture_command("ls", "oops")
      end
    end

    test "non-list process arguments raise ArgumentError" do
      assert_raise ArgumentError, ~r/must be a list/, fn ->
        Portraiture.capture_process("ls", "oops")
      end
    end

    test "unknown option keys raise ArgumentError" do
      assert_raise ArgumentError, ~r/unknown capture option/, fn ->
        Portraiture.capture_command("ls", bogus: true)
      end
    end

    test "the removed shell option raises instead of being ignored" do
      assert_raise ArgumentError, ~r/:shell/, fn ->
        Portraiture.capture_command("ls", shell: false)
      end
    end

    test "script-only options are rejected for command capture" do
      assert_raise ArgumentError, ~r/:interpreter/, fn ->
        Portraiture.capture_command("ls", interpreter: %{command: "/bin/sh"})
      end
    end

    test "invalid parser values raise ArgumentError" do
      assert_raise ArgumentError, ~r/:parser/, fn ->
        Portraiture.capture_command("ls", parser: "not a function")
      end
    end

    test "invalid parse_input values raise ArgumentError" do
      assert_raise ArgumentError, ~r/:parse_input/, fn ->
        Portraiture.capture_command("ls", parse_input: :both)
      end
    end

    test "new/1 rejects unknown keys" do
      assert_raise KeyError, fn -> Portraiture.new(bogus: true) end
      assert_raise KeyError, fn -> Portraiture.new(shell: true) end
      assert_raise KeyError, fn -> Portraiture.new(interpreter: %{command: "/bin/sh"}) end
    end
  end
end
