package claudebridge

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ResolveBinary 解析实际要运行的 bridge。普通 CLI 优先使用显式配置，
// 配置缺失或失效时回退到与 agentd 同目录的随包 bridge。完整 Mac App
// 必须固定使用随包 bridge，避免旧外置版本覆盖 App 自带的兼容运行时。
// Gateway、配置校验和 Doctor 必须共用这条规则，否则会出现状态分裂。
func ResolveBinary(command string) (string, bool) {
	return resolveBinary(command, runningExecutablePath())
}

func BundledAvailable() bool {
	_, ok := resolveExecutable(BundledSiblingPath())
	return ok
}

// BundledSiblingPath 返回运行中 agentd 同目录的 bridge；无法取得当前
// 可执行文件路径时返回空字符串。
func BundledSiblingPath() string {
	return bundledSiblingPath(runningExecutablePath())
}

// resolveBinary 接收可注入的 agentd 路径，保证 App bundle 选择逻辑可在
// 不读取用户真实配置、也不依赖当前测试进程位置的情况下确定性验证。
func resolveBinary(command, executable string) (string, bool) {
	bundled := bundledSiblingPath(executable)
	if isMacAppAgentdPath(executable) {
		// Mac App 的 Resources 与 agentd 同包发布，必须优先固定这份 bridge，
		// 否则旧外置 bridge 可能覆盖随包版本并破坏 App 的兼容性保证。
		if path, ok := resolveExecutable(bundled); ok {
			return path, true
		}
	}
	if path, ok := resolveExecutable(command); ok {
		return path, true
	}
	if path, ok := resolveExecutable(bundled); ok {
		return path, true
	}
	return strings.TrimSpace(command), false
}

func runningExecutablePath() string {
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	return executable
}

func bundledSiblingPath(executable string) string {
	if strings.TrimSpace(executable) == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(executable), BinaryName)
}

func isMacAppAgentdPath(executable string) bool {
	clean := filepath.Clean(strings.TrimSpace(executable))
	if clean == "." || filepath.Base(clean) != "agentd" {
		return false
	}
	resources := filepath.Dir(clean)
	if filepath.Base(resources) != "Resources" {
		return false
	}
	contents := filepath.Dir(resources)
	if filepath.Base(contents) != "Contents" {
		return false
	}
	return strings.HasSuffix(filepath.Base(filepath.Dir(contents)), ".app")
}

func resolveExecutable(command string) (string, bool) {
	command = strings.TrimSpace(command)
	if command == "" {
		return "", false
	}
	if filepath.IsAbs(command) || strings.ContainsAny(command, `/\`) {
		info, err := os.Stat(command)
		if err != nil || !isExecutableFile(command, info) {
			return command, false
		}
		return command, true
	}
	path, err := exec.LookPath(command)
	if err != nil {
		return command, false
	}
	return path, true
}
