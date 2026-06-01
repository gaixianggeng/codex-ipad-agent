package session

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
)

func TestManagerCodexArgsForPromptAndResume(t *testing.T) {
	manager := NewManager(Options{DefaultArgs: []string{"--no-alt-screen", "--sandbox", "workspace-write"}})

	got := manager.codexArgs(CreateRequest{Prompt: "  帮我检查测试  "})
	want := []string{"--no-alt-screen", "--sandbox", "workspace-write", "帮我检查测试"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("新会话参数不匹配\nwant=%v\ngot=%v", want, got)
	}

	got = manager.codexArgs(CreateRequest{ResumeID: "thread_123", Prompt: "继续"})
	want = []string{"resume", "--no-alt-screen", "--sandbox", "workspace-write", "thread_123", "继续"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("恢复会话参数不匹配\nwant=%v\ngot=%v", want, got)
	}
}

func TestSessionTitleAndSourceDefaults(t *testing.T) {
	if got := sessionTitle(""); got != "交互式 Codex 会话" {
		t.Fatalf("空 prompt 标题异常：%q", got)
	}
	if got := sessionTitle("  第一行\n第二行  "); got != "第一行 第二行" {
		t.Fatalf("标题应压平空白字符：%q", got)
	}
	longTitle := sessionTitle(strings.Repeat("界", 50))
	if !strings.HasSuffix(longTitle, "...") || len([]rune(longTitle)) != 45 {
		t.Fatalf("长标题应按 rune 截断并追加省略号：%q", longTitle)
	}
	if got := sessionSource(""); got != "agentd" {
		t.Fatalf("新会话 source 异常：%q", got)
	}
	if got := sessionSource("thread_1"); got != "codex" {
		t.Fatalf("恢复会话 source 异常：%q", got)
	}
}

func TestCreateWithFakeCodexUsesProjectDirAndBoundsTerminalSize(t *testing.T) {
	projectDir := t.TempDir()
	realProjectDir, err := filepath.EvalSymlinks(projectDir)
	if err != nil {
		t.Fatal(err)
	}
	fakeCodex := filepath.Join(t.TempDir(), "codex")
	writeFakeCodex(t, fakeCodex)

	manager := NewManager(Options{
		CodexBin:     fakeCodex,
		DefaultArgs:  []string{"--no-alt-screen"},
		Env:          map[string]string{"TERM": "xterm-agentd-test"},
		OutputBuffer: 1024,
	})
	session, err := manager.Create(CreateRequest{
		Project: projects.Project{
			ID:       "demo",
			Name:     "Demo",
			Path:     projectDir,
			RealPath: projectDir,
		},
		Prompt: "hello world",
		Cols:   1,
		Rows:   999,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Shutdown()

	select {
	case <-session.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("fake codex 未按预期退出")
	}

	snapshot := session.Snapshot()
	if snapshot.ProjectID != "demo" || snapshot.Dir != projectDir {
		t.Fatalf("session 未保存 allowlist 项目信息：%+v", snapshot)
	}
	if snapshot.Title != "hello world" {
		t.Fatalf("标题应来自 prompt：%q", snapshot.Title)
	}
	if snapshot.Source != "agentd" {
		t.Fatalf("新会话 source 应为 agentd：%q", snapshot.Source)
	}
	if session.termCols != 120 || session.termRows != 32 {
		t.Fatalf("非法终端尺寸应回落到默认值，cols=%d rows=%d", session.termCols, session.termRows)
	}

	output := session.RecentOutput()
	if !strings.Contains(output, "cwd="+realProjectDir) {
		t.Fatalf("fake codex 应在项目目录运行，输出：%q", output)
	}
	if !strings.Contains(output, "args=--no-alt-screen hello world") {
		t.Fatalf("fake codex 参数异常，输出：%q", output)
	}
	if !strings.Contains(output, "TERM=xterm-agentd-test") {
		t.Fatalf("session 环境变量未传入子进程，输出：%q", output)
	}
}

func TestCreateExistingResumeSessionWritesPrompt(t *testing.T) {
	projectDir := t.TempDir()
	fakeCodex := filepath.Join(t.TempDir(), "codex")
	inputLog := filepath.Join(t.TempDir(), "input.log")
	writeInteractiveFakeCodex(t, fakeCodex, inputLog)

	manager := NewManager(Options{
		CodexBin:     fakeCodex,
		DefaultArgs:  []string{"--no-alt-screen"},
		Env:          map[string]string{"TERM": "xterm-agentd-test"},
		OutputBuffer: 1024,
	})
	defer manager.Shutdown()

	project := projects.Project{
		ID:       "demo",
		Name:     "Demo",
		Path:     projectDir,
		RealPath: projectDir,
	}
	first, err := manager.Create(CreateRequest{
		Project:  project,
		ResumeID: "thread_123",
		Prompt:   "第一次",
		Cols:     120,
		Rows:     32,
	})
	if err != nil {
		t.Fatal(err)
	}

	second, err := manager.Create(CreateRequest{
		Project:  project,
		ResumeID: "thread_123",
		Prompt:   "第二次",
		Cols:     120,
		Rows:     32,
	})
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("同一个 resumeID 的运行中会话应复用已有 session")
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		data, _ := os.ReadFile(inputLog)
		if strings.Contains(string(data), "第二次") {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("复用运行中 resume session 时没有把 prompt 写入 PTY，input.log=%q", string(data))
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSplitSubmittedPrompt(t *testing.T) {
	tests := []struct {
		name string
		in   string
		body string
		ok   bool
	}{
		{name: "submitted prompt", in: "hello\r", body: "hello", ok: true},
		{name: "raw enter", in: "\r", body: "\r", ok: false},
		{name: "plain text", in: "hello", body: "hello", ok: false},
		{name: "double enter keeps first in body", in: "hello\r\r", body: "hello\r", ok: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body, ok := splitSubmittedPrompt(tt.in)
			if body != tt.body || ok != tt.ok {
				t.Fatalf("splitSubmittedPrompt(%q) = (%q, %v)，期望 (%q, %v)", tt.in, body, ok, tt.body, tt.ok)
			}
		})
	}
}

func TestSessionWriteSubmittedPromptSeparatesEnter(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()

	session := &Session{
		Status: "running",
		ptmx:   writer,
	}

	done := make(chan error, 1)
	go func() {
		done <- session.Write("hello\r")
	}()

	first := make(chan string, 1)
	go func() {
		buf := make([]byte, len("hello"))
		_, err := io.ReadFull(reader, buf)
		if err != nil {
			first <- "read error: " + err.Error()
			return
		}
		first <- string(buf)
	}()

	select {
	case got := <-first:
		if got != "hello" {
			t.Fatalf("应先写入 prompt 正文，实际 %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("没有读到 prompt 正文")
	}

	enter := make(chan string, 1)
	go func() {
		buf := make([]byte, 1)
		_, err := io.ReadFull(reader, buf)
		if err != nil {
			enter <- "read error: " + err.Error()
			return
		}
		enter <- string(buf)
	}()

	select {
	case got := <-enter:
		if got != "\r" {
			t.Fatalf("应补发 Enter，实际 %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("没有读到补发的 Enter")
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Write 返回错误：%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Write 没有结束")
	}
}

func TestAttachAllowsMultipleClientsReceiveBroadcast(t *testing.T) {
	session := &Session{
		Status:      "running",
		subscribers: make(map[chan []byte]struct{}),
		done:        make(chan struct{}),
	}

	first, detachFirst, err := session.Attach()
	if err != nil {
		t.Fatalf("首次 attach 应成功：%v", err)
	}
	defer detachFirst()
	second, detachSecond, err := session.Attach()
	if err != nil {
		t.Fatalf("第二个客户端也应允许 attach：%v", err)
	}
	defer detachSecond()

	session.broadcastOutput([]byte("hello"))
	for name, ch := range map[string]<-chan []byte{"first": first, "second": second} {
		select {
		case got := <-ch:
			if string(got) != "hello" {
				t.Fatalf("%s 收到的输出异常：%q", name, string(got))
			}
		case <-time.After(time.Second):
			t.Fatalf("%s 没有收到广播输出", name)
		}
	}
}

func writeFakeCodex(t *testing.T, path string) {
	t.Helper()
	// 脚本模拟 Codex CLI：打印 cwd、参数和关键环境变量，随后立即退出，让测试快速稳定。
	script := `#!/bin/sh
printf 'cwd=%s\n' "$PWD"
printf 'args=%s\n' "$*"
printf 'TERM=%s\n' "$TERM"
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeInteractiveFakeCodex(t *testing.T, path, inputLog string) {
	t.Helper()
	// 脚本模拟长驻 Codex CLI：先打印启动参数，再把之后从 PTY 收到的输入落盘。
	script := fmt.Sprintf(`#!/bin/sh
printf 'args=%%s\n' "$*"
while IFS= read -r line; do
  printf '%%s\n' "$line" >> %s
done
`, shellQuote(inputLog))
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
