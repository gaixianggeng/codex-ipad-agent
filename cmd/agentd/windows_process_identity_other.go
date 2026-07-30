//go:build !windows

package main

// Windows service command construction remains buildable on other hosts so its
// fake-schtasks tests can run there. Only Windows can validate a live process
// handle against the installed agentd executable.
var windowsManagedPIDMatchesExecutable = func(int) bool {
	return false
}
