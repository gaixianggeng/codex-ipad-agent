package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadMergesExplicitAndScannedProjects(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "app")
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".hidden"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "node_modules"), 0o755); err != nil {
		t.Fatal(err)
	}

	cfgPath := filepath.Join(t.TempDir(), "config.json")
	raw, err := json.Marshal(map[string]any{
		"auth": AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		"projects": []ProjectConfig{{
			ID:   "explicit-app",
			Name: "Explicit App",
			Path: appDir,
		}},
		"scan_roots": []string{root},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfgPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	clearAgentdEnv(t)

	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}

	if len(cfg.Projects) != 2 {
		t.Fatalf("期望 explicit app + scan root 两个项目，实际 %+v", cfg.Projects)
	}
	if cfg.Projects[0].ID != "explicit-app" {
		t.Fatalf("显式项目应保持优先级，实际 %+v", cfg.Projects[0])
	}
	if cfg.Projects[1].Path != root {
		t.Fatalf("扫描根目录未规范化加入：%+v", cfg.Projects)
	}
	for _, project := range cfg.Projects {
		if project.Name == ".hidden" || project.Name == "node_modules" {
			t.Fatalf("扫描目录应跳过隐藏目录和依赖目录：%+v", cfg.Projects)
		}
	}
}

func TestLoadEnvListenPrecedenceAndSessionBuffer(t *testing.T) {
	projectDir := t.TempDir()
	clearAgentdEnv(t)
	t.Setenv("AGENTD_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("AGENTD_PROJECTS", projectDir)
	t.Setenv("AGENTD_BIND", "0.0.0.0")
	t.Setenv("AGENTD_PORT", "9999")
	t.Setenv("AGENTD_LISTEN", "127.0.0.1:7777")
	t.Setenv("AGENTD_OUTPUT_BUFFER_BYTES", "4096")
	t.Setenv("AGENTD_ALLOW_QUERY_TOKEN", "1")
	t.Setenv("AGENTD_RUNTIME", "app_server")
	t.Setenv("AGENTD_APP_SERVER_TRANSPORT", "stdio")
	t.Setenv("AGENTD_APP_SERVER_MANAGED", "true")
	t.Setenv("AGENTD_APP_SERVER_WS_TOKEN_FILE", "/tmp/codex-app-server-ws-token")
	t.Setenv("AGENTD_APP_SERVER_FALLBACK_PTY", "false")

	cfg, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Listen != "127.0.0.1:7777" {
		t.Fatalf("AGENTD_LISTEN 应优先于 bind/port，实际 %q", cfg.Listen)
	}
	if cfg.Session.OutputBufferBytes != 4096 {
		t.Fatalf("输出缓冲区环境变量未生效：%d", cfg.Session.OutputBufferBytes)
	}
	if !cfg.Auth.AllowQueryToken {
		t.Fatal("AGENTD_ALLOW_QUERY_TOKEN=1 应启用 query token 兼容模式")
	}
	if cfg.Runtime.Type != "codex_app_server" || cfg.Runtime.FallbackPTY {
		t.Fatalf("runtime 环境变量解析异常：%+v", cfg.Runtime)
	}
	if cfg.AppServer.Transport != "stdio" || !cfg.AppServer.Managed || cfg.AppServer.WSTokenFile != "/tmp/codex-app-server-ws-token" {
		t.Fatalf("app_server 环境变量解析异常：%+v", cfg.AppServer)
	}
	if len(cfg.Projects) != 1 || cfg.Projects[0].Path != projectDir {
		t.Fatalf("项目环境变量解析异常：%+v", cfg.Projects)
	}
}

func TestValidateAcceptsDevInsecureWithoutToken(t *testing.T) {
	cfg := defaults()
	cfg.DevInsecure = true
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

	if err := cfg.Validate(); err != nil {
		t.Fatalf("开发模式应允许无 token：%v", err)
	}
}

func TestValidateRejectsShortToken(t *testing.T) {
	cfg := defaults()
	cfg.Auth.Token = "short"
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

	if err := cfg.Validate(); err == nil {
		t.Fatal("期望短 token 被拒绝")
	}
}

func TestValidateRejectsUnsafeAppServerListen(t *testing.T) {
	cfg := defaults()
	cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
	cfg.Runtime.Type = "codex_app_server"
	cfg.AppServer.Transport = "ws"
	cfg.AppServer.Listen = "0.0.0.0:8390"
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

	if err := cfg.Validate(); err == nil {
		t.Fatal("非 loopback app-server ws 监听应被拒绝")
	}

	cfg.AppServer.Listen = "127.0.0.1:8390"
	if err := cfg.Validate(); err != nil {
		t.Fatalf("loopback app-server ws 监听应允许用于本机调试：%v", err)
	}
}

func clearAgentdEnv(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"AGENTD_CONFIG",
		"AGENTD_LISTEN",
		"AGENTD_BIND",
		"AGENTD_PORT",
		"AGENTD_TOKEN",
		"AGENTD_ALLOW_QUERY_TOKEN",
		"AGENTD_CODEX_BIN",
		"AGENTD_CODEX_ARGS",
		"AGENTD_RUNTIME",
		"AGENTD_APP_SERVER_TRANSPORT",
		"AGENTD_APP_SERVER_LISTEN",
		"AGENTD_APP_SERVER_WS_TOKEN_FILE",
		"AGENTD_APP_SERVER_MANAGED",
		"AGENTD_APP_SERVER_FALLBACK_PTY",
		"AGENTD_DEV_INSECURE",
		"AGENTD_OUTPUT_BUFFER_BYTES",
		"AGENTD_PROJECTS",
		"AGENTD_SCAN_ROOTS",
	} {
		t.Setenv(key, "")
	}
}
