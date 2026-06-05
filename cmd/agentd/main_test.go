package main

import (
	"path/filepath"
	"testing"
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
