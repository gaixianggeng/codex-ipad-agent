//go:build !windows

package main

import (
	"os"
	"os/signal"
	"syscall"
)

func notifyServeSignals(stopCh chan<- os.Signal) func() {
	signal.Notify(stopCh, os.Interrupt, syscall.SIGTERM)
	return func() {
		signal.Stop(stopCh)
	}
}
