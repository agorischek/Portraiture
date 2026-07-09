# Rust

```rust
use portraiture::{Options, Portraitist};
```

## Command capture

```rust
let portraitist = Portraitist::new(Options::default());
let result = portraitist.capture_command("uname -a", Options::default());

let output = result.into_std_result()?;
println!("{output}");
```

Rust keeps the cross-language `CaptureResult<T>` shape so failed captures still
retain stdout, stderr, chunks, exit code, signal, duration, and target metadata.
Use `into_std_result()` when you want idiomatic `Result<T, CaptureFailure>`
flow.

## Process capture

Use `capture_process` when you want literal arguments without shell
interpretation:

```rust
let result = portraitist.capture_process("rg", ["TODO", "."], Options::default());
```

## Script capture

```rust
let result = portraitist.capture_script(
    "./scripts/collect-host",
    ["--json"],
    Options::default(),
);
```

Use an explicit interpreter when a script path should be launched through a
specific runtime:

```rust
use portraiture::Interpreter;

let result = portraitist.capture_script(
    "./scripts/collect-host.ps1",
    ["--json"],
    Options {
        interpreter: Some(Interpreter::with_args(
            "pwsh",
            ["-NoProfile", "-NonInteractive", "-File"],
        )),
        ..Options::default()
    },
);
```

## Defaults

```rust
use std::time::Duration;
use portraiture::{Options, Portraitist, StderrPolicy};

let portraitist = Portraitist::new(Options {
    working_directory: Some("/workspace/project".into()),
    timeout: Some(Duration::from_secs(5)),
    stderr: Some(StderrPolicy::Fail),
    ..Options::default()
});
```

Default interpreters can be configured by extension:

```rust
use std::collections::HashMap;
use portraiture::Interpreter;

let portraitist = Portraitist::new(Options {
    interpreters: HashMap::from([
        (
            ".ps1".to_string(),
            Interpreter::with_args("pwsh", ["-NoProfile", "-NonInteractive", "-File"]),
        ),
        (".py".to_string(), Interpreter::new("python3")),
    ]),
    ..Options::default()
});
```

## Parsers

Parser closures receive selected captured text and the capture context. Parsers
read stdout by default.

```rust
let result = portraitist.capture_script_parsed(
    "./scripts/collect-host-json",
    Vec::<String>::new(),
    Options::default(),
    |text, _context| parse_host_portrait(text),
);
```

Select parser input explicitly when needed:

```rust
use portraiture::ParseInput;

let result = portraitist.capture_command_parsed(
    "tool --diagnostics",
    Options {
        parse_input: Some(ParseInput::Stderr),
        ..Options::default()
    },
    |text, _context| Ok::<_, String>(text.lines().collect::<Vec<_>>()),
);
```
