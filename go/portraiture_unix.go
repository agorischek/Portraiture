//go:build unix

package portraiture

import (
	"errors"
	"os"
	"os/exec"
	"sync/atomic"
	"syscall"
	"time"
)

// killEscalationDelay is how long the child process group is given to exit
// after SIGTERM before SIGKILL is sent.
const killEscalationDelay = time.Second

// setupCancellation starts the child as a process group leader and installs
// a cancel hook that terminates the whole group when the run context ends:
// SIGTERM first, escalating to SIGKILL after killEscalationDelay. This kills
// grandchildren too, so orphaned descendants cannot outlive a timeout or hold
// the output pipes open. WaitDelay is set as a final guard so Wait can never
// block forever on lingering I/O. The killed flag records that the hook
// actually fired, which runCapture uses to classify timeout and cancellation
// failures.
func setupCancellation(command *exec.Cmd, killed *atomic.Bool) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.WaitDelay = cancellationWaitDelay
	command.Cancel = func() error {
		killed.Store(true)

		process := command.Process
		if process == nil {
			return os.ErrProcessDone
		}

		group := -process.Pid
		if err := syscall.Kill(group, syscall.SIGTERM); err != nil {
			if errors.Is(err, syscall.ESRCH) {
				return os.ErrProcessDone
			}
			// Group signaling failed for another reason; fall back to
			// killing the direct child.
			return process.Kill()
		}

		time.AfterFunc(killEscalationDelay, func() {
			// Best effort: the group is normally gone by now, in which
			// case this is a harmless ESRCH.
			_ = syscall.Kill(group, syscall.SIGKILL)
		})

		return nil
	}
}

// processSignal reports the signal that terminated the process (for example
// "SIGTERM"), or "" when the process was not terminated by a signal or has
// not run.
func processSignal(command *exec.Cmd) string {
	state := command.ProcessState
	if state == nil {
		return ""
	}

	status, ok := state.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() {
		return ""
	}

	return signalName(status.Signal())
}

func signalName(signal syscall.Signal) string {
	switch signal {
	case syscall.SIGHUP:
		return "SIGHUP"
	case syscall.SIGINT:
		return "SIGINT"
	case syscall.SIGQUIT:
		return "SIGQUIT"
	case syscall.SIGILL:
		return "SIGILL"
	case syscall.SIGTRAP:
		return "SIGTRAP"
	case syscall.SIGABRT:
		return "SIGABRT"
	case syscall.SIGFPE:
		return "SIGFPE"
	case syscall.SIGKILL:
		return "SIGKILL"
	case syscall.SIGBUS:
		return "SIGBUS"
	case syscall.SIGSEGV:
		return "SIGSEGV"
	case syscall.SIGPIPE:
		return "SIGPIPE"
	case syscall.SIGALRM:
		return "SIGALRM"
	case syscall.SIGTERM:
		return "SIGTERM"
	default:
		return signal.String()
	}
}
