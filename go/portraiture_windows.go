//go:build windows

package portraiture

import (
	"os"
	"os/exec"
	"sync/atomic"
)

// setupCancellation installs a cancel hook that kills the direct child when
// the run context ends and sets WaitDelay as a final guard so Wait can never
// block forever on lingering I/O. Windows has no POSIX process groups, so
// only the direct child is killed; grandchildren may outlive a timeout. The
// killed flag records that the hook actually fired, which runCapture uses to
// classify timeout and cancellation failures.
func setupCancellation(command *exec.Cmd, killed *atomic.Bool) {
	command.WaitDelay = cancellationWaitDelay
	command.Cancel = func() error {
		killed.Store(true)

		process := command.Process
		if process == nil {
			return os.ErrProcessDone
		}

		return process.Kill()
	}
}

// processSignal always reports "" on Windows, which does not expose POSIX
// termination signals.
func processSignal(_ *exec.Cmd) string {
	return ""
}
