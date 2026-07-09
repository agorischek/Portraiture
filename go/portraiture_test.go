package portraiture

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestHelperProcess(t *testing.T) {
	if os.Getenv("PORTRAITURE_GO_HELPER_PROCESS") != "1" {
		return
	}

	separator := slices.Index(os.Args, "--")
	if separator == -1 || separator+1 >= len(os.Args) {
		os.Exit(2)
	}

	args := os.Args[separator+1:]
	switch args[0] {
	case "echo":
		os.Stdout.WriteString(args[1])
	case "json":
		os.Stdout.WriteString(`{"hostname":"local","platform":"test"}`)
	case "stderr":
		os.Stderr.WriteString(args[1])
	case "exit":
		os.Stdout.WriteString("before")
		os.Stderr.WriteString("bad")
		os.Exit(7)
	case "sleep":
		milliseconds, _ := strconv.Atoi(args[1])
		time.Sleep(time.Duration(milliseconds) * time.Millisecond)
	case "slow":
		os.Stdout.WriteString("before")
		time.Sleep(5 * time.Second)
	case "stdin":
		data, _ := io.ReadAll(os.Stdin)
		os.Stdout.Write(data)
	case "env":
		values := make([]string, 0, len(args)-1)
		for _, name := range args[1:] {
			values = append(values, os.Getenv(name))
		}
		os.Stdout.WriteString(strings.Join(values, "|"))
	case "big":
		size, _ := strconv.Atoi(args[1])
		os.Stdout.Write(bytes.Repeat([]byte("a"), size))
	case "marker":
		data, err := os.ReadFile("marker.txt")
		if err != nil {
			os.Stderr.WriteString(err.Error())
			os.Exit(1)
		}
		os.Stdout.Write(data)
	case "out-err":
		os.Stdout.WriteString("out")
		os.Stderr.WriteString("err")
	default:
		os.Exit(2)
	}

	os.Exit(0)
}

func TestCaptureCommandCapturesStdout(t *testing.T) {
	t.Parallel()
	result := CaptureCommand(context.Background(), printfCommand("hello"))

	if !result.Ok {
		t.Fatalf("expected capture to succeed: %#v", result.Error)
	}
	if result.Value != "hello" {
		t.Fatalf("expected value hello, got %q", result.Value)
	}
	if result.Target.Kind != CommandTarget {
		t.Fatalf("expected command target, got %s", result.Target.Kind)
	}
}

func TestCaptureProcessPassesLiteralArgs(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("echo", "hello; echo nope"))

	if !result.Ok {
		t.Fatalf("expected capture to succeed: %#v", result.Error)
	}
	if result.Value != "hello; echo nope" {
		t.Fatalf("expected literal args, got %q", result.Value)
	}
	if result.Target.Kind != ProcessTarget {
		t.Fatalf("expected process target, got %s", result.Target.Kind)
	}
}

func TestCaptureScriptRunsDirectlyWithoutInterpreter(t *testing.T) {
	t.Parallel()
	skipWindowsScriptTest(t)
	script := writeTempScript(t, "direct.sh", "#!/bin/sh\nprintf 'direct:%s' \"$1\"\n")
	result := CaptureScript(context.Background(), script, []string{"one"})

	if !result.Ok {
		t.Fatalf("expected direct script capture to succeed: %#v", result.Error)
	}
	if result.Value != "direct:one" {
		t.Fatalf("expected direct script output, got %q", result.Value)
	}
	if result.Target.Interpreter != nil {
		t.Fatalf("expected no interpreter, got %#v", result.Target.Interpreter)
	}
	if result.Target.Command != script {
		t.Fatalf("expected script to run directly, got command %q", result.Target.Command)
	}
}

func TestCaptureScriptSupportsExplicitInterpreter(t *testing.T) {
	t.Parallel()
	skipWindowsScriptTest(t)
	script := writeTempScript(t, "explicit.portraiture-sh", "printf \"$1\"")
	portraitist := New(Options{})
	result := portraitist.CaptureScript(
		context.Background(),
		script,
		[]string{"via-interpreter"},
		Options{Interpreter: &Interpreter{Command: "/bin/sh"}},
	)

	if !result.Ok {
		t.Fatalf("expected capture to succeed: %#v", result.Error)
	}
	if result.Value != "via-interpreter" {
		t.Fatalf("expected interpreter output, got %q", result.Value)
	}
	if result.Target.Command != "/bin/sh" {
		t.Fatalf("expected interpreter command, got %q", result.Target.Command)
	}
	if result.Target.Script != script {
		t.Fatalf("expected target script %q, got %q", script, result.Target.Script)
	}
}

func TestInterpreterArgsPrecedeScriptPath(t *testing.T) {
	t.Parallel()
	skipWindowsScriptTest(t)
	script := writeTempScript(t, "spliced.testext", "ignored")
	result := CaptureScript(
		context.Background(),
		script,
		[]string{"C"},
		Options{Interpreter: &Interpreter{Command: "echo", Args: []string{"A", "B"}}},
	)

	if !result.Ok {
		t.Fatalf("expected capture to succeed: %#v", result.Error)
	}
	expectedArgs := []string{"A", "B", script, "C"}
	if !slices.Equal(result.Target.Args, expectedArgs) {
		t.Fatalf("expected args %#v, got %#v", expectedArgs, result.Target.Args)
	}
	expectedOutput := "A B " + script + " C\n"
	if result.Value != expectedOutput {
		t.Fatalf("expected fixed args before script path, got %q", result.Value)
	}
}

func TestPortraitistSupportsDefaultInterpretersByExtension(t *testing.T) {
	t.Parallel()
	skipWindowsScriptTest(t)
	script := writeTempScript(t, "default.portraiture-sh", "printf \"$1\"")
	portraitist := New(Options{
		Interpreters: map[string]Interpreter{
			"portraiture-sh": {Command: "/bin/sh"},
		},
	})
	result := portraitist.CaptureScript(context.Background(), script, []string{"from-default"})

	if !result.Ok {
		t.Fatalf("expected capture to succeed: %#v", result.Error)
	}
	if result.Value != "from-default" {
		t.Fatalf("expected default interpreter output, got %q", result.Value)
	}
	if result.Target.Command != "/bin/sh" {
		t.Fatalf("expected interpreter command, got %q", result.Target.Command)
	}
}

func TestInterpreterPrecedence(t *testing.T) {
	t.Parallel()
	skipWindowsScriptTest(t)

	marked := func(marker string) Interpreter {
		return Interpreter{Command: "echo", Args: []string{marker}}
	}
	markedMap := func(marker string) map[string]Interpreter {
		return map[string]Interpreter{".pshx": marked(marker)}
	}

	tests := []struct {
		name        string
		constructor Options
		call        Options
		expected    string
	}{
		{
			name: "per-call interpreter beats everything",
			constructor: Options{
				Interpreter:  interpreterPointer(marked("ctor-interp")),
				Interpreters: markedMap("ctor-map"),
			},
			call: Options{
				Interpreter:  interpreterPointer(marked("call-interp")),
				Interpreters: markedMap("call-map"),
			},
			expected: "call-interp",
		},
		{
			name: "per-call interpreters map beats constructor interpreter",
			constructor: Options{
				Interpreter:  interpreterPointer(marked("ctor-interp")),
				Interpreters: markedMap("ctor-map"),
			},
			call:     Options{Interpreters: markedMap("call-map")},
			expected: "call-map",
		},
		{
			name: "constructor interpreter beats constructor interpreters map",
			constructor: Options{
				Interpreter:  interpreterPointer(marked("ctor-interp")),
				Interpreters: markedMap("ctor-map"),
			},
			expected: "ctor-interp",
		},
		{
			name:        "constructor interpreters map applies when nothing else set",
			constructor: Options{Interpreters: markedMap("ctor-map")},
			expected:    "ctor-map",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			script := writeTempScript(t, "precedence.pshx", "ignored")
			portraitist := New(test.constructor)
			result := portraitist.CaptureScript(context.Background(), script, nil, test.call)

			if !result.Ok {
				t.Fatalf("expected capture to succeed: %#v", result.Error)
			}
			if !strings.HasPrefix(result.Value, test.expected+" ") {
				t.Fatalf("expected interpreter marker %q, got output %q", test.expected, result.Value)
			}
		})
	}
}

func TestParserReadsStdoutByDefault(t *testing.T) {
	t.Parallel()
	type hostPortrait struct {
		Hostname string `json:"hostname"`
		Platform string `json:"platform"`
	}

	portraitist := helperPortraitist(Options{})
	result := WithParser(portraitist, func(text string, _ CaptureContext) (hostPortrait, error) {
		var value hostPortrait
		err := json.Unmarshal([]byte(text), &value)
		return value, err
	}).Process(context.Background(), helperProgram(), helperArgs("json"))

	if !result.Ok {
		t.Fatalf("expected parser capture to succeed: %#v", result.Error)
	}
	if result.Value.Hostname != "local" {
		t.Fatalf("expected hostname local, got %q", result.Value.Hostname)
	}
}

func TestParseInputCanParseCombinedOutput(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := WithParser(portraitist, func(text string, _ CaptureContext) (string, error) {
		return text, nil
	}).Process(
		context.Background(),
		helperProgram(),
		helperArgs("out-err"),
		Options{ParseInput: ParseCombined},
	)

	if !result.Ok {
		t.Fatalf("expected combined parser capture to succeed: %#v", result.Error)
	}
	if result.Value != "outerr" && result.Value != "errout" {
		t.Fatalf("expected combined output, got %q", result.Value)
	}
}

func TestParseInputCanParseStderr(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := WithParser(portraitist, func(text string, _ CaptureContext) (string, error) {
		return "parsed:" + text, nil
	}).Process(
		context.Background(),
		helperProgram(),
		helperArgs("stderr", "warning"),
		Options{ParseInput: ParseStderr},
	)

	if !result.Ok {
		t.Fatalf("expected stderr parser capture to succeed: %#v", result.Error)
	}
	if result.Value != "parsed:warning" {
		t.Fatalf("expected parser to read stderr, got %q", result.Value)
	}
}

func TestParseInputConstructorDefaultAndPerCallOverride(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{ParseInput: ParseStderr})
	identity := func(text string, _ CaptureContext) (string, error) {
		return text, nil
	}

	fromDefault := WithParser(portraitist, identity).Process(context.Background(), helperProgram(), helperArgs("out-err"))
	if !fromDefault.Ok || fromDefault.Value != "err" {
		t.Fatalf("expected constructor ParseInput to read stderr, got %q (%#v)", fromDefault.Value, fromDefault.Error)
	}

	overridden := WithParser(portraitist, identity).Process(
		context.Background(),
		helperProgram(),
		helperArgs("out-err"),
		Options{ParseInput: ParseStdout},
	)
	if !overridden.Ok || overridden.Value != "out" {
		t.Fatalf("expected per-call ParseInput to reset to stdout, got %q (%#v)", overridden.Value, overridden.Error)
	}
}

func TestParserFailureReturnsParseFailure(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := WithParser(portraitist, func(_ string, _ CaptureContext) (string, error) {
		return "", errors.New("nope")
	}).Process(context.Background(), helperProgram(), helperArgs("echo", "not-json"))

	if result.Ok {
		t.Fatal("expected parser failure")
	}
	if result.Error.Kind != ParseFailure {
		t.Fatalf("expected parse failure, got %s", result.Error.Kind)
	}
	if result.Stdout != "not-json" {
		t.Fatalf("expected stdout to be preserved, got %q", result.Stdout)
	}
}

func TestStderrCanFailResult(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("stderr", "warn"),
		Options{Stderr: StderrFail},
	)

	if result.Ok {
		t.Fatal("expected stderr failure")
	}
	if result.Error.Kind != StderrFailure {
		t.Fatalf("expected stderr failure, got %s", result.Error.Kind)
	}
	if result.Stderr != "warn" {
		t.Fatalf("expected stderr to be preserved, got %q", result.Stderr)
	}
}

func TestStderrPolicyConstructorDefaultAndPerCallReset(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{Stderr: StderrFail})

	fromDefault := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("stderr", "warn"))
	if fromDefault.Ok || fromDefault.Error.Kind != StderrFailure {
		t.Fatalf("expected constructor StderrFail default to apply, got %#v", fromDefault.Error)
	}

	reset := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("stderr", "warn"),
		Options{Stderr: StderrCapture},
	)
	if !reset.Ok {
		t.Fatalf("expected per-call StderrCapture to reset the default: %#v", reset.Error)
	}
	if reset.Stderr != "warn" {
		t.Fatalf("expected stderr data, got %q", reset.Stderr)
	}
}

func TestNonzeroExitFailsByDefault(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("exit"))

	if result.Ok {
		t.Fatal("expected exit failure")
	}
	if result.Error.Kind != ExitFailure {
		t.Fatalf("expected exit failure, got %s", result.Error.Kind)
	}
	if result.ExitCode == nil || *result.ExitCode != 7 {
		t.Fatalf("expected exit code 7, got %#v", result.ExitCode)
	}
	if result.Stdout != "before" || result.Stderr != "bad" {
		t.Fatalf("expected captured output to be preserved, got stdout=%q stderr=%q", result.Stdout, result.Stderr)
	}
}

func TestNonzeroExitCanBeCollectedAsSuccess(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("exit"),
		Options{FailOnNonZeroExit: Bool(false)},
	)

	if !result.Ok {
		t.Fatalf("expected nonzero exit to be collected: %#v", result.Error)
	}
	if result.ExitCode == nil || *result.ExitCode != 7 {
		t.Fatalf("expected exit code 7, got %#v", result.ExitCode)
	}
	if result.Value != "before" {
		t.Fatalf("expected stdout value, got %q", result.Value)
	}
}

func TestFailOnNonZeroExitConstructorDefaultAndPerCallReset(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{FailOnNonZeroExit: Bool(false)})

	fromDefault := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("exit"))
	if !fromDefault.Ok {
		t.Fatalf("expected constructor FailOnNonZeroExit(false) to collect exit: %#v", fromDefault.Error)
	}

	reset := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("exit"),
		Options{FailOnNonZeroExit: Bool(true)},
	)
	if reset.Ok || reset.Error.Kind != ExitFailure {
		t.Fatalf("expected per-call Bool(true) to reset the default, got %#v", reset.Error)
	}
}

func TestFailureImplementsError(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("exit"))

	if result.Ok {
		t.Fatal("expected exit failure")
	}
	var err error = result.Error
	if !strings.Contains(err.Error(), "exit") {
		t.Fatalf("expected Error() to mention the failure kind, got %q", err.Error())
	}
	if result.Error.Cause == nil {
		t.Fatal("expected exit failure to carry a cause")
	}
	if !errors.Is(err, result.Error.Cause) {
		t.Fatal("expected errors.Is to see through Unwrap to the cause")
	}
	if errors.Unwrap(err) != result.Error.Cause {
		t.Fatal("expected Unwrap to return the cause")
	}
}

func TestTimeoutReturnsTimeoutFailure(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("sleep", "5000"),
		Options{Timeout: 50 * time.Millisecond},
	)

	if result.Ok {
		t.Fatal("expected timeout failure")
	}
	if result.Error.Kind != TimeoutFailure {
		t.Fatalf("expected timeout failure, got %s", result.Error.Kind)
	}
}

func TestTimeoutConstructorDefaultAndPerCallOverride(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{Timeout: 100 * time.Millisecond})

	fromDefault := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("sleep", "5000"))
	if fromDefault.Ok || fromDefault.Error.Kind != TimeoutFailure {
		t.Fatalf("expected constructor timeout default to apply, got %#v", fromDefault.Error)
	}

	longer := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("sleep", "5000"),
		Options{Timeout: 50 * time.Millisecond},
	)
	if longer.Ok || longer.Error.Kind != TimeoutFailure {
		t.Fatalf("expected per-call timeout to apply, got %#v", longer.Error)
	}
}

func TestNegativeTimeoutDisablesConstructorDefault(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{Timeout: 100 * time.Millisecond})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("sleep", "400"),
		Options{Timeout: -1},
	)

	if !result.Ok {
		t.Fatalf("expected negative per-call timeout to disable the default: %#v", result.Error)
	}
}

func TestParentContextDeadlineReturnsTimeoutFailure(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(ctx, helperProgram(), helperArgs("sleep", "5000"))

	if result.Ok {
		t.Fatal("expected timeout failure from parent deadline")
	}
	if result.Error.Kind != TimeoutFailure {
		t.Fatalf("expected timeout failure, got %s", result.Error.Kind)
	}
}

func TestParentContextCancellationReturnsCanceledFailure(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	timer := time.AfterFunc(100*time.Millisecond, cancel)
	defer timer.Stop()
	defer cancel()

	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(ctx, helperProgram(), helperArgs("sleep", "5000"))

	if result.Ok {
		t.Fatal("expected canceled failure")
	}
	if result.Error.Kind != CanceledFailure {
		t.Fatalf("expected canceled failure, got %s", result.Error.Kind)
	}
}

func TestOutputCapturedBeforeTimeoutIsPreserved(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("slow"),
		Options{Timeout: 750 * time.Millisecond},
	)

	if result.Ok {
		t.Fatal("expected timeout failure")
	}
	if result.Error.Kind != TimeoutFailure {
		t.Fatalf("expected timeout failure, got %s", result.Error.Kind)
	}
	if result.Stdout != "before" {
		t.Fatalf("expected pre-timeout output to be preserved, got %q", result.Stdout)
	}
	if runtime.GOOS != "windows" && result.Signal == "" {
		t.Fatal("expected the terminating signal to be reported on POSIX")
	}
}

func TestSpawnErrorReturnsSpawnFailure(t *testing.T) {
	t.Parallel()
	result := CaptureProcess(context.Background(), "__portraiture_missing_executable__", nil)

	if result.Ok {
		t.Fatal("expected spawn failure")
	}
	if result.Error.Kind != SpawnFailure {
		t.Fatalf("expected spawn failure, got %s", result.Error.Kind)
	}
}

func TestSpawnFailureEmitsStartAndFinishLogEvents(t *testing.T) {
	t.Parallel()
	logger := &recordingLogger{}
	result := CaptureProcess(
		context.Background(),
		"__portraiture_missing_executable__",
		nil,
		Options{Logger: logger},
	)

	if result.Ok {
		t.Fatal("expected spawn failure")
	}

	events := logger.snapshot()
	if len(events) != 2 {
		t.Fatalf("expected exactly start and finish events, got %#v", eventTypes(events))
	}
	if events[0].Type != LogStart {
		t.Fatalf("expected first event to be start, got %s", events[0].Type)
	}
	if events[1].Type != LogFinish {
		t.Fatalf("expected terminal event to be finish, got %s", events[1].Type)
	}
	if events[1].Ok {
		t.Fatal("expected finish event to report failure")
	}
}

func TestSignalKilledProcessReportsExitFailureWithSignal(t *testing.T) {
	t.Parallel()
	if runtime.GOOS == "windows" {
		t.Skip("POSIX signals are not available on Windows")
	}

	result := CaptureProcess(context.Background(), "/bin/sh", []string{"-c", "kill -KILL $$"})

	if result.Ok {
		t.Fatal("expected signal-killed process to fail")
	}
	if result.Error.Kind != ExitFailure {
		t.Fatalf("expected exit failure, got %s", result.Error.Kind)
	}
	if result.Signal != "SIGKILL" {
		t.Fatalf("expected signal SIGKILL, got %q", result.Signal)
	}
	if !strings.Contains(result.Error.Message, "SIGKILL") {
		t.Fatalf("expected message to name the signal, got %q", result.Error.Message)
	}
	if result.ExitCode != nil {
		t.Fatalf("expected no exit code for signal death, got %#v", result.ExitCode)
	}
}

func TestStandardInputIsSentToProcess(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("stdin"),
		Options{StandardInput: "hello stdin"},
	)

	if !result.Ok {
		t.Fatalf("expected stdin capture to succeed: %#v", result.Error)
	}
	if result.Value != "hello stdin" {
		t.Fatalf("expected stdin to be echoed, got %q", result.Value)
	}
}

func TestStandardInputConstructorDefaultAndPerCallOverride(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{StandardInput: "from-ctor"})

	fromDefault := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("stdin"))
	if !fromDefault.Ok || fromDefault.Value != "from-ctor" {
		t.Fatalf("expected constructor stdin default, got %q (%#v)", fromDefault.Value, fromDefault.Error)
	}

	overridden := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("stdin"),
		Options{StandardInput: "from-call"},
	)
	if !overridden.Ok || overridden.Value != "from-call" {
		t.Fatalf("expected per-call stdin override, got %q (%#v)", overridden.Value, overridden.Error)
	}
}

func TestUseShellConstructorDefaultAndPerCallOverride(t *testing.T) {
	t.Parallel()
	if runtime.GOOS == "windows" {
		t.Skip("test fixture uses a POSIX command")
	}

	portraitist := New(Options{UseShell: Bool(false)})

	fromDefault := portraitist.CaptureCommand(context.Background(), "printf shell-on")
	if fromDefault.Ok || fromDefault.Error.Kind != SpawnFailure {
		t.Fatalf("expected constructor UseShell(false) to disable the shell, got %#v", fromDefault.Error)
	}

	overridden := portraitist.CaptureCommand(context.Background(), "printf shell-on", Options{UseShell: Bool(true)})
	if !overridden.Ok || overridden.Value != "shell-on" {
		t.Fatalf("expected per-call UseShell(true) override, got %q (%#v)", overridden.Value, overridden.Error)
	}
}

func TestLoggerReceivesLifecycleAndStreamEvents(t *testing.T) {
	t.Parallel()
	logger := &recordingLogger{}
	portraitist := helperPortraitist(Options{Logger: logger})
	result := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("out-err"))

	if !result.Ok {
		t.Fatalf("expected logged capture to succeed: %#v", result.Error)
	}
	loggedEvents := eventTypes(logger.snapshot())
	if !slices.Contains(loggedEvents, LogStart) || !slices.Contains(loggedEvents, LogStdout) || !slices.Contains(loggedEvents, LogStderr) || !slices.Contains(loggedEvents, LogFinish) {
		t.Fatalf("expected lifecycle and stream events, got %#v", loggedEvents)
	}
}

func TestLoggerPerCallOverridesConstructorDefault(t *testing.T) {
	t.Parallel()
	constructorLogger := &recordingLogger{}
	perCallLogger := &recordingLogger{}
	portraitist := helperPortraitist(Options{Logger: constructorLogger})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("echo", "logged"),
		Options{Logger: perCallLogger},
	)

	if !result.Ok {
		t.Fatalf("expected capture to succeed: %#v", result.Error)
	}
	if len(constructorLogger.snapshot()) != 0 {
		t.Fatalf("expected constructor logger to be overridden, got %#v", eventTypes(constructorLogger.snapshot()))
	}
	if len(perCallLogger.snapshot()) == 0 {
		t.Fatal("expected per-call logger to receive events")
	}
}

func TestLoggerPanicDoesNotChangeCaptureResult(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{
		Logger: LoggerFunc(func(LogEvent) {
			panic("logger failed")
		}),
	})
	result := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("echo", "ok"))

	if !result.Ok {
		t.Fatalf("expected logger panic to be ignored: %#v", result.Error)
	}
	if result.Value != "ok" {
		t.Fatalf("expected ok, got %q", result.Value)
	}
}

func TestPortraitistCanSetDefaultWorkingDirectory(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	writeMarker(t, directory, "default")
	portraitist := helperPortraitist(Options{WorkingDirectory: directory})
	result := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("marker"))

	if !result.Ok {
		t.Fatalf("expected cwd capture to succeed: %#v", result.Error)
	}
	if result.Value != "default" {
		t.Fatalf("expected default cwd marker, got %q", result.Value)
	}
}

func TestPerCallWorkingDirectoryOverridesPortraitistDefault(t *testing.T) {
	t.Parallel()
	defaultDirectory := t.TempDir()
	overrideDirectory := t.TempDir()
	writeMarker(t, defaultDirectory, "default")
	writeMarker(t, overrideDirectory, "override")
	portraitist := helperPortraitist(Options{WorkingDirectory: defaultDirectory})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("marker"),
		Options{WorkingDirectory: overrideDirectory},
	)

	if !result.Ok {
		t.Fatalf("expected cwd override capture to succeed: %#v", result.Error)
	}
	if result.Value != "override" {
		t.Fatalf("expected override cwd marker, got %q", result.Value)
	}
}

func TestEnvironmentAugmentsParentEnvironment(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{
		Environment: map[string]string{
			"PORTRAITURE_CTOR":   "from-ctor",
			"PORTRAITURE_SHARED": "from-ctor",
		},
	})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("env", "PATH", "PORTRAITURE_CTOR", "PORTRAITURE_SHARED", "PORTRAITURE_CALL"),
		Options{
			Environment: map[string]string{
				"PORTRAITURE_SHARED": "from-call",
				"PORTRAITURE_CALL":   "from-call",
			},
		},
	)

	if !result.Ok {
		t.Fatalf("expected env capture to succeed: %#v", result.Error)
	}

	parts := strings.Split(result.Value, "|")
	if len(parts) != 4 {
		t.Fatalf("expected four env values, got %#v", parts)
	}
	if parts[0] == "" || parts[0] != os.Getenv("PATH") {
		t.Fatalf("expected parent PATH to be preserved, got %q", parts[0])
	}
	if parts[1] != "from-ctor" {
		t.Fatalf("expected constructor env value, got %q", parts[1])
	}
	if parts[2] != "from-call" {
		t.Fatalf("expected per-call env to override constructor env, got %q", parts[2])
	}
	if parts[3] != "from-call" {
		t.Fatalf("expected per-call env value, got %q", parts[3])
	}
}

func TestMultipleVariadicOptionsMergeLeftToRight(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("env", "PORTRAITURE_MERGE_A", "PORTRAITURE_MERGE_B"),
		Options{Environment: map[string]string{"PORTRAITURE_MERGE_A": "first"}, Stderr: StderrFail},
		Options{Environment: map[string]string{"PORTRAITURE_MERGE_B": "second"}},
		Options{Environment: map[string]string{"PORTRAITURE_MERGE_A": "third"}, Stderr: StderrCapture},
	)

	if !result.Ok {
		t.Fatalf("expected merged options capture to succeed: %#v", result.Error)
	}
	if result.Value != "third|second" {
		t.Fatalf("expected later options to win field by field, got %q", result.Value)
	}

	stderrResult := portraitist.CaptureProcess(
		context.Background(),
		helperProgram(),
		helperArgs("stderr", "warn"),
		Options{Stderr: StderrFail},
		Options{Stderr: StderrCapture},
	)
	if !stderrResult.Ok {
		t.Fatalf("expected later Stderr option to win, got %#v", stderrResult.Error)
	}
}

func TestResultMetadataIsPopulated(t *testing.T) {
	t.Parallel()
	portraitist := helperPortraitist(Options{})
	result := portraitist.CaptureProcess(context.Background(), helperProgram(), helperArgs("out-err"))

	if !result.Ok {
		t.Fatalf("expected capture to succeed: %#v", result.Error)
	}
	if result.Output != "outerr" && result.Output != "errout" {
		t.Fatalf("expected combined output, got %q", result.Output)
	}

	var stdoutText, stderrText string
	for _, chunk := range result.Chunks {
		switch chunk.Stream {
		case Stdout:
			stdoutText += chunk.Text
		case Stderr:
			stderrText += chunk.Text
		}
	}
	if stdoutText != "out" || stderrText != "err" {
		t.Fatalf("expected chunks per stream, got stdout=%q stderr=%q", stdoutText, stderrText)
	}
	if result.Duration <= 0 {
		t.Fatalf("expected positive duration, got %s", result.Duration)
	}
	if result.Signal != "" {
		t.Fatalf("expected no signal for normal exit, got %q", result.Signal)
	}
	if result.ExitCode == nil || *result.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %#v", result.ExitCode)
	}
}

func TestLargeOutputIsCapturedExactly(t *testing.T) {
	t.Parallel()
	const size = 64 * 1024
	portraitist := helperPortraitist(Options{})

	for attempt := 0; attempt < 8; attempt++ {
		result := portraitist.CaptureProcess(
			context.Background(),
			helperProgram(),
			helperArgs("big", strconv.Itoa(size)),
		)

		if !result.Ok {
			t.Fatalf("attempt %d: expected capture to succeed: %#v", attempt, result.Error)
		}
		if len(result.Stdout) != size {
			t.Fatalf("attempt %d: expected %d bytes of stdout, got %d", attempt, size, len(result.Stdout))
		}
		if len(result.Value) != size {
			t.Fatalf("attempt %d: expected %d bytes in value, got %d", attempt, size, len(result.Value))
		}
	}
}

func TestPackageLevelParsedCaptures(t *testing.T) {
	t.Parallel()
	atoi := func(text string, _ CaptureContext) (int, error) {
		return strconv.Atoi(strings.TrimSpace(text))
	}

	command := CaptureCommandParsed(context.Background(), printfCommand("42"), atoi)
	if !command.Ok || command.Value != 42 {
		t.Fatalf("expected parsed command value 42, got %d (%#v)", command.Value, command.Error)
	}

	process := CaptureProcessParsed(
		context.Background(),
		helperProgram(),
		helperArgs("echo", "7"),
		atoi,
		Options{Environment: helperEnvironment()},
	)
	if !process.Ok || process.Value != 7 {
		t.Fatalf("expected parsed process value 7, got %d (%#v)", process.Value, process.Error)
	}

	upper := CaptureWithParser(func(text string, _ CaptureContext) (string, error) {
		return strings.ToUpper(text), nil
	}).Command(context.Background(), printfCommand("shout"))
	if !upper.Ok || upper.Value != "SHOUT" {
		t.Fatalf("expected CaptureWithParser value SHOUT, got %q (%#v)", upper.Value, upper.Error)
	}
}

func TestPackageLevelCaptureScriptParsed(t *testing.T) {
	t.Parallel()
	skipWindowsScriptTest(t)
	script := writeTempScript(t, "answer.sh", "#!/bin/sh\nprintf '9'\n")
	result := CaptureScriptParsed(
		context.Background(),
		script,
		nil,
		func(text string, _ CaptureContext) (int, error) {
			return strconv.Atoi(text)
		},
	)

	if !result.Ok || result.Value != 9 {
		t.Fatalf("expected parsed script value 9, got %d (%#v)", result.Value, result.Error)
	}
}

func TestWithParserNilPortraitistAndNilParser(t *testing.T) {
	t.Parallel()
	result := WithParser[string](nil, nil).Command(context.Background(), printfCommand("ignored"))

	if result.Ok {
		t.Fatal("expected nil parser to fail")
	}
	if result.Error.Kind != ParseFailure {
		t.Fatalf("expected parse failure, got %s", result.Error.Kind)
	}
	if result.Error.Message != "parser is nil" {
		t.Fatalf("expected missing-parser message, got %q", result.Error.Message)
	}
	if result.Stdout != "ignored" {
		t.Fatalf("expected capture output to be preserved, got %q", result.Stdout)
	}
}

func TestBoolReturnsPointerToValue(t *testing.T) {
	t.Parallel()
	truthy := Bool(true)
	falsy := Bool(false)

	if truthy == nil || !*truthy {
		t.Fatalf("expected pointer to true, got %#v", truthy)
	}
	if falsy == nil || *falsy {
		t.Fatalf("expected pointer to false, got %#v", falsy)
	}
}

type recordingLogger struct {
	gate   sync.Mutex
	events []LogEvent
}

func (logger *recordingLogger) LogCapture(event LogEvent) {
	logger.gate.Lock()
	defer logger.gate.Unlock()
	logger.events = append(logger.events, event)
}

func (logger *recordingLogger) snapshot() []LogEvent {
	logger.gate.Lock()
	defer logger.gate.Unlock()
	return slices.Clone(logger.events)
}

func eventTypes(events []LogEvent) []LogEventType {
	types := make([]LogEventType, 0, len(events))
	for _, event := range events {
		types = append(types, event.Type)
	}
	return types
}

func interpreterPointer(value Interpreter) *Interpreter {
	return &value
}

func helperProgram() string {
	path, err := os.Executable()
	if err == nil {
		return path
	}

	return os.Args[0]
}

func helperArgs(args ...string) []string {
	values := []string{"-test.run=TestHelperProcess", "--"}
	values = append(values, args...)
	return values
}

func helperPortraitist(options Options) *Portraitist {
	options.Environment = mergeEnvironment(helperEnvironment(), options.Environment)
	return New(options)
}

func helperEnvironment() map[string]string {
	return map[string]string{"PORTRAITURE_GO_HELPER_PROCESS": "1"}
}

func printfCommand(text string) string {
	if runtime.GOOS == "windows" {
		return "<nul set /p dummy=" + text
	}

	return "printf " + shellQuote(text)
}

func writeTempScript(t *testing.T, name string, contents string) string {
	t.Helper()
	directory := t.TempDir()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte(contents), 0o700); err != nil {
		t.Fatalf("write script: %v", err)
	}
	return path
}

func writeMarker(t *testing.T, directory string, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(directory, "marker.txt"), []byte(text), 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}
}

func skipWindowsScriptTest(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("script fixture is Unix-only")
	}
}
