package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestVersionDoesNotRequireConfig(t *testing.T) {
	if err := run([]string{"agentd", "version"}); err != nil {
		t.Fatalf("version 不应依赖配置：%v", err)
	}
}

func TestSetupCommandCreatesConfig(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	scanRoot := t.TempDir()

	if err := run([]string{
		"agentd",
		"setup",
		"-config", cfgPath,
		"-scan-root", scanRoot,
		"-listen", "127.0.0.1:8787",
		"-json",
	}); err != nil {
		t.Fatalf("setup 命令失败：%v", err)
	}
}

func TestServeConnectionIsNotPrintedToRegularFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd.log")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}

	maybePrintServeConnection(file, agentsetup.Result{
		Endpoint:   "http://127.0.0.1:8787",
		Token:      "secret-token",
		ConnectURL: "mimiremote://connect?endpoint=http%3A%2F%2F127.0.0.1%3A8787&token=secret-token",
	})
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	output := string(raw)
	if strings.Contains(output, "secret-token") || strings.Contains(output, "mimiremote://connect") {
		t.Fatalf("serve 不应把连接凭证写入非交互式日志输出：%q", output)
	}
}
