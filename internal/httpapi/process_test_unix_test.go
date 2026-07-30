//go:build !windows

package httpapi

import "syscall"

func testProcessRunning(pid int) bool {
	return pid > 0 && syscall.Kill(pid, 0) == nil
}

func killTestProcessTree(pid int) {
	if pid > 0 {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
}
