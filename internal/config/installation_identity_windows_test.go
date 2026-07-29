//go:build windows

package config

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadOrCreateInstallationIDUsesWindowsFileModeSemantics(t *testing.T) {
	path := filepath.Join(t.TempDir(), installationIDFileName)
	entropy := bytes.NewReader([]byte{
		0x00, 0x11, 0x22, 0x33,
		0x44, 0x55,
		0x66, 0x77,
		0x88, 0x99,
		0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
	})

	installationID, err := loadOrCreateInstallationID(path, entropy)
	if err != nil {
		t.Fatal(err)
	}
	if installationID != "00112233-4455-4677-8899-aabbccddeeff" {
		t.Fatalf("安装身份异常：%q", installationID)
	}

	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() == installationIDFileMode {
		t.Fatalf("测试前提失效：Windows 不应把普通可写文件报告为 POSIX 0600：%v", info.Mode())
	}

	again, err := readInstallationID(path)
	if err != nil {
		t.Fatal(err)
	}
	if again != installationID {
		t.Fatalf("Windows 安装身份必须跨读取稳定：first=%q second=%q", installationID, again)
	}
}
