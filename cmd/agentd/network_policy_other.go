//go:build !windows

package main

func ensurePlatformLANAccessAllowed() error {
	return nil
}
