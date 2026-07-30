//go:build windows

package windowslan

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestParseStatus(t *testing.T) {
	status, err := parseStatus([]byte(`{"firewall_valid":false,"profile_private":false,"interface_alias":"WLAN","network_category":"Public","unsafe_rules":["agentd.exe","agentd.exe"]}`))
	if err != nil {
		t.Fatal(err)
	}
	if status.Ready() {
		t.Fatal("Public 网络不能通过 Windows LAN 安全策略")
	}
	if status.FirewallValid || status.ProfilePrivate || len(status.UnsafeRules) != 2 {
		t.Fatalf("状态解析错误：%+v", status)
	}
	if status.InterfaceLabel() != "WLAN" || status.CategoryLabel() != "Public" {
		t.Fatalf("网络说明解析错误：%+v", status)
	}
}

func TestLivePolicyWhenAgentPathIsProvided(t *testing.T) {
	agentPath := os.Getenv("MIMI_WINDOWS_LAN_POLICY_AGENT")
	if agentPath == "" {
		t.Skip("set MIMI_WINDOWS_LAN_POLICY_AGENT for the live Windows policy probe")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	status, err := Check(ctx, agentPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("live Windows LAN policy: %+v", status)
	if expected := os.Getenv("MIMI_WINDOWS_LAN_POLICY_EXPECT_READY"); expected != "" {
		wantReady := expected == "true"
		if status.Ready() != wantReady {
			t.Fatalf("Ready()=%v, want %v: %+v", status.Ready(), wantReady, status)
		}
	}
}
