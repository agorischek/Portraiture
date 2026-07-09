defmodule Portraiture.Failure do
  @moduledoc """
  Structured description of a failed capture.

  Every failed `Portraiture.Result` carries one of these under `result.error`.

  * `:kind` — one of `:spawn`, `:timeout`, `:stderr`, `:exit`, or `:parse`.
  * `:message` — a human-readable explanation.
  * `:cause` — the underlying exception or term when one exists, otherwise `nil`.
  """

  @enforce_keys [:kind, :message]
  defstruct [:kind, :message, :cause]

  @typedoc "The failure classification required by the Portraiture contract."
  @type kind :: :exit | :parse | :spawn | :stderr | :timeout

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          cause: term()
        }
end
