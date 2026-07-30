//go:build !windows

package setup

import "os/exec"

func lookupUsableCodexExecutable(file string) (string, error) {
	return exec.LookPath(file)
}
