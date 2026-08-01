package tailscaleinfo

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestInspectReturnsNormalizedMagicDNSHost(t *testing.T) {
	host := inspect(context.Background(), func(context.Context) ([]byte, error) {
		return []byte(`{"Self":{"DNSName":"Studio-Mac.alpha-beta.ts.net."}}`), nil
	})
	if host.DNSName != "studio-mac.alpha-beta.ts.net" || host.DeviceName != "studio-mac" {
		t.Fatalf("MagicDNS 元数据异常：%+v", host)
	}
}

func TestInspectFailsOpenWithoutValidMagicDNS(t *testing.T) {
	tests := []struct {
		name   string
		output string
		err    error
	}{
		{name: "CLI unavailable", err: errors.New("missing")},
		{name: "no MagicDNS", output: `{"Self":{"DNSName":""}}`},
		{name: "short hostname", output: `{"Self":{"DNSName":"studio-mac"}}`},
		{name: "invalid hostname", output: `{"Self":{"DNSName":"bad name.tail.ts.net"}}`},
		{name: "invalid JSON", output: `{`},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			host := inspect(context.Background(), func(context.Context) ([]byte, error) {
				return []byte(testCase.output), testCase.err
			})
			if host != (Host{}) {
				t.Fatalf("异常环境必须回退为空元数据，got=%+v", host)
			}
		})
	}
}

func TestResolverCachesEmptyAndNonEmptyResults(t *testing.T) {
	var calls atomic.Int32
	resolver := newResolver(time.Minute, func(context.Context) Host {
		if calls.Add(1) == 1 {
			return Host{}
		}
		return Host{DNSName: "studio.tail.ts.net", DeviceName: "studio"}
	})
	if got := resolver.Lookup(context.Background()); got != (Host{}) {
		t.Fatalf("首次空结果异常：%+v", got)
	}
	if got := resolver.Lookup(context.Background()); got != (Host{}) {
		t.Fatalf("TTL 内应复用空结果：%+v", got)
	}
	if calls.Load() != 1 {
		t.Fatalf("TTL 内不应重复运行 CLI，calls=%d", calls.Load())
	}
}

func TestIsTailscaleEndpoint(t *testing.T) {
	if !IsTailscaleEndpoint("http://100.100.20.30:8787") {
		t.Fatal("CGNAT Tailscale 地址应被识别")
	}
	if IsTailscaleEndpoint("http://192.168.1.2:8787") {
		t.Fatal("LAN 地址不应被识别为 Tailscale")
	}
}
