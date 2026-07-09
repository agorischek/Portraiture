# Portraiture Docs

These docs are for people using Portraiture in a specific language.

- [TypeScript](typescript.md)
- [Python](python.md)
- [C#](csharp.md)
- [Go](go.md)
- [Elixir](elixir.md)
- [PowerShell](powershell.md)
- [Rust](rust.md)

## Shared concepts

Portraiture runs something outside your application and captures the result:

- `captureCommand` runs a shell command string.
- `captureProcess` runs an executable with literal arguments.
- `captureScript` runs a script file path with optional script arguments.

Captures return structured results. Successful results contain a value plus
stdout, stderr, combined output, output chunks, exit metadata, duration, and
target metadata. Failed results still preserve captured output where possible.

By default:

- stderr is captured as data.
- nonzero exits fail the result.
- parsers read stdout.
- command strings use a shell.
- process and script calls avoid a shell unless configured otherwise.
