package doctor

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os/exec"
	"time"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
)

type Checker struct {
	version  string
	cfg      config.Config
	registry *projects.Registry
}

type Results struct {
	OK      bool    `json:"ok"`
	Version string  `json:"version"`
	Listen  string  `json:"listen"`
	Checks  []Check `json:"checks"`
}

type Check struct {
	Name    string `json:"name"`
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	Fix     string `json:"fix,omitempty"`
}

func NewChecker(version string, cfg config.Config, registry *projects.Registry) *Checker {
	return &Checker{version: version, cfg: cfg, registry: registry}
}

func (c *Checker) Run(ctx context.Context, checkPort bool) Results {
	checks := []Check{
		{Name: "token", OK: c.cfg.DevInsecure || c.cfg.Auth.Token != "", Message: "Token 已配置", Fix: `export AGENTD_TOKEN="$(openssl rand -hex 32)"`},
		{Name: "projects", OK: len(c.registry.List()) > 0, Message: fmt.Sprintf("已加载 %d 个项目", len(c.registry.List())), Fix: "在 config.json 配置 projects，或设置 AGENTD_PROJECTS=/path/a,/path/b"},
		{Name: "codex", OK: commandExists(c.cfg.Codex.Bin), Message: "Codex CLI 可执行", Fix: "安装 Codex CLI 并确认 codex 在 PATH 中"},
		c.runtimeCheck(),
		{Name: "tailscale", OK: commandExists("tailscale"), Message: "检测到 Tailscale 命令", Fix: "安装并登录 Tailscale：https://tailscale.com/download"},
	}
	if checkPort {
		checks = append(checks, c.portCheck(ctx))
	}

	ok := true
	for i := range checks {
		if checks[i].Name == "tailscale" && !checks[i].OK {
			checks[i].Message = "未检测到 Tailscale 命令，本机访问仍可使用"
			continue
		}
		if !checks[i].OK {
			ok = false
		}
	}
	return Results{OK: ok, Version: c.version, Listen: c.cfg.Listen, Checks: checks}
}

func (c *Checker) runtimeCheck() Check {
	runtimeType := c.cfg.Runtime.Type
	if runtimeType == "" {
		runtimeType = "pty"
	}
	if runtimeType != "codex_app_server" {
		return Check{Name: "runtime", OK: true, Message: fmt.Sprintf("当前运行时：%s", runtimeType)}
	}
	transport := c.cfg.AppServer.Transport
	if transport == "" {
		transport = "stdio"
	}
	switch transport {
	case "stdio":
		return Check{Name: "app-server", OK: true, Message: "Codex app-server 将通过 stdio 子进程访问"}
	case "unix":
		return Check{Name: "app-server", OK: true, Message: "Codex app-server 将通过 unix socket 本机访问"}
	case "ws":
		if c.cfg.AppServer.Listen == "" || isLoopbackListen(c.cfg.AppServer.Listen) {
			return Check{Name: "app-server", OK: true, Message: "Codex app-server ws 仅限 loopback 本机调试"}
		}
		return Check{
			Name:    "app-server",
			OK:      false,
			Message: "Codex app-server 不应暴露到非 loopback 网络",
			Fix:     "使用 stdio://，或将 app_server.listen 改为 127.0.0.1，仅让 iPad 连接 agentd",
		}
	default:
		return Check{Name: "app-server", OK: false, Message: "app-server transport 配置无效", Fix: "设置 AGENTD_APP_SERVER_TRANSPORT=stdio"}
	}
}

func isLoopbackListen(raw string) bool {
	host, _, err := net.SplitHostPort(raw)
	if err != nil {
		return raw == "localhost" || raw == "::1"
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (c *Checker) portCheck(ctx context.Context) Check {
	d := net.Dialer{Timeout: 500 * time.Millisecond}
	conn, err := d.DialContext(ctx, "tcp", c.cfg.Listen)
	if err == nil {
		_ = conn.Close()
		return Check{Name: "port", OK: false, Message: "端口已被占用", Fix: "修改 AGENTD_PORT 或关闭占用该端口的进程"}
	}
	return Check{Name: "port", OK: true, Message: "端口可监听"}
}

func commandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func Print(w io.Writer, results Results) {
	status := "OK"
	if !results.OK {
		status = "FAIL"
	}
	fmt.Fprintf(w, "agentd doctor [%s]\n\n", status)
	fmt.Fprintf(w, "Version: %s\n", results.Version)
	fmt.Fprintf(w, "Listen:  %s\n\n", results.Listen)
	for _, check := range results.Checks {
		marker := "OK"
		if !check.OK {
			marker = "FAIL"
		}
		fmt.Fprintf(w, "[%s] %s: %s\n", marker, check.Name, check.Message)
		if !check.OK && check.Fix != "" {
			fmt.Fprintf(w, "      Fix: %s\n", check.Fix)
		}
	}
	if b, err := json.MarshalIndent(results, "", "  "); err == nil {
		fmt.Fprintf(w, "\nJSON:\n%s\n", string(b))
	}
}
