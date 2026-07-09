// Package portraiture captures the output of external commands, processes,
// and scripts and returns structured results.
//
// The package exposes three capture styles: CaptureCommand runs a shell
// command string, CaptureProcess runs an executable with literal arguments
// (no shell interpretation), and CaptureScript runs a script file, optionally
// through a configured interpreter. A Portraitist holds reusable defaults for
// working directory, environment, policies, logging, and timeouts; the
// package-level functions delegate to a shared Default instance.
//
// Captures never panic on process problems. Every capture returns a Result
// whose Ok field reports success and whose Error field carries a structured
// *Failure (which also implements the error interface) on failure. Captured
// stdout, stderr, combined output, chunks, exit code, signal, and duration
// remain available on the Result regardless of success or failure.
//
// # Environment
//
// Environment variables supplied through Options.Environment AUGMENT the
// parent process environment (os.Environ()); they never replace it. Supplied
// keys override inherited keys of the same name, and everything else (PATH,
// HOME, and so on) is preserved.
//
// # Timeouts and cancellation
//
// When a capture times out (either through Options.Timeout or a deadline on
// the caller's context) the entire child process group is terminated on POSIX
// systems: the child is started as a process group leader, the group receives
// SIGTERM, and SIGKILL follows if the group does not exit promptly. Output
// captured before the timeout stays available on the Result. Deadline
// expiration is reported with failure kind "timeout"; explicit cancellation
// of the caller's context is reported with failure kind "canceled". On
// Windows only the direct child process is killed.
package portraiture

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// TargetKind identifies which capture style produced a Target.
type TargetKind string

// Target kinds for the three capture styles.
const (
	// CommandTarget marks a capture of a shell command string.
	CommandTarget TargetKind = "command"
	// ProcessTarget marks a capture of an executable plus literal arguments.
	ProcessTarget TargetKind = "process"
	// ScriptTarget marks a capture of a script file path.
	ScriptTarget TargetKind = "script"
)

// Stream identifies which output stream a Chunk or log event came from.
type Stream string

// Output streams.
const (
	// Stdout identifies the child process standard output stream.
	Stdout Stream = "stdout"
	// Stderr identifies the child process standard error stream.
	Stderr Stream = "stderr"
)

// ParseInput selects which captured text is handed to a Parser.
type ParseInput string

// Parser input selections.
const (
	// ParseStdout feeds the parser captured stdout. This is the default.
	ParseStdout ParseInput = "stdout"
	// ParseStderr feeds the parser captured stderr.
	ParseStderr ParseInput = "stderr"
	// ParseCombined feeds the parser the interleaved combined output.
	ParseCombined ParseInput = "combined"
)

// StderrPolicy controls how captured stderr affects the result.
type StderrPolicy string

// Stderr policies.
const (
	// StderrCapture records stderr as data without failing the capture.
	// This is the default.
	StderrCapture StderrPolicy = "capture"
	// StderrFail turns any non-empty stderr into a failure of kind
	// StderrFailure. The stderr text remains available on the Result.
	StderrFail StderrPolicy = "fail"
)

// FailureKind classifies why a capture failed.
type FailureKind string

// Failure kinds.
const (
	// ExitFailure reports a nonzero exit code, or termination by a signal
	// that Portraiture did not send (the Signal field names the signal).
	ExitFailure FailureKind = "exit"
	// ParseFailure reports that the configured parser returned an error.
	ParseFailure FailureKind = "parse"
	// SpawnFailure reports that the process could not be started.
	SpawnFailure FailureKind = "spawn"
	// StderrFailure reports non-empty stderr under the StderrFail policy.
	StderrFailure FailureKind = "stderr"
	// TimeoutFailure reports that the capture was terminated because a
	// deadline expired — either Options.Timeout or a deadline already set
	// on the caller's context.
	TimeoutFailure FailureKind = "timeout"
	// CanceledFailure reports that the capture was terminated because the
	// caller's context was explicitly canceled (context.Canceled), as
	// opposed to expiring by deadline.
	CanceledFailure FailureKind = "canceled"
)

// Chunk is one contiguous piece of output read from a single stream, in the
// order it was observed. Exact cross-stream interleaving is best-effort.
type Chunk struct {
	// Stream is the stream the chunk was read from.
	Stream Stream
	// Text is the chunk contents.
	Text string
}

// Interpreter describes how to launch a script through a runtime such as a
// shell, Python, or PowerShell.
type Interpreter struct {
	// Command is the interpreter executable, for example "python3".
	Command string
	// Args are fixed arguments spliced in before the script path, for
	// example []string{"-NoProfile", "-File"}.
	Args []string
}

// Target describes what a capture ran. It is echoed on results and log
// events for diagnostics.
type Target struct {
	// Kind is the capture style that produced this target.
	Kind TargetKind
	// Command is the shell command string, executable, or resolved
	// interpreter command that was launched.
	Command string
	// Args are the literal arguments passed to Command.
	Args []string
	// Script is the script path for ScriptTarget captures.
	Script string
	// Interpreter is the resolved interpreter for ScriptTarget captures,
	// or nil when the script ran directly.
	Interpreter *Interpreter
}

// CaptureContext carries the captured output and process metadata that is
// handed to parsers alongside the selected input text.
type CaptureContext struct {
	// Stdout is everything captured from standard output.
	Stdout string
	// Stderr is everything captured from standard error.
	Stderr string
	// Output is the combined stdout and stderr in observed order.
	Output string
	// Chunks are the individual reads, tagged by stream.
	Chunks []Chunk
	// ExitCode is the process exit code, or nil when the process did not
	// exit normally (for example when it was killed by a signal).
	ExitCode *int
	// Signal names the signal that terminated the process (for example
	// "SIGTERM") when the runtime exposes it, or "" otherwise. Always ""
	// on Windows.
	Signal string
	// Duration is the elapsed wall-clock time of the capture.
	Duration time.Duration
}

// Failure is the structured error carried by failed results. *Failure also
// implements the error interface, so it can be returned, wrapped, and
// inspected with errors.Is and errors.As.
type Failure struct {
	// Kind classifies the failure.
	Kind FailureKind
	// Message is a human-readable description of the failure.
	Message string
	// Cause is the underlying error, if any. It is exposed via Unwrap.
	Cause error
}

// Error implements the error interface.
func (failure *Failure) Error() string {
	return fmt.Sprintf("portraiture %s failure: %s", failure.Kind, failure.Message)
}

// Unwrap returns the underlying cause so that errors.Is and errors.As can
// see through the Failure.
func (failure *Failure) Unwrap() error {
	return failure.Cause
}

// Result is the outcome of a capture.
//
// Captures deliberately return a result object instead of a (value, error)
// pair: captured stdout, stderr, chunks, exit code, signal, and duration must
// remain accessible even when the capture fails (per the Portraiture
// contract), and a plain error return would lose that context. Error still
// implements the error interface for interoperability with Go error
// handling.
type Result[T any] struct {
	// Ok reports whether the capture succeeded.
	Ok bool
	// Value is the parsed value on success (the raw stdout string for the
	// unparsed capture methods). It is the zero value on failure.
	Value T
	// Error is the structured failure on failure, or nil on success.
	Error *Failure
	// Stdout is everything captured from standard output.
	Stdout string
	// Stderr is everything captured from standard error.
	Stderr string
	// Output is the combined stdout and stderr in observed order.
	Output string
	// Chunks are the individual reads, tagged by stream.
	Chunks []Chunk
	// ExitCode is the process exit code, or nil when the process did not
	// exit normally.
	ExitCode *int
	// Signal names the terminating signal when available (see
	// CaptureContext.Signal).
	Signal string
	// Duration is the elapsed wall-clock time of the capture.
	Duration time.Duration
	// Target describes what was executed.
	Target Target
}

// Parser converts captured text into a typed value. The text argument is
// selected by Options.ParseInput (stdout by default); the context carries the
// full captured output and process metadata. A returned error fails the
// capture with kind ParseFailure.
type Parser[T any] func(text string, context CaptureContext) (T, error)

// LogEventType identifies a capture lifecycle or stream log event.
type LogEventType string

// Log event types.
const (
	// LogStart is emitted once before the process is launched.
	LogStart LogEventType = "start"
	// LogStdout is emitted for each captured stdout chunk.
	LogStdout LogEventType = "stdout"
	// LogStderr is emitted for each captured stderr chunk.
	LogStderr LogEventType = "stderr"
	// LogFinish is emitted once when the capture completes, whether it
	// succeeded or failed (including spawn failures).
	LogFinish LogEventType = "finish"
)

// LogEvent is a single capture lifecycle or stream event.
type LogEvent struct {
	// Type is the event type.
	Type LogEventType
	// Target describes what is being executed.
	Target Target
	// Text is the chunk text for LogStdout and LogStderr events.
	Text string
	// Ok reports the capture outcome on LogFinish events.
	Ok bool
	// Duration is the capture duration on LogFinish events.
	Duration time.Duration
	// ExitCode is the process exit code on LogFinish events, when known.
	ExitCode *int
	// Signal is the terminating signal on LogFinish events, when known.
	Signal string
}

// Logger receives capture lifecycle and stream events.
//
// LogCapture is invoked concurrently: stdout and stderr chunk events are
// emitted from separate goroutines while the process runs, so implementations
// MUST be safe for concurrent use. Panics from LogCapture are recovered and
// never change the capture result.
type Logger interface {
	LogCapture(event LogEvent)
}

// LoggerFunc adapts a plain function to the Logger interface. The function
// must be safe for concurrent use (see Logger).
type LoggerFunc func(event LogEvent)

// LogCapture implements Logger by calling the wrapped function.
func (logger LoggerFunc) LogCapture(event LogEvent) {
	logger(event)
}

// Options configures a Portraitist (constructor defaults) or a single capture
// call (per-call options).
//
// Merging happens in layers: multiple variadic per-call Options are merged
// left to right (later values win field by field), and the merged per-call
// options are then applied over the constructor defaults. Per-call values
// always beat constructor defaults. Zero values ("", nil, 0) leave the
// inherited value in place; each field documents its own reset mechanics.
type Options struct {
	// WorkingDirectory is the directory the child process is launched in.
	// It never changes the host process working directory. An empty string
	// inherits the constructor default (and ultimately the host process
	// working directory); there is no way to reset an inherited default
	// other than passing a different directory.
	WorkingDirectory string
	// Environment entries AUGMENT the parent process environment
	// (os.Environ()); they never replace it. Supplied keys override
	// inherited variables of the same name; everything else (PATH, HOME,
	// and so on) is preserved. Constructor and per-call maps are merged
	// with per-call keys winning. Individual variables cannot be removed
	// from the parent environment, only overridden (for example with "").
	Environment map[string]string
	// FailOnNonZeroExit controls whether a nonzero exit code fails the
	// capture (kind ExitFailure). nil inherits the constructor default,
	// which itself defaults to true. Use Bool(false) to collect nonzero
	// exits as successful data, or Bool(true) to reset an inherited false.
	FailOnNonZeroExit *bool
	// Logger receives lifecycle and stream events and must be safe for
	// concurrent use (see Logger). nil inherits the constructor default;
	// an inherited logger cannot be reset to nil per call, only replaced
	// (for example with a no-op LoggerFunc).
	Logger Logger
	// ParseInput selects the text handed to a Parser: ParseStdout
	// (default), ParseStderr, or ParseCombined. "" inherits; pass
	// ParseStdout explicitly to reset an inherited default.
	ParseInput ParseInput
	// Interpreter forces a specific interpreter for a script capture. It
	// takes precedence over any Interpreters map. Resolution order is:
	// per-call Interpreter, per-call Interpreters, constructor
	// Interpreter, constructor Interpreters. nil inherits.
	Interpreter *Interpreter
	// Interpreters maps script extensions (".py" or "py") to default
	// interpreters. Constructor and per-call maps are merged with per-call
	// entries winning; see Interpreter for the full resolution order.
	Interpreters map[string]Interpreter
	// UseShell controls whether the target runs through the platform shell
	// (/bin/sh -c on POSIX, cmd.exe /C on Windows). nil inherits the
	// constructor default, which itself defaults to true for command
	// captures and false for process and script captures. Use Bool to set
	// or reset explicitly. On Windows, forcing UseShell for a target with
	// literal arguments fails with kind SpawnFailure, because arguments
	// cannot be safely escaped for cmd.exe; format the command as a single
	// string with CaptureCommand instead.
	UseShell *bool
	// Stderr is the stderr policy: StderrCapture (default) or StderrFail.
	// "" inherits; pass StderrCapture explicitly to reset an inherited
	// StderrFail default.
	Stderr StderrPolicy
	// StandardInput is text written to the child process standard input.
	// "" inherits the constructor default; an inherited value cannot be
	// reset to empty per call.
	StandardInput string
	// Timeout bounds the capture duration. Zero inherits the constructor
	// default. A negative value explicitly disables an inherited default
	// (no timeout). On expiry the child process group is terminated on
	// POSIX (SIGTERM, then SIGKILL) and the capture fails with kind
	// TimeoutFailure; output captured before expiry stays available.
	Timeout time.Duration
}

// Portraitist owns reusable capture defaults. Create one with New; the zero
// value is not usable. A Portraitist is safe for concurrent use.
type Portraitist struct {
	defaults Options
}

// Default is the shared Portraitist used by the package-level capture
// functions. It has no constructor defaults.
var Default = New(Options{})

// Bool returns a pointer to value, for use with the pointer-typed option
// fields FailOnNonZeroExit and UseShell.
func Bool(value bool) *bool {
	return &value
}

// New creates a Portraitist with the given constructor defaults. The options
// are cloned, so later mutation of the argument does not affect the
// Portraitist.
func New(options Options) *Portraitist {
	return &Portraitist{defaults: cloneOptions(options)}
}

// CaptureCommand runs a shell command string with the Default Portraitist.
// See Portraitist.CaptureCommand.
func CaptureCommand(ctx context.Context, command string, options ...Options) Result[string] {
	return Default.CaptureCommand(ctx, command, options...)
}

// CaptureProcess runs an executable with literal arguments (no shell) using
// the Default Portraitist. See Portraitist.CaptureProcess.
func CaptureProcess(ctx context.Context, program string, args []string, options ...Options) Result[string] {
	return Default.CaptureProcess(ctx, program, args, options...)
}

// CaptureScript runs a script file with the Default Portraitist. See
// Portraitist.CaptureScript.
func CaptureScript(ctx context.Context, path string, args []string, options ...Options) Result[string] {
	return Default.CaptureScript(ctx, path, args, options...)
}

// CaptureWithParser returns a ParsedCapture bound to the Default Portraitist
// and the given parser. It exists because Go methods cannot introduce type
// parameters.
func CaptureWithParser[T any](parser Parser[T]) ParsedCapture[T] {
	return WithParser(Default, parser)
}

// CaptureCommandParsed runs a shell command string with the Default
// Portraitist and parses the selected output with parser.
func CaptureCommandParsed[T any](ctx context.Context, command string, parser Parser[T], options ...Options) Result[T] {
	return CaptureWithParser(parser).Command(ctx, command, options...)
}

// CaptureProcessParsed runs an executable with literal arguments using the
// Default Portraitist and parses the selected output with parser.
func CaptureProcessParsed[T any](ctx context.Context, program string, args []string, parser Parser[T], options ...Options) Result[T] {
	return CaptureWithParser(parser).Process(ctx, program, args, options...)
}

// CaptureScriptParsed runs a script file with the Default Portraitist and
// parses the selected output with parser.
func CaptureScriptParsed[T any](ctx context.Context, path string, args []string, parser Parser[T], options ...Options) Result[T] {
	return CaptureWithParser(parser).Script(ctx, path, args, options...)
}

// CaptureCommand runs a shell command string. It uses the platform shell by
// default (/bin/sh -c on POSIX, cmd.exe /C on Windows). Multiple options are
// merged left to right and then applied over the constructor defaults.
func (portraitist *Portraitist) CaptureCommand(ctx context.Context, command string, options ...Options) Result[string] {
	target := Target{Kind: CommandTarget, Command: command}
	return runCapture(ctx, portraitist, target, stringParser, mergeCallOptions(options))
}

// CaptureProcess runs an executable plus literal arguments without shell
// interpretation by default. Multiple options are merged left to right and
// then applied over the constructor defaults.
func (portraitist *Portraitist) CaptureProcess(ctx context.Context, program string, args []string, options ...Options) Result[string] {
	target := Target{Kind: ProcessTarget, Command: program, Args: cloneStrings(args)}
	return runCapture(ctx, portraitist, target, stringParser, mergeCallOptions(options))
}

// CaptureScript runs a script file path with optional script arguments. By
// default the path is executed directly (so it must be executable, for
// example via a shebang line on POSIX); an interpreter resolved from the
// Interpreter and Interpreters options is used when configured. Multiple
// options are merged left to right and then applied over the constructor
// defaults.
func (portraitist *Portraitist) CaptureScript(ctx context.Context, path string, args []string, options ...Options) Result[string] {
	callOptions := mergeCallOptions(options)
	target := portraitist.createScriptTarget(path, args, callOptions)
	return runCapture(ctx, portraitist, target, stringParser, callOptions)
}

// ParsedCapture pairs a Portraitist with a Parser so captures can return a
// typed value. Construct one with WithParser or CaptureWithParser; the zero
// value is not usable.
type ParsedCapture[T any] struct {
	portraitist *Portraitist
	parser      Parser[T]
}

// WithParser binds parser to portraitist. A nil portraitist uses Default; a
// nil parser yields captures that fail with kind ParseFailure.
func WithParser[T any](portraitist *Portraitist, parser Parser[T]) ParsedCapture[T] {
	if portraitist == nil {
		portraitist = Default
	}

	if parser == nil {
		parser = missingParser[T]
	}

	return ParsedCapture[T]{
		portraitist: portraitist,
		parser:      parser,
	}
}

// Command runs a shell command string and parses the selected output. See
// Portraitist.CaptureCommand.
func (capture ParsedCapture[T]) Command(ctx context.Context, command string, options ...Options) Result[T] {
	target := Target{Kind: CommandTarget, Command: command}
	return runCapture(ctx, capture.portraitist, target, capture.parser, mergeCallOptions(options))
}

// Process runs an executable with literal arguments and parses the selected
// output. See Portraitist.CaptureProcess.
func (capture ParsedCapture[T]) Process(ctx context.Context, program string, args []string, options ...Options) Result[T] {
	target := Target{Kind: ProcessTarget, Command: program, Args: cloneStrings(args)}
	return runCapture(ctx, capture.portraitist, target, capture.parser, mergeCallOptions(options))
}

// Script runs a script file and parses the selected output. See
// Portraitist.CaptureScript.
func (capture ParsedCapture[T]) Script(ctx context.Context, path string, args []string, options ...Options) Result[T] {
	callOptions := mergeCallOptions(options)
	target := capture.portraitist.createScriptTarget(path, args, callOptions)
	return runCapture(ctx, capture.portraitist, target, capture.parser, callOptions)
}

type resolvedOptions struct {
	WorkingDirectory  string
	Environment       map[string]string
	FailOnNonZeroExit bool
	Logger            Logger
	ParseInput        ParseInput
	UseShell          bool
	Stderr            StderrPolicy
	StandardInput     string
	Timeout           time.Duration
}

// cancellationWaitDelay bounds how long Wait blocks on lingering I/O after
// the process exits or the context is canceled (exec.Cmd.WaitDelay). It is a
// belt-and-braces guard; process-group termination normally releases the
// pipes well before it fires.
const cancellationWaitDelay = 10 * time.Second

// errWindowsShellArgs reports the unsupported UseShell-with-arguments
// combination on Windows. cmd.exe metacharacters (%VAR%, ^, &) cannot be
// escaped safely, so Portraiture refuses to build an injectable command line.
var errWindowsShellArgs = errors.New(
	"UseShell with literal arguments is not supported on Windows because arguments cannot be safely escaped for cmd.exe; format the command as a single string with CaptureCommand or disable UseShell",
)

// captureState accumulates output from both stream writers under one lock.
type captureState struct {
	gate   sync.Mutex
	stdout bytes.Buffer
	stderr bytes.Buffer
	output bytes.Buffer
	chunks []Chunk
}

func (state *captureState) snapshot(duration time.Duration) CaptureContext {
	state.gate.Lock()
	defer state.gate.Unlock()

	return CaptureContext{
		Stdout:   state.stdout.String(),
		Stderr:   state.stderr.String(),
		Output:   state.output.String(),
		Chunks:   cloneChunks(state.chunks),
		Duration: duration,
	}
}

// streamWriter is installed as cmd.Stdout or cmd.Stderr. Letting os/exec own
// the pipe copying (instead of StdoutPipe/StderrPipe plus manual reads) makes
// cmd.Wait itself wait for all output to be captured, eliminating the
// wait-before-readers race that could truncate output.
type streamWriter struct {
	state  *captureState
	stream Stream
	logger Logger
	target Target
}

func (writer *streamWriter) Write(data []byte) (int, error) {
	text := string(data)

	writer.state.gate.Lock()
	buffer := &writer.state.stdout
	if writer.stream == Stderr {
		buffer = &writer.state.stderr
	}
	buffer.WriteString(text)
	writer.state.output.WriteString(text)
	writer.state.chunks = append(writer.state.chunks, Chunk{Stream: writer.stream, Text: text})
	writer.state.gate.Unlock()

	eventType := LogStdout
	if writer.stream == Stderr {
		eventType = LogStderr
	}
	safeLog(writer.logger, LogEvent{Type: eventType, Target: cloneTarget(writer.target), Text: text})

	return len(data), nil
}

func runCapture[T any](
	parentContext context.Context,
	portraitist *Portraitist,
	target Target,
	parser Parser[T],
	callOptions Options,
) Result[T] {
	if portraitist == nil {
		portraitist = Default
	}
	if parentContext == nil {
		parentContext = context.Background()
	}

	options := portraitist.resolveOptions(target.Kind, callOptions)
	startedAt := time.Now()
	runContext := parentContext
	cancel := func() {}
	if options.Timeout > 0 {
		runContext, cancel = context.WithTimeout(parentContext, options.Timeout)
	}
	defer cancel()

	command, buildErr := buildCommand(runContext, target, options)

	safeLog(options.Logger, LogEvent{Type: LogStart, Target: cloneTarget(target)})

	if buildErr != nil {
		failure := failureResult[T](target, emptyContext(time.Since(startedAt)), SpawnFailure, buildErr.Error(), buildErr)
		safeLogFinish(options.Logger, target, failure)
		return failure
	}

	if options.WorkingDirectory != "" {
		command.Dir = options.WorkingDirectory
	}
	if len(options.Environment) > 0 {
		// Augment, never replace: supplied variables are appended after
		// os.Environ() so they override same-named parent variables while
		// preserving the rest of the parent environment.
		command.Env = append(os.Environ(), environmentList(options.Environment)...)
	}
	if options.StandardInput != "" {
		command.Stdin = strings.NewReader(options.StandardInput)
	}

	state := &captureState{}
	command.Stdout = &streamWriter{state: state, stream: Stdout, logger: options.Logger, target: target}
	command.Stderr = &streamWriter{state: state, stream: Stderr, logger: options.Logger, target: target}

	var killed atomic.Bool
	setupCancellation(command, &killed)

	if err := command.Start(); err != nil {
		kind := SpawnFailure
		message := err.Error()
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			kind, message = TimeoutFailure, "Capture timed out before the process started."
		case errors.Is(err, context.Canceled):
			kind, message = CanceledFailure, "Capture was canceled before the process started."
		}
		failure := failureResult[T](target, emptyContext(time.Since(startedAt)), kind, message, err)
		safeLogFinish(options.Logger, target, failure)
		return failure
	}

	waitErr := command.Wait()

	duration := time.Since(startedAt)
	captureContext := state.snapshot(duration)
	captureContext.ExitCode = processExitCode(command)
	captureContext.Signal = processSignal(command)

	// Classify cancellation by whether our cancel hook actually fired and
	// the wait actually failed, not by a post-hoc context check: a run that
	// completed successfully right at the deadline stays successful.
	if killed.Load() && waitErr != nil {
		kind := CanceledFailure
		message := "Capture was canceled."
		if errors.Is(context.Cause(runContext), context.DeadlineExceeded) {
			kind = TimeoutFailure
			message = "Capture timed out."
		}
		failure := failureResult[T](target, captureContext, kind, message, waitErr)
		safeLogFinish(options.Logger, target, failure)
		return failure
	}

	if waitErr != nil && captureContext.ExitCode == nil {
		if captureContext.Signal != "" {
			failure := failureResult[T](
				target,
				captureContext,
				ExitFailure,
				fmt.Sprintf("Capture was terminated by signal %s.", captureContext.Signal),
				waitErr,
			)
			safeLogFinish(options.Logger, target, failure)
			return failure
		}

		failure := failureResult[T](target, captureContext, SpawnFailure, waitErr.Error(), waitErr)
		safeLogFinish(options.Logger, target, failure)
		return failure
	}

	if options.Stderr == StderrFail && captureContext.Stderr != "" {
		failure := failureResult[T](target, captureContext, StderrFailure, "Capture wrote to stderr.", nil)
		safeLogFinish(options.Logger, target, failure)
		return failure
	}

	if options.FailOnNonZeroExit && captureContext.ExitCode != nil && *captureContext.ExitCode != 0 {
		failure := failureResult[T](
			target,
			captureContext,
			ExitFailure,
			fmt.Sprintf("Capture exited with code %d.", *captureContext.ExitCode),
			waitErr,
		)
		safeLogFinish(options.Logger, target, failure)
		return failure
	}

	value, err := parser(parserInput(captureContext, options.ParseInput), captureContext)
	if err != nil {
		failure := failureResult[T](target, captureContext, ParseFailure, err.Error(), err)
		safeLogFinish(options.Logger, target, failure)
		return failure
	}

	result := successResult(target, captureContext, value)
	safeLogFinish(options.Logger, target, result)
	return result
}

func (portraitist *Portraitist) createScriptTarget(path string, args []string, callOptions Options) Target {
	interpreter := portraitist.resolveInterpreter(path, callOptions)
	if interpreter == nil {
		return Target{
			Kind:    ScriptTarget,
			Command: path,
			Args:    cloneStrings(args),
			Script:  path,
		}
	}

	commandArgs := make([]string, 0, len(interpreter.Args)+1+len(args))
	commandArgs = append(commandArgs, interpreter.Args...)
	commandArgs = append(commandArgs, path)
	commandArgs = append(commandArgs, args...)

	return Target{
		Kind:        ScriptTarget,
		Command:     interpreter.Command,
		Args:        commandArgs,
		Script:      path,
		Interpreter: cloneInterpreterPointer(interpreter),
	}
}

// resolveInterpreter applies the documented precedence: per-call Interpreter,
// then per-call Interpreters, then constructor Interpreter, then constructor
// Interpreters. Per-call options always beat constructor defaults.
func (portraitist *Portraitist) resolveInterpreter(path string, callOptions Options) *Interpreter {
	if callOptions.Interpreter != nil {
		return cloneInterpreterPointer(callOptions.Interpreter)
	}

	if interpreter := lookupInterpreter(callOptions.Interpreters, path); interpreter != nil {
		return interpreter
	}

	if portraitist.defaults.Interpreter != nil {
		return cloneInterpreterPointer(portraitist.defaults.Interpreter)
	}

	return lookupInterpreter(portraitist.defaults.Interpreters, path)
}

func lookupInterpreter(interpreters map[string]Interpreter, path string) *Interpreter {
	if len(interpreters) == 0 {
		return nil
	}

	extension := filepath.Ext(path)
	if extension == "" {
		return nil
	}

	if interpreter, ok := interpreters[extension]; ok {
		return cloneInterpreterPointer(&interpreter)
	}

	if interpreter, ok := interpreters[strings.TrimPrefix(extension, ".")]; ok {
		return cloneInterpreterPointer(&interpreter)
	}

	return nil
}

func (portraitist *Portraitist) resolveOptions(kind TargetKind, callOptions Options) resolvedOptions {
	defaults := portraitist.defaults
	failOnNonZeroExit := true
	if defaults.FailOnNonZeroExit != nil {
		failOnNonZeroExit = *defaults.FailOnNonZeroExit
	}
	if callOptions.FailOnNonZeroExit != nil {
		failOnNonZeroExit = *callOptions.FailOnNonZeroExit
	}

	useShell := kind == CommandTarget
	if defaults.UseShell != nil {
		useShell = *defaults.UseShell
	}
	if callOptions.UseShell != nil {
		useShell = *callOptions.UseShell
	}

	stderr := StderrCapture
	if defaults.Stderr != "" {
		stderr = defaults.Stderr
	}
	if callOptions.Stderr != "" {
		stderr = callOptions.Stderr
	}

	parseInput := ParseStdout
	if defaults.ParseInput != "" {
		parseInput = defaults.ParseInput
	}
	if callOptions.ParseInput != "" {
		parseInput = callOptions.ParseInput
	}

	logger := defaults.Logger
	if callOptions.Logger != nil {
		logger = callOptions.Logger
	}

	standardInput := defaults.StandardInput
	if callOptions.StandardInput != "" {
		standardInput = callOptions.StandardInput
	}

	timeout := defaults.Timeout
	if callOptions.Timeout != 0 {
		timeout = callOptions.Timeout
	}
	if timeout < 0 {
		// A negative per-call (or constructor) timeout explicitly disables
		// any inherited timeout.
		timeout = 0
	}

	return resolvedOptions{
		WorkingDirectory:  chooseString(defaults.WorkingDirectory, callOptions.WorkingDirectory),
		Environment:       mergeEnvironment(defaults.Environment, callOptions.Environment),
		FailOnNonZeroExit: failOnNonZeroExit,
		Logger:            logger,
		ParseInput:        parseInput,
		UseShell:          useShell,
		Stderr:            stderr,
		StandardInput:     standardInput,
		Timeout:           timeout,
	}
}

func buildCommand(ctx context.Context, target Target, options resolvedOptions) (*exec.Cmd, error) {
	if options.UseShell {
		line := target.Command
		if target.Kind != CommandTarget {
			if runtime.GOOS == "windows" {
				// cmd.exe has no safe quoting for %VAR%, ^, &, and friends;
				// refuse rather than build an injectable command line.
				return nil, errWindowsShellArgs
			}
			line = shellJoin(append([]string{target.Command}, target.Args...))
		}

		if runtime.GOOS == "windows" {
			return exec.CommandContext(ctx, "cmd.exe", "/C", line), nil
		}

		return exec.CommandContext(ctx, "/bin/sh", "-c", line), nil
	}

	return exec.CommandContext(ctx, target.Command, target.Args...), nil
}

func parserInput(context CaptureContext, parseInput ParseInput) string {
	switch parseInput {
	case ParseCombined:
		return context.Output
	case ParseStderr:
		return context.Stderr
	default:
		return context.Stdout
	}
}

func stringParser(text string, _ CaptureContext) (string, error) {
	return text, nil
}

func missingParser[T any](_ string, _ CaptureContext) (T, error) {
	var zero T
	return zero, errors.New("parser is nil")
}

func successResult[T any](target Target, context CaptureContext, value T) Result[T] {
	return Result[T]{
		Ok:       true,
		Value:    value,
		Stdout:   context.Stdout,
		Stderr:   context.Stderr,
		Output:   context.Output,
		Chunks:   cloneChunks(context.Chunks),
		ExitCode: cloneIntPointer(context.ExitCode),
		Signal:   context.Signal,
		Duration: context.Duration,
		Target:   cloneTarget(target),
	}
}

func failureResult[T any](target Target, context CaptureContext, kind FailureKind, message string, cause error) Result[T] {
	return Result[T]{
		Ok: false,
		Error: &Failure{
			Kind:    kind,
			Message: message,
			Cause:   cause,
		},
		Stdout:   context.Stdout,
		Stderr:   context.Stderr,
		Output:   context.Output,
		Chunks:   cloneChunks(context.Chunks),
		ExitCode: cloneIntPointer(context.ExitCode),
		Signal:   context.Signal,
		Duration: context.Duration,
		Target:   cloneTarget(target),
	}
}

func emptyContext(duration time.Duration) CaptureContext {
	return CaptureContext{Duration: duration}
}

func processExitCode(command *exec.Cmd) *int {
	if command.ProcessState == nil {
		return nil
	}

	exitCode := command.ProcessState.ExitCode()
	if exitCode < 0 {
		return nil
	}

	return &exitCode
}

func safeLog(logger Logger, event LogEvent) {
	if logger == nil {
		return
	}

	defer func() {
		_ = recover()
	}()

	logger.LogCapture(event)
}

func safeLogFinish[T any](logger Logger, target Target, result Result[T]) {
	safeLog(logger, LogEvent{
		Type:     LogFinish,
		Target:   cloneTarget(target),
		Ok:       result.Ok,
		Duration: result.Duration,
		ExitCode: cloneIntPointer(result.ExitCode),
		Signal:   result.Signal,
	})
}

// mergeCallOptions merges every variadic per-call Options value left to
// right: later values win field by field, with the same zero-value-inherits
// semantics used when applying per-call options over constructor defaults.
func mergeCallOptions(options []Options) Options {
	merged := Options{}
	for _, next := range options {
		merged = mergeOptions(merged, next)
	}
	return merged
}

func mergeOptions(base Options, override Options) Options {
	merged := cloneOptions(base)

	if override.WorkingDirectory != "" {
		merged.WorkingDirectory = override.WorkingDirectory
	}
	merged.Environment = mergeEnvironment(merged.Environment, override.Environment)
	if override.FailOnNonZeroExit != nil {
		merged.FailOnNonZeroExit = cloneBoolPointer(override.FailOnNonZeroExit)
	}
	if override.Logger != nil {
		merged.Logger = override.Logger
	}
	if override.ParseInput != "" {
		merged.ParseInput = override.ParseInput
	}
	if override.Interpreter != nil {
		merged.Interpreter = cloneInterpreterPointer(override.Interpreter)
	}
	merged.Interpreters = mergeInterpreters(merged.Interpreters, override.Interpreters)
	if override.UseShell != nil {
		merged.UseShell = cloneBoolPointer(override.UseShell)
	}
	if override.Stderr != "" {
		merged.Stderr = override.Stderr
	}
	if override.StandardInput != "" {
		merged.StandardInput = override.StandardInput
	}
	if override.Timeout != 0 {
		merged.Timeout = override.Timeout
	}

	return merged
}

func cloneOptions(options Options) Options {
	return Options{
		WorkingDirectory:  options.WorkingDirectory,
		Environment:       cloneStringMap(options.Environment),
		FailOnNonZeroExit: cloneBoolPointer(options.FailOnNonZeroExit),
		Logger:            options.Logger,
		ParseInput:        options.ParseInput,
		Interpreter:       cloneInterpreterPointer(options.Interpreter),
		Interpreters:      cloneInterpreterMap(options.Interpreters),
		UseShell:          cloneBoolPointer(options.UseShell),
		Stderr:            options.Stderr,
		StandardInput:     options.StandardInput,
		Timeout:           options.Timeout,
	}
}

func cloneTarget(target Target) Target {
	return Target{
		Kind:        target.Kind,
		Command:     target.Command,
		Args:        cloneStrings(target.Args),
		Script:      target.Script,
		Interpreter: cloneInterpreterPointer(target.Interpreter),
	}
}

func cloneChunks(chunks []Chunk) []Chunk {
	if chunks == nil {
		return nil
	}

	cloned := make([]Chunk, len(chunks))
	copy(cloned, chunks)
	return cloned
}

func cloneStrings(values []string) []string {
	if values == nil {
		return nil
	}

	cloned := make([]string, len(values))
	copy(cloned, values)
	return cloned
}

func cloneStringMap(values map[string]string) map[string]string {
	if values == nil {
		return nil
	}

	cloned := make(map[string]string, len(values))
	for key, value := range values {
		cloned[key] = value
	}
	return cloned
}

func cloneInterpreterMap(values map[string]Interpreter) map[string]Interpreter {
	if values == nil {
		return nil
	}

	cloned := make(map[string]Interpreter, len(values))
	for key, value := range values {
		cloned[key] = cloneInterpreter(value)
	}
	return cloned
}

func cloneInterpreter(value Interpreter) Interpreter {
	return Interpreter{
		Command: value.Command,
		Args:    cloneStrings(value.Args),
	}
}

func cloneInterpreterPointer(value *Interpreter) *Interpreter {
	if value == nil {
		return nil
	}

	cloned := cloneInterpreter(*value)
	return &cloned
}

func cloneBoolPointer(value *bool) *bool {
	if value == nil {
		return nil
	}

	cloned := *value
	return &cloned
}

func cloneIntPointer(value *int) *int {
	if value == nil {
		return nil
	}

	cloned := *value
	return &cloned
}

func mergeEnvironment(defaults map[string]string, overrides map[string]string) map[string]string {
	if defaults == nil && overrides == nil {
		return nil
	}

	merged := cloneStringMap(defaults)
	if merged == nil {
		merged = map[string]string{}
	}

	for key, value := range overrides {
		merged[key] = value
	}

	return merged
}

func mergeInterpreters(defaults map[string]Interpreter, overrides map[string]Interpreter) map[string]Interpreter {
	if defaults == nil && overrides == nil {
		return nil
	}

	merged := cloneInterpreterMap(defaults)
	if merged == nil {
		merged = map[string]Interpreter{}
	}

	for key, value := range overrides {
		merged[key] = cloneInterpreter(value)
	}

	return merged
}

func environmentList(environment map[string]string) []string {
	values := make([]string, 0, len(environment))
	for key, value := range environment {
		values = append(values, key+"="+value)
	}
	return values
}

func chooseString(defaultValue string, overrideValue string) string {
	if overrideValue != "" {
		return overrideValue
	}

	return defaultValue
}

func shellJoin(args []string) string {
	quoted := make([]string, 0, len(args))
	for _, arg := range args {
		quoted = append(quoted, shellQuote(arg))
	}
	return strings.Join(quoted, " ")
}

// shellQuote quotes a single argument for a POSIX shell. It is only used on
// non-Windows platforms; see errWindowsShellArgs for the Windows behavior.
func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
