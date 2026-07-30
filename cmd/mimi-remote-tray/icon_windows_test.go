//go:build windows

package main

import (
	"path/filepath"
	"runtime"
	"testing"
)

func TestWindowsApplicationIconCanBeLoaded(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate icon test source")
	}
	iconPath := filepath.Join(
		filepath.Dir(sourceFile),
		"..",
		"..",
		"packaging",
		"windows",
		"mimi-remote.ico",
	)
	icon := loadIconFromPath(iconPath)
	if icon == 0 {
		t.Fatalf("Windows could not load the packaged multi-size icon: %s", iconPath)
	}
	procDestroyIcon.Call(icon)
}
