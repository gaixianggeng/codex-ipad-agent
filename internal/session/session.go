package session

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/ring"
)

type Options struct {
	CodexBin     string
	DefaultArgs  []string
	Env          map[string]string
	OutputBuffer int
}

type Manager struct {
	options  Options
	mu       sync.Mutex
	sessions map[string]*Session
}

type Session struct {
	ID        string    `json:"id"`
	ProjectID string    `json:"project_id"`
	Project   string    `json:"project"`
	Dir       string    `json:"dir"`
	Title     string    `json:"title"`
	Status    string    `json:"status"`
	Source    string    `json:"source"`
	ResumeID  string    `json:"resume_id,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	cmd    *exec.Cmd
	ptmx   *os.File
	cancel context.CancelFunc
	buffer *ring.Buffer

	mu          sync.Mutex
	writeMu     sync.Mutex
	termCols    int
	termRows    int
	subscribers map[chan []byte]struct{}
	exit        ExitResult
	done        chan struct{}
}

const promptSubmitDelay = 180 * time.Millisecond

type ExitResult struct {
	Code   int    `json:"code"`
	Reason string `json:"reason"`
}

type CreateRequest struct {
	Project  projects.Project
	Prompt   string
	ResumeID string
	Title    string
	Cols     int
	Rows     int
}

func NewManager(options Options) *Manager {
	if options.CodexBin == "" {
		options.CodexBin = "codex"
	}
	if options.OutputBuffer <= 0 {
		options.OutputBuffer = 128 * 1024
	}
	return &Manager{options: options, sessions: map[string]*Session{}}
}

func (m *Manager) Create(req CreateRequest) (*Session, error) {
	if req.Cols < 20 || req.Cols > 300 {
		req.Cols = 120
	}
	if req.Rows < 5 || req.Rows > 100 {
		req.Rows = 32
	}

	id := ""
	if req.ResumeID != "" {
		id = "codex_" + req.ResumeID
		if existing, ok := m.Get(id); ok {
			if existing.Snapshot().Status == "running" {
				if prompt := strings.TrimSpace(req.Prompt); prompt != "" {
					// 旧的 iPad 状态可能还把这个线程当成 history；如果服务端已经有运行中的
					// resume session，继续复用它，但必须把本次输入写进 PTY，避免请求被静默吞掉。
					if err := existing.Write(prompt + "\r"); err != nil {
						return nil, err
					}
				}
				return existing, nil
			}
			m.remove(id)
		}
	} else {
		var err error
		id, err = newID()
		if err != nil {
			return nil, err
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	args := m.codexArgs(req)
	title := req.Title
	if title == "" {
		title = sessionTitle(req.Prompt)
	}

	cmd := exec.CommandContext(ctx, m.options.CodexBin, args...)
	cmd.Dir = req.Project.RealPath
	cmd.Env = buildEnv(m.options.Env)
	// creack/pty 会为子进程创建新的 session 和控制终端；不要额外设置 Setpgid，
	// macOS 下 Setsid + Setpgid 组合会导致 fork/exec 返回 operation not permitted。

	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: uint16(req.Rows), Cols: uint16(req.Cols)})
	if err != nil {
		cancel()
		return nil, fmt.Errorf("启动 Codex 失败：%w", err)
	}

	now := time.Now()
	s := &Session{
		ID:          id,
		ProjectID:   req.Project.ID,
		Project:     req.Project.Name,
		Dir:         req.Project.Path,
		Title:       title,
		Status:      "running",
		Source:      sessionSource(req.ResumeID),
		ResumeID:    req.ResumeID,
		CreatedAt:   now,
		UpdatedAt:   now,
		cmd:         cmd,
		ptmx:        ptmx,
		cancel:      cancel,
		buffer:      ring.New(m.options.OutputBuffer),
		termCols:    req.Cols,
		termRows:    req.Rows,
		subscribers: make(map[chan []byte]struct{}),
		done:        make(chan struct{}),
	}

	m.mu.Lock()
	m.sessions[id] = s
	m.mu.Unlock()

	go s.readLoop()
	go s.waitLoop()
	return s, nil
}

func sessionSource(resumeID string) string {
	if strings.TrimSpace(resumeID) != "" {
		return "codex"
	}
	return "agentd"
}

func (m *Manager) remove(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.sessions, id)
}

func (m *Manager) codexArgs(req CreateRequest) []string {
	prompt := strings.TrimSpace(req.Prompt)
	if req.ResumeID != "" {
		args := append([]string{"resume"}, m.options.DefaultArgs...)
		args = append(args, req.ResumeID)
		if prompt != "" {
			args = append(args, prompt)
		}
		return args
	}
	args := append([]string{}, m.options.DefaultArgs...)
	if prompt != "" {
		args = append(args, prompt)
	}
	return args
}

func sessionTitle(prompt string) string {
	prompt = strings.TrimSpace(prompt)
	if prompt == "" {
		return "交互式 Codex 会话"
	}
	fields := strings.Fields(prompt)
	title := strings.Join(fields, " ")
	if len([]rune(title)) > 42 {
		runes := []rune(title)
		return string(runes[:42]) + "..."
	}
	return title
}

func buildEnv(extra map[string]string) []string {
	env := os.Environ()
	for k, v := range extra {
		env = append(env, k+"="+v)
	}
	return env
}

func newID() (string, error) {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return "sess_" + hex.EncodeToString(b[:]), nil
}

func (m *Manager) Get(id string) (*Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	return s, ok
}

func (m *Manager) List() []*Session {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].CreatedAt.After(out[j].CreatedAt)
	})
	return out
}

func (m *Manager) Stop(id string) error {
	s, ok := m.Get(id)
	if !ok {
		return fmt.Errorf("session 不存在：%s", id)
	}
	return s.Stop()
}

func (m *Manager) Shutdown() {
	for _, s := range m.List() {
		_ = s.Stop()
	}
}

func (s *Session) Snapshot() Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := *s
	cp.cmd = nil
	cp.ptmx = nil
	cp.cancel = nil
	cp.buffer = nil
	cp.subscribers = nil
	cp.done = nil
	return cp
}

func (s *Session) RecentOutput() string {
	return s.buffer.String()
}

func (s *Session) Write(input string) error {
	if len(input) > 16*1024 {
		return fmt.Errorf("单次输入过大，最大 16KB")
	}
	s.mu.Lock()
	closed := s.Status != "running"
	ptmx := s.ptmx
	s.mu.Unlock()
	if closed || ptmx == nil {
		return fmt.Errorf("session 已结束")
	}

	s.writeMu.Lock()
	defer s.writeMu.Unlock()

	if body, ok := splitSubmittedPrompt(input); ok {
		// Codex TUI 会把快速连续字符识别成 paste burst，并在短窗口内把 Enter
		// 当作粘贴里的换行。把正文和提交键分开发，可以避免“文字进入输入框但没提交”。
		if _, err := ptmx.Write([]byte(body)); err != nil {
			return err
		}
		time.Sleep(promptSubmitDelay)
		_, err := ptmx.Write([]byte("\r"))
		return err
	}

	_, err := ptmx.Write([]byte(input))
	return err
}

func splitSubmittedPrompt(input string) (string, bool) {
	if len(input) <= 1 || !strings.HasSuffix(input, "\r") {
		return input, false
	}
	body := strings.TrimSuffix(input, "\r")
	if body == "" {
		return input, false
	}
	return body, true
}

func (s *Session) Resize(cols, rows int) error {
	if cols < 20 || cols > 300 || rows < 5 || rows > 100 {
		return fmt.Errorf("终端尺寸超出范围")
	}
	s.mu.Lock()
	if s.termCols == cols && s.termRows == rows {
		s.mu.Unlock()
		return nil
	}
	ptmx := s.ptmx
	s.mu.Unlock()
	if ptmx == nil {
		return fmt.Errorf("session 已结束")
	}
	if err := pty.Setsize(ptmx, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)}); err != nil {
		return err
	}
	s.mu.Lock()
	s.termCols = cols
	s.termRows = rows
	s.mu.Unlock()
	return nil
}

func (s *Session) Stop() error {
	s.mu.Lock()
	if s.Status != "running" {
		s.mu.Unlock()
		return nil
	}
	s.Status = "stopping"
	s.UpdatedAt = time.Now()
	cmd := s.cmd
	cancel := s.cancel
	s.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if cmd != nil && cmd.Process != nil {
		// 先温和退出，2 秒后仍未退出再强杀进程组。
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		select {
		case <-s.done:
			return nil
		case <-time.After(2 * time.Second):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
	}
	return nil
}

func (s *Session) Attach() (<-chan []byte, func(), error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.Status != "running" {
		return nil, nil, fmt.Errorf("session 已结束")
	}
	if s.subscribers == nil {
		s.subscribers = make(map[chan []byte]struct{})
	}
	ch := make(chan []byte, 128)
	s.subscribers[ch] = struct{}{}
	detached := false
	return ch, func() {
		s.mu.Lock()
		if !detached {
			delete(s.subscribers, ch)
			close(ch)
			detached = true
		}
		s.mu.Unlock()
	}, nil
}

func (s *Session) broadcastOutput(chunk []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for ch := range s.subscribers {
		select {
		case ch <- chunk:
		default:
			// 前端太慢时丢弃实时块；最近输出仍在 ring buffer 中，刷新可追回。
		}
	}
}

func (s *Session) Done() <-chan struct{} {
	return s.done
}

func (s *Session) ExitResult() ExitResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.exit
}

func (s *Session) readLoop() {
	buf := make([]byte, 4096)
	for {
		n, err := s.ptmx.Read(buf)
		if n > 0 {
			chunk := append([]byte(nil), buf[:n]...)
			s.buffer.Write(chunk)
			s.broadcastOutput(chunk)
		}
		if err != nil {
			if err != io.EOF {
				s.buffer.Write([]byte("\r\n[agentd] PTY 读取结束：" + err.Error() + "\r\n"))
			}
			return
		}
	}
}

func (s *Session) waitLoop() {
	err := s.cmd.Wait()
	exit := ExitResult{Code: 0, Reason: "process exited"}
	if err != nil {
		exit.Code = exitCode(err)
		exit.Reason = err.Error()
	}
	_ = s.ptmx.Close()

	s.mu.Lock()
	s.Status = "closed"
	s.UpdatedAt = time.Now()
	s.exit = exit
	s.mu.Unlock()
	close(s.done)
}

func exitCode(err error) int {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
			return status.ExitStatus()
		}
	}
	return -1
}
