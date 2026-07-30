//go:build windows

package session

import (
	"os/exec"
	"testing"
	"time"
)

func TestTerminateSessionProcessTreeWindows(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "ping.exe", "-t", "127.0.0.1")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start process: %v", err)
	}
	wait := make(chan error, 1)
	go func() { wait <- cmd.Wait() }()
	t.Cleanup(func() {
		terminateSessionProcessTree(cmd, true)
		select {
		case <-wait:
		case <-time.After(10 * time.Second):
		}
	})

	terminateSessionProcessTree(cmd, true)
	select {
	case <-wait:
	case <-time.After(10 * time.Second):
		t.Fatal("process did not exit after forced tree termination")
	}
}
