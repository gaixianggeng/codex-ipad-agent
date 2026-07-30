package claudebridge

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ResolveBinary 优先使用显式配置；配置缺失或失效时回退到与 agentd
// 同目录的随包 bridge。Gateway、配置校验和 Doctor 必须共用这条规则，
// 否则完整 Mac App 安装会出现“运行时可用但诊断失败”的状态分裂。
func ResolveBinary(command string) (string, bool) {
	if path, ok := resolveExecutable(command); ok {
		return path, true
	}
	if path, ok := resolveExecutable(BundledSiblingPath()); ok {
		return path, true
	}
	return strings.TrimSpace(command), false
}

func BundledAvailable() bool {
	_, ok := resolveExecutable(BundledSiblingPath())
	return ok
}

// BundledSiblingPath 返回运行中 agentd 同目录的 bridge；无法取得当前
// 可执行文件路径时返回空字符串。
func BundledSiblingPath() string {
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	return filepath.Join(filepath.Dir(executable), BinaryName)
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
