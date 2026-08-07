package claudebridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveBinaryMacAppPrefersBundledBridge(t *testing.T) {
	executable, bundled, external := binaryResolutionFixtures(t, true)

	got, ok := resolveBinary(external, executable)
	if !ok || got != bundled {
		t.Fatalf("Mac App 应优先选择随包 bridge：got=(%q,%t), want=(%q,true)", got, ok, bundled)
	}
}

func TestResolveBinaryCLIStillPrefersExplicitBridge(t *testing.T) {
	executable, bundled, external := binaryResolutionFixtures(t, true)

	cliExecutable := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(executable)))), "agentd")
	got, ok := resolveBinary(external, cliExecutable)
	if !ok || got != external {
		t.Fatalf("普通 CLI 应优先选择显式 bridge：got=(%q,%t), want=(%q,true)", got, ok, external)
	}

	// 保留随包文件，确保该测试验证的是路径形态，而非 bridge 缺失回退。
	if _, err := os.Stat(bundled); err != nil {
		t.Fatalf("测试 fixture 缺少随包 bridge：%v", err)
	}
}

func TestResolveBinaryMacAppFallsBackWhenBundledBridgeMissing(t *testing.T) {
	executable, _, external := binaryResolutionFixtures(t, false)

	got, ok := resolveBinary(external, executable)
	if !ok || got != external {
		t.Fatalf("Mac App 随包 bridge 缺失时应回退显式 bridge：got=(%q,%t), want=(%q,true)", got, ok, external)
	}
}

func TestResolveBinaryFailsWhenNoBridgeIsAvailable(t *testing.T) {
	executable, _, _ := binaryResolutionFixtures(t, false)
	missing := filepath.Join(t.TempDir(), "missing-bridge")

	got, ok := resolveBinary(missing, executable)
	if ok || got != missing {
		t.Fatalf("无可用 bridge 时应返回失败和原始命令：got=(%q,%t), want=(%q,false)", got, ok, missing)
	}
}

func binaryResolutionFixtures(t *testing.T, bundledAvailable bool) (executable, bundled, external string) {
	t.Helper()
	root := t.TempDir()
	resources := filepath.Join(root, "Mimi Remote.app", "Contents", "Resources")
	executable = filepath.Join(resources, "agentd")
	bundled = filepath.Join(resources, BinaryName)
	external = filepath.Join(root, "old", BinaryName)
	if err := os.MkdirAll(filepath.Dir(executable), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(external), 0o755); err != nil {
		t.Fatal(err)
	}
	writeExecutableFixture(t, external)
	if bundledAvailable {
		writeExecutableFixture(t, bundled)
	}
	return executable, bundled, external
}

func writeExecutableFixture(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("bridge fixture\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}
