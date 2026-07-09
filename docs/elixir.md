# Elixir

## Command capture

```elixir
result = Portraiture.capture_command("uname -a")

if result.ok do
  IO.puts(result.value)
else
  raise result.error.message
end
```

## Process capture

Use `capture_process/3` when you want literal arguments without shell
interpretation:

```elixir
Portraiture.capture_process("rg", ["TODO", "."])
```

## Script capture

```elixir
Portraiture.capture_script("./scripts/collect-host", ["--json"])
```

Use an explicit interpreter when a script path should be launched through a
specific runtime:

```elixir
Portraiture.capture_script(
  "./scripts/collect-host.ps1",
  ["--json"],
  interpreter: %{command: "pwsh", args: ["-NoProfile", "-NonInteractive", "-File"]}
)
```

## Defaults

Use `Portraiture.new/1` when you want reusable defaults:

```elixir
portraiture =
  Portraiture.new(
    cwd: "/workspace/project",
    timeout_ms: 5_000,
    stderr: :fail
  )

result = Portraiture.capture_command(portraiture, "git status --short")
```

Default interpreters can be configured by extension:

```elixir
portraiture =
  Portraiture.new(
    interpreters: %{
      ".ps1" => %{command: "pwsh", args: ["-NoProfile", "-NonInteractive", "-File"]},
      ".py" => "python3"
    }
  )
```

## Parsers

Parser functions receive captured text and the capture context. Parsers may
return `{:ok, value}`, `{:error, reason}`, or a raw value.

```elixir
result =
  Portraiture.capture_script(
    "./scripts/collect-host-json",
    [],
    parser: fn text, _context ->
      {:ok, parse_host_portrait(text)}
    end
  )
```
