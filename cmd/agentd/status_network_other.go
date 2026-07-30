//go:build !windows

package main

import (
	"context"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func inspectPlatformNetworkStatus(_ context.Context, cfg config.Config) agentNetworkStatus {
	result := configuredAgentNetworkStatus(cfg)
	result.PolicyChecked = true
	result.PolicyOK = true
	return result
}
