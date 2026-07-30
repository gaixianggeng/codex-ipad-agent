//go:build windows

package httpapi

import (
	"fmt"
	"net"
)

func prepareClaudeBridgeEndpoint(_ string) (string, string, []string, error) {
	// Reserve an ephemeral loopback address long enough to let the OS choose a
	// free port. The bridge binds it immediately after this listener closes.
	// A different local process could theoretically win that small race; the
	// bounded startup probe reports the failure and the next ensure retries
	// with a fresh port.
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return "", "", nil, fmt.Errorf("分配 Claude bridge loopback 端口失败：%w", err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		return "", "", nil, fmt.Errorf("释放 Claude bridge 预留端口失败：%w", err)
	}
	return "tcp", address, []string{"--tcp-listen", address}, nil
}
