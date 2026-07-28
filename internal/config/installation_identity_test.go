package config

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestLoadOrCreateInstallationIDCreatesStablePrivateIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), installationIDFileName)
	entropy := bytes.NewReader([]byte{
		0x00, 0x11, 0x22, 0x33,
		0x44, 0x55,
		0x66, 0x77,
		0x88, 0x99,
		0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
	})

	first, err := loadOrCreateInstallationID(path, entropy)
	if err != nil {
		t.Fatal(err)
	}
	const want = "00112233-4455-4677-8899-aabbccddeeff"
	if first != want {
		t.Fatalf("安装身份异常：got=%q want=%q", first, want)
	}

	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("安装身份必须是 0600 普通文件：mode=%v", info.Mode())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != want+"\n" {
		t.Fatalf("持久化内容异常：%q", raw)
	}

	// 第二次加载不能消耗随机源，更不能轮换已经发布的身份。
	second, err := loadOrCreateInstallationID(path, bytes.NewReader(nil))
	if err != nil {
		t.Fatal(err)
	}
	if second != first {
		t.Fatalf("安装身份必须跨启动稳定：first=%q second=%q", first, second)
	}
}

func TestLoadOrCreateInstallationIDRejectsCorruptionWithoutReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), installationIDFileName)
	const damaged = "not-an-installation-id\n"
	if err := os.WriteFile(path, []byte(damaged), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := loadOrCreateInstallationID(path, bytes.NewReader(make([]byte, 16))); err == nil {
		t.Fatal("损坏的安装身份必须阻止启动")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != damaged {
		t.Fatalf("损坏文件不能被静默替换：%q", raw)
	}
}

func TestLoadOrCreateInstallationIDRejectsUnsafePermissionAndSymlink(t *testing.T) {
	valid := "00112233-4455-4677-8899-aabbccddeeff\n"

	t.Run("permission", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), installationIDFileName)
		if err := os.WriteFile(path, []byte(valid), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := loadOrCreateInstallationID(path, bytes.NewReader(make([]byte, 16))); err == nil || !strings.Contains(err.Error(), "0600") {
			t.Fatalf("宽松权限必须 fail closed：%v", err)
		}
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o644 {
			t.Fatalf("加载器不能静默修复或替换异常权限：%04o", info.Mode().Perm())
		}
	})

	t.Run("symlink", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "target")
		path := filepath.Join(dir, installationIDFileName)
		if err := os.WriteFile(target, []byte(valid), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
		if _, err := loadOrCreateInstallationID(path, bytes.NewReader(make([]byte, 16))); err == nil || !strings.Contains(err.Error(), "符号链接") {
			t.Fatalf("符号链接身份文件必须 fail closed：%v", err)
		}
	})
}

func TestLoadOrCreateInstallationIDConcurrentFirstStartUsesOneIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), installationIDFileName)
	const workers = 12
	results := make(chan string, workers)
	errs := make(chan error, workers)
	var group sync.WaitGroup

	for index := 0; index < workers; index++ {
		index := index
		group.Add(1)
		go func() {
			defer group.Done()
			randomValue := bytes.Repeat([]byte{byte(index + 1)}, 16)
			installationID, err := loadOrCreateInstallationID(path, bytes.NewReader(randomValue))
			if err != nil {
				errs <- err
				return
			}
			results <- installationID
		}()
	}
	group.Wait()
	close(results)
	close(errs)

	for err := range errs {
		t.Fatalf("并发首次启动失败：%v", err)
	}
	var first string
	for installationID := range results {
		if first == "" {
			first = installationID
		}
		if installationID != first {
			t.Fatalf("并发首次启动产生多个身份：first=%q got=%q", first, installationID)
		}
	}
	if first == "" {
		t.Fatal("没有返回安装身份")
	}
}

func TestLoadOrCreateInstallationIDDoesNotPublishWhenEntropyFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), installationIDFileName)
	if _, err := loadOrCreateInstallationID(path, errorReader{}); err == nil {
		t.Fatal("随机源失败必须阻止创建身份")
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("随机源失败时不能留下目标文件：%v", err)
	}
}

type errorReader struct{}

func (errorReader) Read([]byte) (int, error) {
	return 0, errors.New("entropy unavailable")
}
