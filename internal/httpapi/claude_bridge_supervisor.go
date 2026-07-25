package httpapi

import (
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// claudeBridgeStartTimeout bounds how long we wait for a freshly spawned bridge
// to bind its socket before declaring the start failed. Overridable so tests
// can exercise the timeout path without a ten-second wait.
var claudeBridgeStartTimeout = 10 * time.Second

// macOS caps sockaddr_un.sun_path at 104 bytes. A socket we cannot bind is a
// confusing failure deep inside the bridge, so reject the path up front.
const claudeBridgeMaxSocketPath = 100

// claudeBridgeSupervisor owns a single resident `alleycat-claude-bridge`
// running in `--socket` mode.
//
// The bridge used to be spawned per WebSocket connection, which tied every
// piece of in-flight state to the life of a phone's network link: dropping the
// connection killed the process, and with it the running turn, the Claude
// child processes and the replay ring that exists precisely to survive a
// reconnect. Keeping one process behind a socket lets a connection come and go
// while the turn keeps running.
type claudeBridgeSupervisor struct {
	mu         sync.Mutex
	dir        string
	socketPath string
	cmd        *exec.Cmd
	// done is closed by the reaper once the process has been waited on. It is
	// the only exit signal anyone else waits for: cmd.Wait has exactly one
	// consumer, so startup and shutdown cannot starve each other of it.
	done chan struct{}
	// exited is set by the reaper once the process is gone, so the next
	// ensure() starts a replacement instead of dialing a dead socket.
	exited  bool
	stopped bool

	// cursors records, per session key, the highest sequence number we
	// finished relaying, so a reconnecting client resumes from there rather
	// than from what the bridge merely wrote to the socket. Bounded because
	// the keys come from clients.
	cursorMu   sync.Mutex
	cursors    map[string]uint64
	cursorFIFO []string
}

// claudeBridgeMaxCursors caps the resume-cursor table. Far above the handful
// of devices a single agentd serves; the bound only exists so client-chosen
// keys cannot grow the map without limit.
const claudeBridgeMaxCursors = 64

func newClaudeBridgeSupervisor() *claudeBridgeSupervisor {
	return &claudeBridgeSupervisor{cursors: map[string]uint64{}}
}

// noteDelivered advances the resume cursor for a session. Sequence numbers
// only move forward; a replayed frame must not rewind it.
func (s *claudeBridgeSupervisor) noteDelivered(sessionKey string, seq uint64) {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	if current, ok := s.cursors[sessionKey]; ok {
		if seq > current {
			s.cursors[sessionKey] = seq
		}
		return
	}
	if len(s.cursorFIFO) >= claudeBridgeMaxCursors {
		oldest := s.cursorFIFO[0]
		s.cursorFIFO = s.cursorFIFO[1:]
		delete(s.cursors, oldest)
	}
	s.cursorFIFO = append(s.cursorFIFO, sessionKey)
	s.cursors[sessionKey] = seq
}

func (s *claudeBridgeSupervisor) resumeCursor(sessionKey string) (uint64, bool) {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	seq, ok := s.cursors[sessionKey]
	return seq, ok
}

// forgetCursor drops a cursor the bridge told us is no longer replayable, so
// the next attach starts clean instead of asking for a sequence below the ring
// floor again.
func (s *claudeBridgeSupervisor) forgetCursor(sessionKey string) {
	s.cursorMu.Lock()
	defer s.cursorMu.Unlock()
	delete(s.cursors, sessionKey)
	for i, key := range s.cursorFIFO {
		if key == sessionKey {
			s.cursorFIFO = append(s.cursorFIFO[:i], s.cursorFIFO[i+1:]...)
			break
		}
	}
}

// ensure returns the socket path of a running bridge, starting one if needed.
func (s *claudeBridgeSupervisor) ensure(bin string, args []string, env map[string]string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		return "", errors.New("Claude bridge 管理器已停止")
	}
	if s.cmd != nil && !s.exited {
		return s.socketPath, nil
	}
	if s.cmd != nil {
		log.Printf("claude bridge exited; starting a replacement")
		s.reset()
	}
	if err := s.start(bin, args, env); err != nil {
		s.reset()
		return "", err
	}
	return s.socketPath, nil
}

// start spawns the bridge and blocks until its socket accepts a connection.
// Caller must hold s.mu.
func (s *claudeBridgeSupervisor) start(bin string, args []string, env map[string]string) error {
	if s.dir == "" {
		dir, err := os.MkdirTemp("", "mimi-claude")
		if err != nil {
			return fmt.Errorf("创建 Claude bridge 运行目录失败：%w", err)
		}
		s.dir = dir
	}
	socketPath := filepath.Join(s.dir, "bridge.sock")
	if len(socketPath) > claudeBridgeMaxSocketPath {
		return fmt.Errorf("Claude bridge socket 路径过长（%d 字节）：%s", len(socketPath), socketPath)
	}
	// A leftover node from a crashed predecessor would make bind fail.
	if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("清理 Claude bridge socket 失败：%w", err)
	}

	cmd := exec.Command(bin, append(append([]string{}, args...), "--socket", socketPath)...)
	cmd.Env = buildClaudeBridgeEnv(env)
	configureGatewayCommandProcessGroup(cmd)
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("创建 Claude bridge stderr 失败：%w", err)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动 Claude bridge 失败：%w", err)
	}
	go captureClaudeBridgeStderr(stderr)

	done := make(chan struct{})
	s.cmd = cmd
	s.done = done
	s.socketPath = socketPath
	s.exited = false
	go s.reap(cmd, done)

	if err := waitForClaudeBridgeSocket(socketPath, done, claudeBridgeStartTimeout); err != nil {
		// Kill and walk away without waiting on the reaper: we hold s.mu, and
		// the reaper takes it before closing done, so waiting here would
		// deadlock the supervisor — and with it every later ensure() — for a
		// bridge that merely failed to bind in time. The reaper still runs and
		// still reaps; ensure() clears the bookkeeping, and the `s.cmd == cmd`
		// guard keeps this dead process from clobbering its replacement.
		terminateGatewayProcessGroup(cmd, syscall.SIGKILL)
		return err
	}
	return nil
}

// reap waits on the process and marks the supervisor dirty so a later ensure()
// restarts it. It only touches shared state while cmd is still the current
// process, so a shutdown-then-restart cycle cannot have an old reaper clobber
// new state.
func (s *claudeBridgeSupervisor) reap(cmd *exec.Cmd, done chan struct{}) {
	err := cmd.Wait()
	s.mu.Lock()
	if s.cmd == cmd {
		s.exited = true
	}
	s.mu.Unlock()
	if err != nil {
		log.Printf("claude bridge exited err=%v", err)
	} else {
		log.Printf("claude bridge exited")
	}
	close(done)
}

// dial opens a connection to the resident bridge. Each WebSocket connection
// gets its own socket connection; the bridge multiplexes them onto sessions.
func (s *claudeBridgeSupervisor) dial() (net.Conn, error) {
	s.mu.Lock()
	socketPath := s.socketPath
	alive := s.cmd != nil && !s.exited
	s.mu.Unlock()
	if !alive || socketPath == "" {
		return nil, errors.New("Claude bridge 未运行")
	}
	// The socket node exists from bind, but listen lands a moment later, so a
	// dial racing a just-started bridge can see ECONNREFUSED. Retry briefly.
	deadline := time.Now().Add(2 * time.Second)
	for {
		conn, err := net.DialTimeout("unix", socketPath, time.Second)
		if err == nil {
			return conn, nil
		}
		if time.Now().After(deadline) {
			return nil, err
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// shutdown terminates the bridge process group and removes the socket
// directory. The supervisor refuses to start again afterwards.
func (s *claudeBridgeSupervisor) shutdown() {
	s.mu.Lock()
	s.stopped = true
	cmd, done, exited, dir := s.cmd, s.done, s.exited, s.dir
	s.dir = ""
	s.reset()
	s.mu.Unlock()

	// Terminate outside the lock: the reaper takes it on its way out.
	if cmd != nil && !exited {
		// The bridge spawns Claude Code children; signal the whole group so a
		// restart does not inherit orphans still holding the workspace.
		terminateClaudeBridge(cmd, done)
	}
	if dir != "" {
		_ = os.RemoveAll(dir)
	}
}

// terminateClaudeBridge signals the whole process group, escalating to SIGKILL
// if the bridge does not go quietly. It waits on the reaper's done channel,
// which has no competing consumer.
func terminateClaudeBridge(cmd *exec.Cmd, done <-chan struct{}) {
	terminateGatewayProcessGroup(cmd, syscall.SIGTERM)
	select {
	case <-done:
		return
	case <-time.After(300 * time.Millisecond):
	}
	terminateGatewayProcessGroup(cmd, syscall.SIGKILL)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		log.Printf("claude bridge process did not exit after SIGKILL pid=%d", gatewayProcessID(cmd))
	}
}

// reset clears process bookkeeping without touching s.dir, which is reused
// across restarts. Caller must hold s.mu.
func (s *claudeBridgeSupervisor) reset() {
	s.cmd = nil
	s.done = nil
	s.socketPath = ""
	s.exited = false
}

// waitForClaudeBridgeSocket polls until the bridge has bound its socket, the
// process dies, or the deadline passes.
//
// It deliberately checks for the socket node rather than dialing it: a probe
// connection is a real bridge connection, and one that opens and closes at
// once would churn a session for nothing. dial retries instead, which also
// covers the sliver between bind and listen.
func waitForClaudeBridgeSocket(socketPath string, done <-chan struct{}, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		select {
		case <-done:
			return errors.New("Claude bridge 启动后立即退出")
		default:
		}
		if _, err := os.Stat(socketPath); err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Claude bridge 在 %s 内未监听 socket", timeout)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
