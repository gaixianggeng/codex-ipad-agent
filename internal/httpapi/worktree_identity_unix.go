//go:build !windows

package httpapi

func platformFilesystemObjectIdentity(string) (string, bool) { return "", false }

func sameFilesystemPath(left, right string) bool { return left == right }
