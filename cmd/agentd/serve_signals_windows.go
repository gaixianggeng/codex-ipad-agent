//go:build windows

package main

import (
	"os"
	"os/signal"
	"time"
)

func notifyServeSignals(stopCh chan<- os.Signal) func() {
	// Windows 控制台只提供 os.Interrupt。计划任务结束进程时不会投递
	// POSIX SIGTERM；当前用户服务使用一个私有 stop marker 请求优雅退出。
	signal.Notify(stopCh, os.Interrupt)
	done := make(chan struct{})
	go func() {
		path, err := windowsManagedStopPath()
		if err != nil {
			return
		}
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if _, err := os.Stat(path); err == nil {
					select {
					case stopCh <- os.Interrupt:
					default:
					}
					return
				}
			}
		}
	}()
	return func() {
		signal.Stop(stopCh)
		close(done)
		if path, err := windowsManagedStopPath(); err == nil {
			_ = os.Remove(path)
		}
	}
}
