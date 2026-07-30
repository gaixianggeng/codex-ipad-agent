//go:build !windows

package config

import (
	"fmt"
	"io/fs"
	"os"
)

func prepareInstallationIDFile(file *os.File) error {
	return file.Chmod(installationIDFileMode)
}

func validateInstallationIDFilePermissions(info fs.FileInfo) error {
	if info.Mode().Perm() != installationIDFileMode {
		return fmt.Errorf(
			"权限必须是 0600，实际为 %04o",
			info.Mode().Perm(),
		)
	}
	return nil
}

func syncInstallationIDDirectory(dir string) error {
	file, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}
