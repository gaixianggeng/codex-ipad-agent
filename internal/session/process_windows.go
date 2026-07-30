//go:build windows

package session

import (
	"context"
	"os/exec"
	"strconv"
	"time"
)

const sessionTaskkillTimeout = 5 * time.Second

func terminateSessionProcessTree(cmd *exec.Cmd, force bool) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), sessionTaskkillTimeout)
	defer cancel()
	args := []string{"/PID", strconv.Itoa(cmd.Process.Pid), "/T"}
	if force {
		args = append(args, "/F")
	}
	if err := exec.CommandContext(ctx, "taskkill.exe", args...).Run(); err != nil && force {
		_ = cmd.Process.Kill()
	}
}
