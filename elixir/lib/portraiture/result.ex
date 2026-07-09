defmodule Portraiture.Result do
  @moduledoc """
  Result of a single capture.

  Fields:

  * `:ok` — `true` when the capture succeeded under the configured policies.
  * `:value` — the parsed value on success. Without a parser this is the
    combined output string (stdout followed by stderr as captured). `nil` on
    failure.
  * `:error` — a `Portraiture.Failure` struct on failure, otherwise `nil`.
  * `:stdout` / `:stderr` — the captured streams. Always present, even when
    the capture failed.
  * `:output` — stdout followed by stderr. Because this implementation
    captures each stream into its own temporary file, cross-stream
    interleaving is not preserved (see the `Portraiture` module docs).
  * `:chunks` — best-effort output chunks, each `%{stream: :stdout | :stderr,
    text: binary}`. At most one chunk per stream in this implementation.
  * `:exit_code` — the process exit code, or `nil` when the process never
    exited (for example on timeout or spawn failure).
  * `:signal` — always `nil`; the Erlang port API does not expose the
    terminating signal.
  * `:duration_ms` — wall-clock capture duration in milliseconds.
  * `:target` — metadata about what was launched (`:kind`, `:command`,
    `:args`, and for scripts `:script` and optionally `:interpreter`).
  """

  @enforce_keys [:ok, :stdout, :stderr, :output, :chunks, :duration_ms, :target]
  defstruct [
    :ok,
    :value,
    :error,
    :stdout,
    :stderr,
    :output,
    :chunks,
    :exit_code,
    :signal,
    :duration_ms,
    :target
  ]

  @type t :: %__MODULE__{
          ok: boolean(),
          value: term(),
          error: Portraiture.Failure.t() | nil,
          stdout: String.t(),
          stderr: String.t(),
          output: String.t(),
          chunks: [Portraiture.chunk()],
          exit_code: integer() | nil,
          signal: nil,
          duration_ms: non_neg_integer(),
          target: Portraiture.target()
        }
end
