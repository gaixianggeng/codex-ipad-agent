package claudebridge

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

const (
	MinimumVersion = "0.2.0"
	// 兼容修复尚未形成可引用的远端 SHA，不能把旧 main 伪装成可升级版本；
	// 当前只允许从已审阅的 0.2.0 源码安装，提交后再替换为固定 --rev 命令。
	InstallHint = "cargo install --path crates/claude-bridge --locked --force"
)

var semanticVersionPattern = regexp.MustCompile(`(?:^|[^0-9])v?([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?(?:$|[^0-9])`)

// ParseVersion 从标准 `--version` 输出中提取三段式语义版本，避免把日志时间戳误判为版本。
func ParseVersion(output string) (string, bool) {
	match := semanticVersionPattern.FindStringSubmatch(strings.TrimSpace(output))
	if len(match) != 5 {
		return "", false
	}
	// 预发布版本不能静默当作正式版通过能力门禁；保留后缀后由 Compare 保守拒绝。
	return strings.Join(match[1:4], ".") + match[4], true
}

func IsSupported(version string) bool {
	return Compare(version, MinimumVersion) >= 0
}

func Compare(left string, right string) int {
	leftParts, leftOK := numericParts(left)
	rightParts, rightOK := numericParts(right)
	if !leftOK || !rightOK {
		return -1
	}
	for index := range leftParts {
		if leftParts[index] < rightParts[index] {
			return -1
		}
		if leftParts[index] > rightParts[index] {
			return 1
		}
	}
	return 0
}

func UpgradeMessage(version string) string {
	if strings.TrimSpace(version) == "" {
		return fmt.Sprintf("Claude bridge 未返回标准版本；需要 >= %s。请在 alleycat 兼容版源码根目录执行：%s", MinimumVersion, InstallHint)
	}
	return fmt.Sprintf("Claude bridge %s 过旧；需要 >= %s。请在 alleycat 兼容版源码根目录执行：%s", version, MinimumVersion, InstallHint)
}

func numericParts(version string) ([3]int, bool) {
	var result [3]int
	parts := strings.Split(strings.TrimSpace(strings.TrimPrefix(version, "v")), ".")
	if len(parts) != len(result) {
		return result, false
	}
	for index, part := range parts {
		value, err := strconv.Atoi(part)
		if err != nil || value < 0 {
			return result, false
		}
		result[index] = value
	}
	return result, true
}
