//go:build windows

package httpapi

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func platformFilesystemObjectIdentity(path string) (string, bool) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", false
	}
	handle, err := syscall.CreateFile(
		syscall.StringToUTF16Ptr(path),
		syscall.GENERIC_READ,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		nil,
		syscall.OPEN_EXISTING,
		syscall.FILE_FLAG_BACKUP_SEMANTICS,
		0,
	)
	if err != nil {
		return "", false
	}
	defer syscall.CloseHandle(handle)
	var stat syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(handle, &stat); err != nil {
		return "", false
	}
	return fmt.Sprintf("volume=%d;index=%d:%d;type=%s", stat.VolumeSerialNumber, stat.FileIndexHigh, stat.FileIndexLow, info.Mode().Type()), true
}

func sameFilesystemPath(left, right string) bool {
	return strings.EqualFold(filepath.Clean(left), filepath.Clean(right))
}
