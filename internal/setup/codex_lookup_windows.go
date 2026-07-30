//go:build windows

package setup

import (
	"context"
	"io"
	"os/exec"
	"time"
)

// WindowsApps package resources can be discoverable by LookPath while their
// ACL denies CreateProcess to an ordinary desktop process. Probe candidates
// before persisting them so the service never records an unusable path.
func lookupUsableCodexExecutable(file string) (string, error) {
	path, err := exec.LookPath(file)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "--version")
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return "", exec.ErrNotFound
	}
	return path, nil
}
