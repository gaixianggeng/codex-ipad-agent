//go:build windows

package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

func prepareManagedServeRuntime(enabled bool) (func(), error) {
	if !enabled {
		return nil, nil
	}
	pidPath, err := windowsManagedPIDPath()
	if err != nil {
		return nil, err
	}
	stopPath, err := windowsManagedStopPath()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(windowsManagedRuntimeDir(pidPath), 0o700); err != nil {
		return nil, fmt.Errorf("创建 Windows 后台服务状态目录失败：%w", err)
	}
	_ = os.Remove(stopPath)
	pid := strconv.Itoa(os.Getpid())
	tempPath := pidPath + "." + pid + ".tmp"
	if err := os.WriteFile(tempPath, []byte(pid+"\n"), 0o600); err != nil {
		return nil, fmt.Errorf("写入 Windows 后台服务 PID 失败：%w", err)
	}
	if err := os.Rename(tempPath, pidPath); err != nil {
		_ = os.Remove(tempPath)
		return nil, fmt.Errorf("发布 Windows 后台服务 PID 失败：%w", err)
	}
	return func() {
		data, readErr := os.ReadFile(pidPath)
		if readErr == nil && strings.TrimSpace(string(data)) == pid {
			_ = os.Remove(pidPath)
		}
		_ = os.Remove(stopPath)
	}, nil
}
