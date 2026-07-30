//go:build windows

package appserver

import (
	"os/exec"
	"syscall"
	"testing"
)

func TestConfigureManagedCommandCreatesWindowsProcessGroup(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/d", "/c", "exit", "/b", "0")
	configureManagedCommand(cmd)
	if cmd.SysProcAttr == nil || cmd.SysProcAttr.CreationFlags&syscall.CREATE_NEW_PROCESS_GROUP == 0 {
		t.Fatalf("managed app-server must start in a new Windows process group: %#v", cmd.SysProcAttr)
	}
}
