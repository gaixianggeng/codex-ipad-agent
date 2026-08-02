//go:build !windows

package appserver

import (
	"os/exec"
	"syscall"
)

func configureManagedCommand(cmd *exec.Cmd) {
	if cmd != nil {
		// codex 可能是 Node/npm 包装器；独立进程组确保 Shutdown 能回收真实
		// app-server 子进程，而不只杀掉最外层 launcher。
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	}
}

func terminateManagedProcess(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return
	}
	if cmd.SysProcAttr != nil && cmd.SysProcAttr.Setpgid {
		if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err == nil || err == syscall.ESRCH {
			return
		}
	}
	_ = cmd.Process.Kill()
}
