package httpapi

import (
	"os"
	"os/exec"
	"testing"
)

func TestGatewayProcessFacadeHandlesMissingProcess(t *testing.T) {
	var nilCommand *exec.Cmd
	configureGatewayCommandProcessGroup(nilCommand)
	terminateGatewayProcessGroup(nilCommand, false)
	terminateGatewayProcessGroup(&exec.Cmd{}, true)

	if got := gatewayProcessID(nilCommand); got != 0 {
		t.Fatalf("gatewayProcessID(nil) = %d, want 0", got)
	}
	cmd := &exec.Cmd{Process: &os.Process{Pid: 1234}}
	if got := gatewayProcessID(cmd); got != 1234 {
		t.Fatalf("gatewayProcessID(cmd) = %d, want 1234", got)
	}
}
