package session

import (
	"os/exec"
	"testing"
)

func TestTerminateSessionProcessTreeHandlesMissingProcess(t *testing.T) {
	var nilCommand *exec.Cmd
	terminateSessionProcessTree(nilCommand, false)
	terminateSessionProcessTree(&exec.Cmd{}, true)
}
