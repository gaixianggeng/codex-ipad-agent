//go:build windows

package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
)

func TestInspectPlatformNetworkStatusRedactsUnsafeRuleNames(t *testing.T) {
	previous := windowsLANStatusCheck
	windowsLANStatusCheck = func(context.Context, string) (windowslan.Status, error) {
		return windowslan.Status{
			FirewallValid:   false,
			ProfilePrivate:  false,
			InterfaceAlias:  "WLAN",
			NetworkCategory: "Public",
			UnsafeRules:     []string{"secret rule one", "secret rule two"},
		}, nil
	}
	t.Cleanup(func() { windowsLANStatusCheck = previous })

	status := inspectPlatformNetworkStatus(context.Background(), config.Config{
		Listen:  "0.0.0.0:8787",
		Network: config.NetworkConfig{AllowLAN: true},
	})
	if !status.PolicyChecked || status.PolicyOK || status.UnsafeRuleCount != 2 ||
		status.InterfaceAlias != "WLAN" || status.NetworkCategory != "Public" {
		t.Fatalf("unexpected Windows network status: %+v", status)
	}
	raw, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"secret rule one", "secret rule two"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("network status must not expose firewall rule names: %s", raw)
		}
	}
}

func TestInspectPlatformNetworkStatusDoesNotRequireManagedRuleWhenLANDisabled(t *testing.T) {
	previous := windowsLANStatusCheck
	windowsLANStatusCheck = func(context.Context, string) (windowslan.Status, error) {
		return windowslan.Status{
			FirewallValid:   false,
			ProfilePrivate:  false,
			InterfaceAlias:  "WLAN",
			NetworkCategory: "Public",
		}, nil
	}
	t.Cleanup(func() { windowsLANStatusCheck = previous })

	status := inspectPlatformNetworkStatus(context.Background(), config.Config{
		Listen: "127.0.0.1:8787",
	})
	if !status.PolicyChecked || !status.PolicyOK || status.Mode != "loopback" {
		t.Fatalf("loopback-only mode must not require a LAN firewall rule: %+v", status)
	}
}
