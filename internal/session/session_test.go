package session

import (
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

func TestAttachRejectsSecondClientUntilDetached(t *testing.T) {
	session := &Session{
		Status: "running",
		output: make(chan []byte),
		done:   make(chan struct{}),
	}

	_, detach, err := session.Attach()
	if err != nil {
		t.Fatalf("首次 attach 应成功：%v", err)
	}
	if _, _, err := session.Attach(); err == nil {
		t.Fatal("同一 session 同时只能有一个客户端 attach")
	}

	detach()
	if _, detach, err := session.Attach(); err != nil {
		t.Fatalf("detach 后应允许重新 attach：%v", err)
	} else {
		detach()
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
