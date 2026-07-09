# Portraiture Requirements

This document defines the cross-language behavior expected from Portraiture implementations. Individual languages should feel idiomatic, but they should preserve this contract wherever the host runtime makes it practical.

## Core Model

- Portraiture runs external commands, processes, and scripts to capture a portrait of an environment.
- Captured scripts must not depend on Portraiture. A script should be runnable directly from a terminal without importing the SDK.
- The SDK is responsible for launching the target, collecting stdout and stderr, applying failure policy, optionally parsing output, and returning a structured result.
- The SDK must not automatically inspect or collect arbitrary filesystem data as a primary API. Users can write scripts or use the host language filesystem APIs for that.

## Required Capture Methods

- `captureCommand` runs a shell command string. It may use the platform shell by default.
- `captureProcess` runs an executable plus literal arguments. It should avoid shell interpretation by default.
- `captureScript` runs a script file path and optional script arguments.
- Languages should use idiomatic casing and async conventions, such as `capture_command` in Python or `CaptureCommandAsync` in C#.

## Main Actor And Convenience APIs

- Object-oriented languages should provide a main `Portraitist` type that owns reusable defaults.
- Languages with classes should allow `Portraitist` to be instantiated with defaults for capture behavior.
- Languages may also expose a default instance and convenience functions or facades, such as TypeScript `capture.command(...)`, Python `capture.command(...)`, or C# `Capture.CommandAsync(...)`.
- Pure functional languages may omit a main class if a configured value, record, module, or effectful function set is more idiomatic.
- Static convenience facades may be omitted where module-level functions are the idiomatic equivalent.

## Constructor Defaults

- Constructor defaults should include working directory, environment, stderr policy, nonzero-exit policy, logging, parse input, shell behavior, stdin, timeout, and default script interpreters when the language supports those concepts.
- Per-call options must override constructor defaults.
- Parser functions or schemas are normally per-call because their output type is capture-specific.
- .NET implementations must support both a direct `PortraitistOptions` class and `IOptions<PortraitistOptions>` for dependency-injection scenarios.

## Working Directory

- Every capture method should accept a per-call working directory option.
- The main configurable actor should accept a default working directory.
- The working directory affects process launch only. It should not change the host application process working directory.

## Environment

- Every capture method should accept environment variables.
- Implementations should document whether supplied variables replace or augment the parent process environment.
- Current implementations should prefer augmenting the parent environment unless the language or runtime convention strongly points elsewhere.

## Output And Result Shape

- Results should include `ok`, `stdout`, `stderr`, combined `output`, output `chunks`, exit code, signal when available, duration, and target metadata.
- Successful captures should include a `value`.
- Failed captures should include a structured error with a failure kind and message.
- Required failure kinds are `spawn`, `timeout`, `stderr`, `exit`, and `parse`.
- If a runtime does not expose process signals, the signal field may be omitted or always null.
- Implementations should preserve stdout and stderr chunks best-effort, but exact cross-stream interleaving does not need to be guaranteed across runtimes.

## Stderr Policy

- The default stderr policy is to capture stderr as data.
- A `fail` policy should turn any non-empty stderr into a failed result with failure kind `stderr`.
- Stderr output must still be available on the result when stderr causes failure.

## Nonzero Exit Policy

- Nonzero exits should fail by default with failure kind `exit`.
- Implementations must provide an option to collect nonzero exits as successful data.
- Captured stdout and stderr must remain available regardless of exit success or failure.

## Timeouts

- Capture calls should support timeout where the host runtime can terminate or cancel child processes.
- Timeout failures should use failure kind `timeout`.
- Captured output before timeout should remain available where practical.
- Timeout termination should target the whole child process tree where the platform allows it, and remaining limitations should be documented.

## Cancellation

- Languages with a native cancellation primitive may support canceling an in-flight capture.
- Cancellation reporting should follow the host idiom: a language may add a `canceled` failure kind (Go) or propagate the platform's native cancellation signal after cleanup (.NET throws `OperationCanceledException`). The chosen behavior must be documented.
- Deadline-style cancellation, such as a context deadline, should be reported as failure kind `timeout`.
- Cancellation must not leak the child process: implementations should terminate the process tree before returning or throwing.

## Standard Input

- Capture calls should support passing stdin when the host runtime supports writing to child process standard input.
- Text stdin is required. Binary stdin is optional if the host language has a clear binary process API.

## Parsers

- Capture calls should accept an optional parser that converts captured text into a typed value.
- Parsers should read stdout by default.
- Implementations should support selecting parser input from stdout, stderr, or combined output.
- Parser exceptions should return a failed result with failure kind `parse`.
- TypeScript should support Standard Schema V1 parser-like schemas.
- Non-TypeScript implementations may omit Standard Schema support unless there is an idiomatic local equivalent.

## Script Interpreters

- `captureScript` should run the path directly by default.
- `captureScript` should accept an explicit interpreter option for a single call.
- The main configurable actor should accept default interpreters by extension.
- Interpreter definitions should support a command and optional fixed arguments before the script path.
- Implementations should not guess PowerShell, batch, Python, or shell behavior solely from a file extension unless the user has configured a default interpreter.
- Platform-specific interpreter presets are optional.

## Shell Behavior

- `captureCommand` may use a shell by default because it accepts a command string.
- `captureProcess` should avoid a shell by default because it accepts literal arguments.
- `captureScript` should avoid a shell by default unless a configured interpreter requires one.
- Implementations may expose a shell option if the host runtime supports it clearly.

## Logging

- Implementations should expose lifecycle and stream logging when idiomatic.
- Logging should include start, stdout chunk, stderr chunk, success, and failure events where practical.
- Logger exceptions or failures should not change the capture result.
- C# should integrate with `Microsoft.Extensions.Logging.ILogger`.
- Functional languages may represent logging as callbacks, effects, or event streams instead of object-oriented logger instances.

## Retries

- Retries are not required in the core SDK today.
- Implementations should not add hidden retry behavior around external scripts.
- A future retry feature should be explicit and should preserve access to each attempt result.

## Testing Requirements

- Each language implementation should cover command, process, and script capture.
- Tests should cover parser success and parser failure.
- Tests should cover stderr failure policy.
- Tests should cover default nonzero-exit failure and opt-out behavior.
- Tests should cover spawn failures and timeouts.
- Tests should cover stdin where supported.
- Tests should cover logger events where logging is supported.
- Tests should cover explicit script interpreters and default interpreters.
- Tests should cover constructor defaults, per-call overrides, and working directory behavior.
- Tests should cover environment augmentation, including constructor defaults and per-call key overrides.
- Tests should cover `parseInput` for stdout, stderr, and combined output.
- Tests should cover output preservation on timeout and on nonzero exits.
- Tests should assert the result metadata shape: stdout, stderr, combined output, chunks, exit code, signal or documented absence, duration, and target metadata.
- Tests should cover direct script execution without an interpreter where the platform supports executable scripts.
- Tests should cover exposed shell behavior, especially process/script arguments when shell execution is enabled.
- Tests should cover stdin edge cases where practical, including a child that exits without reading stdin.
- Tests should cover terminal logger events for failures, including spawn failures where the implementation can emit them.

## Acceptable Omissions

- A pure functional implementation may omit a `Portraitist` class if it provides an equivalent configured value or function set.
- A language without a stable package for dependency-injection options does not need an `IOptions` equivalent.
- A runtime that does not expose process signals may omit signal support.
- A runtime that cannot reliably kill child processes may document timeout limitations.
- A language without a clear schema standard may omit Standard Schema support.
- A platform-specific port may omit tests for script execution patterns that cannot run on that platform, as long as the limitation is documented.
