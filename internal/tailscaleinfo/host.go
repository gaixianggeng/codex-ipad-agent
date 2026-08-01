package tailscaleinfo

import (
	"context"
	"encoding/json"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const statusOutputLimit = 2 * 1024 * 1024

var (
	tailscaleIPv4Prefix = netip.MustParsePrefix("100.64.0.0/10")
	tailscaleIPv6Prefix = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// Host 描述当前 agentd 所在的 Tailscale 设备。DNSName 是可变路由元数据，
// 不能替代 installation_id 成为客户端身份主键。
type Host struct {
	DNSName    string `json:"tailscale_dns_name,omitempty"`
	DeviceName string `json:"tailscale_device_name,omitempty"`
}

type statusSnapshot struct {
	Self struct {
		DNSName string `json:"DNSName"`
	} `json:"Self"`
}

type statusCommand func(context.Context) ([]byte, error)

// Discover 从本机 Tailscale CLI 读取 MagicDNS 名称。CLI 不可用、MagicDNS
// 未启用或输出异常时返回空值，让 LAN-only 和旧环境继续使用 IP Endpoint。
func Discover(ctx context.Context) Host {
	return inspect(ctx, runStatus)
}

func inspect(ctx context.Context, command statusCommand) Host {
	runCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	output, err := command(runCtx)
	if err != nil || len(output) == 0 || len(output) > statusOutputLimit {
		return Host{}
	}
	var status statusSnapshot
	if err := json.Unmarshal(output, &status); err != nil {
		return Host{}
	}
	dnsName := normalizeDNSName(status.Self.DNSName)
	if dnsName == "" {
		return Host{}
	}
	return Host{
		DNSName:    dnsName,
		DeviceName: strings.SplitN(dnsName, ".", 2)[0],
	}
}

func normalizeDNSName(raw string) string {
	value := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), ".")
	if len(value) == 0 || len(value) > 253 || !strings.Contains(value, ".") {
		return ""
	}
	for _, label := range strings.Split(value, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return ""
		}
		for _, char := range label {
			if (char >= 'a' && char <= 'z') ||
				(char >= '0' && char <= '9') ||
				char == '-' {
				continue
			}
			return ""
		}
	}
	return value
}

// Resolver 对空结果同样做短缓存，避免高频 /api/version 探测反复启动 CLI。
// TTL 到期后会重新读取，从而让设备改名后的 IP 回退连接可以刷新 DNS 路由。
type Resolver struct {
	mu        sync.Mutex
	ttl       time.Duration
	lookup    func(context.Context) Host
	cached    Host
	expiresAt time.Time
}

func NewResolver(ttl time.Duration) *Resolver {
	return newResolver(ttl, Discover)
}

func newResolver(ttl time.Duration, lookup func(context.Context) Host) *Resolver {
	if ttl <= 0 {
		ttl = time.Minute
	}
	return &Resolver{ttl: ttl, lookup: lookup}
}

func (r *Resolver) Lookup(ctx context.Context) Host {
	if r == nil {
		return Host{}
	}
	now := time.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	if now.Before(r.expiresAt) {
		return r.cached
	}
	r.cached = r.lookup(ctx)
	r.expiresAt = now.Add(r.ttl)
	return r.cached
}

func IsTailscaleEndpoint(endpoint string) bool {
	parsed, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil {
		return false
	}
	ip, err := netip.ParseAddr(strings.Trim(parsed.Hostname(), "[]"))
	return err == nil && IsTailscaleAddress(ip)
}

func IsTailscaleAddress(ip netip.Addr) bool {
	ip = ip.Unmap()
	return tailscaleIPv4Prefix.Contains(ip) || tailscaleIPv6Prefix.Contains(ip)
}

func runStatus(ctx context.Context) ([]byte, error) {
	bin, err := FindCLI()
	if err != nil {
		return nil, err
	}
	return exec.CommandContext(ctx, bin, "status", "--json").Output()
}

func FindCLI() (string, error) {
	if bin, err := exec.LookPath("tailscale"); err == nil {
		return bin, nil
	}
	// macOS GUI 安装不一定把 CLI 放进后台服务的 PATH；固定应用路径是官方安装包的入口。
	const macOSAppCLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
	if info, err := os.Stat(macOSAppCLI); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
		return macOSAppCLI, nil
	}
	return exec.LookPath("tailscale")
}
