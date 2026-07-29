package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
)

func TestLoadWithEnvOverrides(t *testing.T) {
	clearAgentdEnv(t)
	t.Setenv("AGENTD_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("AGENTD_PROJECTS", filepath.Join(t.TempDir(), "demo"))
	projectDir := os.Getenv("AGENTD_PROJECTS")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Auth.Token == "" {
		t.Fatal("期望从环境变量读取 token")
	}
	if len(cfg.Projects) != 1 || cfg.Projects[0].ID != "demo" {
		t.Fatalf("项目解析异常：%+v", cfg.Projects)
	}
	if cfg.Voice.CodexTranscriptionBaseURL != "https://chatgpt.com/backend-api" {
		t.Fatalf("默认语音转写必须使用 Codex 登录态后端，实际 %q", cfg.Voice.CodexTranscriptionBaseURL)
	}
	if !cfg.AppServer.AutoTitle {
		t.Fatal("新安装默认应启用 Mac 端会话标题生成")
	}
}

func TestValidateRejectsEmptyToken(t *testing.T) {
	cfg := defaults()
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
	if err := cfg.Validate(); err == nil {
		t.Fatal("期望空 token 被拒绝")
	}
}

// An installed app ships its own bridge next to agentd, so an empty
// claude.bridge_bin is a complete configuration there — that is what lets a
// fresh install work with no per-machine setup. Without a bundled copy it is
// still a misconfiguration and must be rejected.
func TestValidateAcceptsEmptyBridgeBinOnlyWhenOneShipsAlongside(t *testing.T) {
	newConfig := func() Config {
		cfg := defaults()
		cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
		cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = ""
		cfg.Claude.MaxConcurrentBridges = 3
		return cfg
	}

	sibling := bundledSiblingPathForTest(t)
	if sibling == "" {
		t.Skip("拿不到可执行文件路径")
	}
	if _, err := os.Stat(sibling); err == nil {
		t.Skip("测试二进制旁已存在同名文件，跳过以免干扰")
	}

	cfg := newConfig()
	if err := cfg.Validate(); err == nil {
		t.Fatal("没有随包 bridge 时，空 bridge_bin 仍应被拒绝")
	}

	if err := os.WriteFile(sibling, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Skip("无法在测试二进制旁写入：" + err.Error())
	}
	t.Cleanup(func() { _ = os.Remove(sibling) })

	cfg = newConfig()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("随包 bridge 存在时应接受空 bridge_bin：%v", err)
	}
}

func bundledSiblingPathForTest(t *testing.T) string {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	return filepath.Join(filepath.Dir(executable), claudebridge.BinaryName)
}

func TestPlatformDefaultPathIgnoresAgentdConfig(t *testing.T) {
	customPath := filepath.Join(t.TempDir(), "custom-config.json")
	t.Setenv("AGENTD_CONFIG", customPath)

	if got := DefaultPath(); got != customPath {
		t.Fatalf("普通前台命令仍应接受 AGENTD_CONFIG：got=%q want=%q", got, customPath)
	}
	platformDefault := PlatformDefaultPath()
	if platformDefault == customPath {
		t.Fatalf("Homebrew 平台默认路径不能受 AGENTD_CONFIG 影响：%q", platformDefault)
	}
	wantDir, err := UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	if platformDefault != filepath.Join(wantDir, "config.json") {
		t.Fatalf("平台默认配置路径异常：got=%q want=%q", platformDefault, filepath.Join(wantDir, "config.json"))
	}
}
