package doctor

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/url"
	"os/exec"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
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
	tokenOK := c.cfg.DevInsecure || c.cfg.Auth.Token != ""
	tokenMessage := "Token 已配置"
	if !tokenOK {
		tokenMessage = "Token 未配置"
	}
	codexOK := commandExists(c.cfg.Codex.Bin)
	codexMessage := "Codex CLI 可执行"
	if !codexOK {
		codexMessage = "未找到 Codex CLI"
	}
	checks := []Check{
		{Name: "token", OK: tokenOK, Message: tokenMessage, Fix: "执行 agentd setup 生成随机 token，或设置 AGENTD_TOKEN"},
		{Name: "projects", OK: len(c.registry.List()) > 0, Message: fmt.Sprintf("已加载 %d 个项目", len(c.registry.List())), Fix: "在 config.json 配置 projects，或设置 AGENTD_PROJECTS=/path/a,/path/b"},
		{Name: "codex", OK: codexOK, Message: codexMessage, Fix: "安装 Codex CLI 并确认 codex 在 PATH 中；Homebrew service 推荐先运行 agentd setup 记录绝对路径"},
		c.runtimeCheck(),
		{Name: "tailscale", OK: commandExists("tailscale"), Message: "检测到 Tailscale 命令", Fix: "安装并登录 Tailscale：https://tailscale.com/download"},
	}
	if c.needsCodexAppServerCheck() {
		checks = append(checks, c.codexAppServerCheck(ctx))
	}
	if check := c.appServerGatewayCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if checkPort {
		checks = append(checks, c.portChecks(ctx)...)
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
		runtimeType = "codex_app_server"
	}
	if runtimeType != "codex_app_server" {
		return Check{Name: "runtime", OK: false, Message: fmt.Sprintf("当前运行时配置无效：%s", runtimeType), Fix: "设置 runtime.type=codex_app_server，或重新执行 agentd setup"}
	}
	return Check{Name: "runtime", OK: true, Message: "当前运行时：codex_app_server"}
}

func (c *Checker) appServerGatewayCheck() Check {
	transport := c.cfg.AppServer.Transport
	if transport == "" {
		transport = "ws"
	}
	switch transport {
	case "ws":
		if c.cfg.AppServer.Listen == "" {
			return Check{Name: "app-server", OK: false, Message: "app-server ws upstream 未配置", Fix: "执行 agentd setup 生成默认 loopback upstream"}
		}
		if isLoopbackListen(c.cfg.AppServer.Listen) {
			return Check{Name: "app-server", OK: true, Message: "Codex app-server ws upstream 仅限 loopback 本机访问"}
		}
		return Check{
			Name:    "app-server",
			OK:      false,
			Message: "Codex app-server 不应暴露到非 loopback 网络",
			Fix:     "将 app_server.listen 改为 127.0.0.1，仅让 iPad 连接 agentd",
		}
	default:
		return Check{Name: "app-server", OK: false, Message: "app-server transport 配置无效", Fix: "设置 AGENTD_APP_SERVER_TRANSPORT=ws"}
	}
}

func (c *Checker) needsCodexAppServerCheck() bool {
	return true
}

func (c *Checker) codexAppServerCheck(ctx context.Context) Check {
	if !commandExists(c.cfg.Codex.Bin) {
		return Check{Name: "codex-app-server", OK: false, Message: "无法检查 Codex app-server 能力", Fix: "先安装 Codex CLI"}
	}
	runCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(runCtx, c.cfg.Codex.Bin, "app-server", "--help").CombinedOutput()
	if err != nil {
		return Check{Name: "codex-app-server", OK: false, Message: "Codex CLI 不支持 app-server 命令", Fix: "升级 Codex CLI，然后重新执行 agentd doctor"}
	}
	help := string(out)
	for _, flag := range []string{"--listen", "--ws-auth", "--ws-token-file"} {
		if !strings.Contains(help, flag) {
			return Check{Name: "codex-app-server", OK: false, Message: "Codex app-server 缺少必要 WebSocket 参数", Fix: "升级 Codex CLI 到支持 app-server WebSocket 的版本"}
		}
	}
	return Check{Name: "codex-app-server", OK: true, Message: "Codex app-server WebSocket 能力可用"}
}

func isLoopbackListen(raw string) bool {
	if strings.Contains(raw, "://") {
		parsed, err := url.Parse(raw)
		if err != nil {
			return false
		}
		raw = parsed.Host
	}
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

func (c *Checker) portChecks(ctx context.Context) []Check {
	checks := []Check{
		c.portCheck(ctx, "agentd-port", c.cfg.Listen, "agentd"),
	}
	if strings.EqualFold(c.cfg.AppServer.Transport, "ws") && c.cfg.AppServer.Managed && strings.TrimSpace(c.cfg.AppServer.Listen) != "" {
		checks = append(checks, c.portCheck(ctx, "app-server-port", c.cfg.AppServer.Listen, "app-server upstream"))
	}
	return checks
}

func (c *Checker) portCheck(ctx context.Context, name, listen, label string) Check {
	address, err := tcpAddressFromListen(listen)
	if err != nil {
		return Check{Name: name, OK: false, Message: fmt.Sprintf("%s 监听地址无效", label), Fix: err.Error()}
	}
	var listenConfig net.ListenConfig
	listener, err := listenConfig.Listen(ctx, "tcp", address)
	if err != nil {
		return Check{Name: name, OK: false, Message: fmt.Sprintf("%s 端口不可监听", label), Fix: "修改配置里的监听地址/端口，或关闭占用该端口的进程"}
	}
	_ = listener.Close()
	return Check{Name: name, OK: true, Message: fmt.Sprintf("%s 端口可监听", label)}
}

func tcpAddressFromListen(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", fmt.Errorf("监听地址不能为空")
	}
	if strings.Contains(value, "://") {
		parsed, err := url.Parse(value)
		if err != nil {
			return "", fmt.Errorf("解析监听地址失败：%w", err)
		}
		value = parsed.Host
	}
	if _, _, err := net.SplitHostPort(value); err == nil {
		return value, nil
	}
	if strings.Count(value, ":") == 0 {
		return "", fmt.Errorf("监听地址缺少端口：%s", value)
	}
	return "", fmt.Errorf("监听地址格式无效：%s", value)
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
