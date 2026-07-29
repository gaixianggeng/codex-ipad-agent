//go:build windows

package setup

import "os"

// Temp files are created in the user's AppData-backed config directory and
// inherit its ACL. Windows does not map chmod(0600) to a restrictive ACL.
func makePrivateFile(_ *os.File) error { return nil }
