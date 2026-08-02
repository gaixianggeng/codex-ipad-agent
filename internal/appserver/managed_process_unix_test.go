//go:build !windows

package appserver

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestConfigureManagedCommandCreatesUnixProcessGroup(t *testing.T) {
	cmd := exec.Command("sh", "-c", "exit 0")
	configureManagedCommand(cmd)
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.Setpgid {
		t.Fatalf("managed app-server 必须使用独立 Unix 进程组：%#v", cmd.SysProcAttr)
	}
}

func TestTerminateManagedProcessKillsUnixProcessGroup(t *testing.T) {
	childPIDPath := filepath.Join(t.TempDir(), "child.pid")
	cmd := exec.Command("sh", "-c", `sleep 30 & echo $! > "$1"; wait`, "sh", childPIDPath)
	configureManagedCommand(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatalf("启动测试进程组失败：%v", err)
	}
	var childPID int
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		body, err := os.ReadFile(childPIDPath)
		if err == nil {
			childPID, err = strconv.Atoi(strings.TrimSpace(string(body)))
			if err != nil {
				t.Fatalf("解析 child PID 失败：%v", err)
			}
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if childPID <= 0 {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Wait()
		t.Fatal("测试 helper 没有写入 child PID")
	}
	t.Cleanup(func() { _ = syscall.Kill(childPID, syscall.SIGKILL) })

	terminateManagedProcess(cmd)
	err := cmd.Wait()
	if err == nil {
		t.Fatal("被强制终止的 managed 进程不应正常退出")
	}
	if cmd.ProcessState == nil {
		t.Fatal("managed 进程没有 ProcessState")
	}
	if status, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); !ok || !status.Signaled() {
		t.Fatalf("managed 进程应被信号终止：%v", cmd.ProcessState)
	}
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		err = syscall.Kill(childPID, 0)
		if errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("managed 子进程仍存活：pid=%d err=%v", childPID, err)
}

func TestManagedWebSocketShutdownKillsGroupAfterLauncherExit(t *testing.T) {
	childPIDPath := filepath.Join(t.TempDir(), "child.pid")
	cmd := exec.Command("sh", "-c", `trap '' HUP; sleep 30 & echo $! > "$1"; exit 0`, "sh", childPIDPath)
	configureManagedCommand(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatalf("启动提前退出的 launcher 失败：%v", err)
	}
	waitCh := make(chan error, 1)
	doneCh := make(chan struct{})
	go func() {
		waitCh <- cmd.Wait()
		close(doneCh)
	}()

	childPID := waitForChildPID(t, childPIDPath)
	t.Cleanup(func() { _ = syscall.Kill(childPID, syscall.SIGKILL) })
	select {
	case <-doneCh:
	case <-time.After(2 * time.Second):
		t.Fatal("launcher 没有按预期提前退出")
	}

	process := &ManagedWebSocketProcess{cmd: cmd, waitCh: waitCh, doneCh: doneCh}
	if err := process.Shutdown(context.Background()); err != nil {
		t.Fatalf("Shutdown 失败：%v", err)
	}
	waitForProcessGone(t, childPID)
}

func TestStartManagedWebSocketKillsGroupWhenLauncherExitsEarly(t *testing.T) {
	dir := t.TempDir()
	childPIDPath := filepath.Join(dir, "child.pid")
	fakeCodex := writeFakeCodexAppServer(t, dir, `
trap '' HUP
sleep 30 &
echo $! > "$MIMI_TEST_CHILD_PID_PATH"
exit 0
`)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	process, err := StartManagedWebSocket(ctx, ManagedWebSocketOptions{
		CodexBin:       fakeCodex,
		Env:            map[string]string{"MIMI_TEST_CHILD_PID_PATH": childPIDPath},
		Listen:         "ws://127.0.0.1:4222",
		EarlyExitGrace: 2 * time.Second,
	})
	if process != nil {
		_ = process.Shutdown(context.Background())
		t.Fatal("提前退出时不应返回 managed process")
	}
	if err == nil || !strings.Contains(err.Error(), "启动后立即退出") {
		t.Fatalf("提前退出应返回明确错误，got=%v", err)
	}

	childPID := waitForChildPID(t, childPIDPath)
	t.Cleanup(func() { _ = syscall.Kill(childPID, syscall.SIGKILL) })
	waitForProcessGone(t, childPID)
}

func waitForChildPID(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		body, err := os.ReadFile(path)
		if err == nil {
			pid, parseErr := strconv.Atoi(strings.TrimSpace(string(body)))
			if parseErr != nil {
				t.Fatalf("解析 child PID 失败：%v", parseErr)
			}
			if pid > 0 {
				return pid
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("测试 helper 没有写入 child PID")
	return 0
}

func waitForProcessGone(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		err := syscall.Kill(pid, 0)
		if errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("managed 子进程仍存活：pid=%d", pid)
}
