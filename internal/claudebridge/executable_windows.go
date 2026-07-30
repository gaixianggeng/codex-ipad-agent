//go:build windows

package claudebridge

import (
	"os"
	"path/filepath"
	"strings"
)

// Windows executable permissions are ACL based; FileMode's Unix execute bits
// are not meaningful.  Keep explicit paths constrained to launchable suffixes.
func isExecutableFile(path string, info os.FileInfo) bool {
	if !info.Mode().IsRegular() {
		return false
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".exe", ".com", ".bat", ".cmd":
		return true
	default:
		return false
	}
}
