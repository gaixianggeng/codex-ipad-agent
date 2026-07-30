//go:build !windows

package httpapi

import (
	"fmt"
	"os"
	"path/filepath"
)

// macOS caps sockaddr_un.sun_path at 104 bytes. A socket we cannot bind is a
// confusing failure deep inside the bridge, so reject the path up front.
const claudeBridgeMaxSocketPath = 100

func prepareClaudeBridgeEndpoint(dir string) (string, string, []string, error) {
	socketPath := filepath.Join(dir, "bridge.sock")
	if len(socketPath) > claudeBridgeMaxSocketPath {
		return "", "", nil, fmt.Errorf(
			"Claude bridge socket 路径过长（%d 字节）：%s",
			len(socketPath),
			socketPath,
		)
	}
	// A leftover node from a crashed predecessor would make bind fail.
	if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		return "", "", nil, fmt.Errorf("清理 Claude bridge socket 失败：%w", err)
	}
	return "unix", socketPath, []string{"--socket", socketPath}, nil
}
