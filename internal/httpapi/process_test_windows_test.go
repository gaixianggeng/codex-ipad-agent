//go:build windows

package httpapi

import (
	"context"
	"os/exec"
	"strconv"
	"syscall"
)

const stillActiveExitCode = 259

func testProcessRunning(pid int) bool {
	if pid <= 0 {
		return false
	}
	handle, err := syscall.OpenProcess(syscall.PROCESS_QUERY_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(handle)
	var exitCode uint32
	return syscall.GetExitCodeProcess(handle, &exitCode) == nil && exitCode == stillActiveExitCode
}

func killTestProcessTree(pid int) {
	if pid <= 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), gatewayTaskkillTimeout)
	defer cancel()
	_ = exec.CommandContext(ctx, "taskkill.exe", "/PID", strconv.Itoa(pid), "/T", "/F").Run()
}
