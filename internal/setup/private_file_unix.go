//go:build !windows

package setup

import "os"

func makePrivateFile(file *os.File) error { return file.Chmod(0o600) }
