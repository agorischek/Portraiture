# Portraiture

Portraiture is a small SDK for running external commands or scripts and
capturing what they print, which can be useful for capturing evidence for
evaluation after an agent run, collecting diagnostics from an environment, or
recording the output of small inspection scripts.

The script being captured does not import Portraiture or depend on it. It can be
a shell command, an executable file, a Python script, a PowerShell script, a
compiled binary, or anything else the host runtime can launch. Portraiture sits
on the caller side: it starts the process, captures stdout and stderr, applies a
little policy, and returns a structured result.

## Supported languages

- TypeScript
- Python
- C#
- Go
- Elixir
- PowerShell
- Rust

## Core API shape

Each implementation provides the same three capture ideas, with idiomatic names
for the language:

- `captureCommand` runs a shell command string.
- `captureProcess` runs an executable with literal arguments.
- `captureScript` runs a script file path with optional script arguments.

Object-oriented languages also expose a configurable `Portraitist` type for
shared defaults such as working directory, environment variables, timeout,
stderr policy, stdin, and default script interpreters.

## Quick example

```ts
import { portraitist } from "portraiture";

const result = await portraitist.captureCommand("uname -a");

if (!result.ok) {
  throw new Error(result.error.message);
}

console.log(result.value);
```

## Documentation

User-facing language docs live in [docs/README.md](docs/README.md).

## Tests

Run every language suite:

```sh
npm run test:all
```

Run one suite:

```sh
npm run test:ts
npm run test:python
npm run test:csharp
npm run test:go
npm run test:elixir
npm run test:powershell
npm run test:rust
```
