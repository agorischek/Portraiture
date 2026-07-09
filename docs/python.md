# Python

```py
from portraiture import Portraitist, PortraitistOptions, capture
```

## Command capture

```py
result = capture.command("uname -a")

if not result.ok:
    raise RuntimeError(result.error.message)

print(result.value)
```

## Process capture

Use `capture_process` when you want literal arguments without shell
interpretation:

```py
result = capture.process("rg", ["TODO", "."])
```

## Script capture

```py
result = capture.script("./scripts/collect-host", ["--json"])
```

Use an explicit interpreter when a script path should be launched through a
specific runtime:

```py
result = capture.script(
    "./scripts/collect-host.ps1",
    ["--json"],
    interpreter={
        "command": "pwsh",
        "args": ["-NoProfile", "-NonInteractive", "-File"],
    },
)
```

## Defaults

Use `Portraitist` when you want reusable defaults:

```py
portraitist = Portraitist(
    PortraitistOptions(
        cwd="/workspace/project",
        timeout_ms=5_000,
        stderr="fail",
    )
)

result = portraitist.capture_command("git status --short")
```

Keyword construction is also supported:

```py
portraitist = Portraitist(cwd="/workspace/project", timeout_ms=5_000)
```

Per-call options override constructor defaults. Python uses the `UNSET` sentinel
internally so explicit `None` can clear a constructor default for a single call.

```py
portraitist = Portraitist(timeout_ms=5_000, env={"CI": "1"})

portraitist.capture_command("slow-tool", timeout_ms=None)
portraitist.capture_command("uname -a", env=None)
```

## Parsers

Parser functions receive captured text and the capture context. Parsers read
stdout by default.

```py
import json

result = portraitist.capture_script(
    "./scripts/collect-host-json",
    parser=lambda text, _context: json.loads(text),
)

if result.ok:
    print(result.value["hostname"])
```

Select parser input explicitly when needed:

```py
result = portraitist.capture_command(
    "tool --diagnostics",
    parse_input="stderr",
    parser=lambda text, _context: text.splitlines(),
)
```

## Notes

Supplied environment variables augment the parent environment. On POSIX,
timeouts terminate the child process group; on non-POSIX platforms only the
direct child process is killed.
