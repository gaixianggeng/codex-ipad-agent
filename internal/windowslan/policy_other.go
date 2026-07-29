//go:build !windows

package windowslan

import "context"

func Check(context.Context, string) (Status, error) {
	return Status{FirewallValid: true, ProfilePrivate: true}, nil
}
