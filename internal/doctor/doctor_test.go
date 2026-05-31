package doctor

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
)

func TestCheckerRunAndPrintDoNotLeakToken(t *testing.T) {
	binDir := t.TempDir()
	writeFakeExecutable(t, filepath.Join(binDir, "codex"))
	writeFakeExecutable(t, filepath.Join(binDir, "tailscale"))
	t.Setenv("PATH", binDir)

	secret := "0123456789abcdef0123456789abcdef"
	checker := newTestChecker(t, config.Config{
		Listen: "127.0.0.1:8787",
		Auth:   config.AuthConfig{Token: secret},
		Codex:  config.CodexConfig{Bin: "codex"},
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
	if tailscaleOK {
		t.Fatal("空 PATH 下 tailscale check 应失败但不影响整体失败原因判断")
	}
}

func newTestChecker(t *testing.T, cfg config.Config) *Checker {
	t.Helper()
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	return NewChecker("test-version", cfg, registry)
}

func writeFakeExecutable(t *testing.T, path string) {
	t.Helper()
	// doctor 只需要 LookPath 能找到命令；脚本内容保持最小，避免测试依赖真实 CLI。
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}
