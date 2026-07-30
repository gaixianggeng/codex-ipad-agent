//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const processQueryLimitedInformation = 0x1000

var (
	windowsIdentityKernel32            = syscall.NewLazyDLL("kernel32.dll")
	windowsOpenProcess                 = windowsIdentityKernel32.NewProc("OpenProcess")
	windowsQueryFullProcessImageNameW  = windowsIdentityKernel32.NewProc("QueryFullProcessImageNameW")
	windowsCloseHandle                 = windowsIdentityKernel32.NewProc("CloseHandle")
	windowsManagedPIDMatchesExecutable = managedPIDMatchesCurrentExecutable
)

func managedPIDMatchesCurrentExecutable(pid int) bool {
	handle, _, _ := windowsOpenProcess.Call(processQueryLimitedInformation, 0, uintptr(pid))
	if handle == 0 {
		return false
	}
	defer windowsCloseHandle.Call(handle)

	buffer := make([]uint16, 32768)
	size := uint32(len(buffer))
	ok, _, _ := windowsQueryFullProcessImageNameW.Call(
		handle,
		0,
		uintptr(unsafe.Pointer(&buffer[0])),
		uintptr(unsafe.Pointer(&size)),
	)
	if ok == 0 || size == 0 {
		return false
	}
	runningPath := syscall.UTF16ToString(buffer[:size])
	currentPath, err := os.Executable()
	if err != nil {
		return false
	}
	return strings.EqualFold(filepath.Clean(runningPath), filepath.Clean(currentPath))
}
