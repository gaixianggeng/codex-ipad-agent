//go:build !windows

package session

import (
	"os/exec"
	"syscall"
)

func terminateSessionProcessTree(cmd *exec.Cmd, force bool) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return
	}
	signal := syscall.SIGTERM
	if force {
		signal = syscall.SIGKILL
	}
	_ = syscall.Kill(-cmd.Process.Pid, signal)
}
