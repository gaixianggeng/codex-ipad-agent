package doctor

import (
	"bytes"
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
)

func TestCheckerRunAndPrintDoNotLeakToken(t *testing.T) {
	binDir := t.TempDir()
	writeFakeCodexWithAppServerHelp(t, filepath.Join(binDir, "codex"))
	writeFakeExecutable(t, filepath.Join(binDir, "tailscale"))
	t.Setenv("PATH", binDir)

	secret := "0123456789abcdef0123456789abcdef"
	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: secret},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: "codex"},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if !results.OK {
		t.Fatalf("fake codex/tailscale 均存在时 doctor 应通过：%+v", results)
	}

	var out bytes.Buffer
	Print(&out, results)
	if strings.Contains(out.String(), secret) {
		t.Fatalf("doctor 输出不能泄漏 token：%s", out.String())
	}
}

func TestCheckerFailsOnMissingCodexButIgnoresMissingTailscale(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	checker := newTestChecker(t, config.Config{
		Listen: "127.0.0.1:8787",
		Auth:   config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Codex:  config.CodexConfig{Bin: "definitely-missing-codex"},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if results.OK {
		t.Fatalf("缺少 Codex CLI 时 doctor 应失败：%+v", results)
	}

	var codexOK, tailscaleOK bool
	for _, check := range results.Checks {
		switch check.Name {
		case "codex":
			codexOK = check.OK
		case "tailscale":
			tailscaleOK = check.OK
			if check.Message != "未检测到 Tailscale 命令，本机访问仍可使用" {
				t.Fatalf("tailscale 缺失应降级为本机可用提示，实际 %q", check.Message)
			}
		}
	}
	if codexOK {
		t.Fatal("codex check 应失败")
	}
	if !hasCheckMessage(results, "codex", "未找到 Codex CLI") {
		t.Fatalf("codex 缺失时应给出准确文案：%+v", results.Checks)
	}
	if tailscaleOK {
		t.Fatal("空 PATH 下 tailscale check 应失败但不影响整体失败原因判断")
	}
}

func TestCheckerReportsAppServerRuntimeSafely(t *testing.T) {
	binDir := t.TempDir()
	writeFakeCodexWithAppServerHelp(t, filepath.Join(binDir, "codex"))
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: "codex"},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if !results.OK {
		t.Fatalf("ws app-server gateway 应通过 doctor：%+v", results)
	}
	if !hasCheck(results, "app-server") {
		t.Fatalf("doctor 应包含 app-server gateway 检查：%+v", results.Checks)
	}
}

func TestCheckerRejectsUnsafeAppServerWS(t *testing.T) {
	binDir := t.TempDir()
	writeFakeCodexWithAppServerHelp(t, filepath.Join(binDir, "codex"))
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "0.0.0.0:8390"},
		Codex:     config.CodexConfig{Bin: "codex"},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if results.OK {
		t.Fatalf("非 loopback app-server ws 不应通过 doctor：%+v", results)
	}
}

func TestCheckerReportsManagedWSGatewayForAppServerRuntime(t *testing.T) {
	binDir := t.TempDir()
	writeFakeCodexWithAppServerHelp(t, filepath.Join(binDir, "codex"))
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: "codex"},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if !results.OK {
		t.Fatalf("setup 默认 ws gateway 应通过 doctor：%+v", results)
	}
	if !hasCheck(results, "app-server") {
		t.Fatalf("启用 ws gateway 时应检查 app-server：%+v", results.Checks)
	}
}

func TestCheckerCheckPortIncludesManagedAppServerPort(t *testing.T) {
	binDir := t.TempDir()
	writeFakeCodexWithAppServerHelp(t, filepath.Join(binDir, "codex"))
	t.Setenv("PATH", binDir)

	listener := listenOnFreePort(t)
	defer listener.Close()

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:0",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://" + listener.Addr().String()},
		Codex:     config.CodexConfig{Bin: "codex"},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), true)
	if results.OK {
		t.Fatalf("app-server upstream 端口被占用时 doctor --check-port 应失败：%+v", results)
	}
	if !hasCheckMessage(results, "app-server-port", "端口不可监听") {
		t.Fatalf("应报告 app-server-port 占用：%+v", results.Checks)
	}
}

func TestCheckerFailsWhenCodexAppServerHelpMissingWSFlags(t *testing.T) {
	binDir := t.TempDir()
	writeFakeExecutable(t, filepath.Join(binDir, "codex"))
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: "codex"},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if results.OK {
		t.Fatalf("缺少 app-server ws flags 时 doctor 应失败：%+v", results)
	}
	if !hasCheck(results, "codex-app-server") {
		t.Fatalf("应包含 codex-app-server 检查：%+v", results.Checks)
	}
}

func hasCheck(results Results, name string) bool {
	for _, check := range results.Checks {
		if check.Name == name {
			return true
		}
	}
	return false
}

func hasCheckMessage(results Results, name, want string) bool {
	for _, check := range results.Checks {
		if check.Name == name && strings.Contains(check.Message, want) {
			return true
		}
	}
	return false
}

func newTestChecker(t *testing.T, cfg config.Config) *Checker {
	t.Helper()
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	return NewChecker("test-version", cfg, registry)
}

func listenOnFreePort(t *testing.T) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return listener
}

func writeFakeExecutable(t *testing.T, path string) {
	t.Helper()
	// doctor 只需要 LookPath 能找到命令；脚本内容保持最小，避免测试依赖真实 CLI。
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeFakeCodexWithAppServerHelp(t *testing.T, path string) {
	t.Helper()
	body := `#!/bin/sh
if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then
  printf '%s\n' '--listen --ws-auth --ws-token-file'
  exit 0
fi
exit 0
`
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}
