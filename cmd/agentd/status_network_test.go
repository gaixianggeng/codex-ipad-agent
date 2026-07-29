package main

import (
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestConfiguredAgentNetworkMode(t *testing.T) {
	tests := []struct {
		name string
		cfg  config.Config
		want string
	}{
		{
			name: "explicit LAN",
			cfg: config.Config{
				Listen:  "0.0.0.0:8787",
				Network: config.NetworkConfig{AllowLAN: true},
			},
			want: "lan",
		},
		{name: "loopback", cfg: config.Config{Listen: "127.0.0.1:8787"}, want: "loopback"},
		{name: "IPv6 loopback", cfg: config.Config{Listen: "[::1]:8787"}, want: "loopback"},
		{name: "Tailscale CGNAT", cfg: config.Config{Listen: "100.100.20.30:8787"}, want: "tailscale"},
		{name: "ordinary private address", cfg: config.Config{Listen: "192.168.1.20:8787"}, want: "specific"},
		{name: "hostname is not silently classified", cfg: config.Config{Listen: "example.test:8787"}, want: "unknown"},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			if got := configuredAgentNetworkMode(testCase.cfg); got != testCase.want {
				t.Fatalf("network mode = %q, want %q", got, testCase.want)
			}
		})
	}
}

func TestNetworkPolicyDoctorCheckUsesSanitizedCounts(t *testing.T) {
	check := networkPolicyDoctorCheck(agentNetworkStatus{
		Mode:            "lan",
		AllowLAN:        true,
		PolicyChecked:   true,
		UnsafeRuleCount: 2,
	})
	if check.Name != "windows-network-policy" || check.OK || check.Level != "error" {
		t.Fatalf("unexpected network policy check: %+v", check)
	}
	if check.Message == "" || check.Fix == "" {
		t.Fatalf("network policy check must be actionable: %+v", check)
	}
}
