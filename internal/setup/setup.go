package setup

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const defaultAgentDPort = "8787"

type Options struct {
	ConfigPath      string
	ScanRoot        string
	BrowseRoot      string
	Listen          string
	AppServerListen string
	Force           bool
}

type Result struct {
	Created            bool     `json:"created"`
	ConfigPath         string   `json:"config_path"`
	Endpoint           string   `json:"endpoint"`
	Token              string   `json:"token"`
	ConnectURL         string   `json:"connect_url"`
	PairURL            string   `json:"pair_url"`
	ScanRoot           string   `json:"scan_root"`
	BrowseRoot         string   `json:"browse_root"`
	AppServerListen    string   `json:"app_server_listen"`
	AppServerTokenFile string   `json:"app_server_token_file"`
	Warnings           []string `json:"warnings"`
}

func Run(ctx context.Context, options Options) (Result, error) {
	cfgPath, err := resolveConfigPath(options.ConfigPath)
	if err != nil {
		return Result{}, err
	}
	if fileExists(cfgPath) && !options.Force {
		// 已有配置时默认只读取配对信息，避免误覆盖用户已经绑定到 iPad 的 token。
		result, err := Pair(ctx, cfgPath)
		if err != nil {
			return Result{}, err
		}
		result.Created = false
		return result, nil
	}

	cfgDir := filepath.Dir(cfgPath)
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		return Result{}, fmt.Errorf("创建配置目录失败：%w", err)
	}
	token, err := randomHex(32)
	if err != nil {
		return Result{}, err
	}
	// 外侧 token 给 iPad 访问 agentd 使用；upstream token 只留在 Mac 本机，避免客户端拿到 app-server 直连凭证。
	appServerToken, err := randomHex(32)
	if err != nil {
		return Result{}, err
	}
	tokenFile := filepath.Join(cfgDir, "app-server-ws-token")
	if err := os.WriteFile(tokenFile, []byte(appServerToken+"\n"), 0o600); err != nil {
		return Result{}, fmt.Errorf("写入 app-server token 文件失败：%w", err)
	}

	scanRoot, err := defaultScanRoot(options.ScanRoot)
	if err != nil {
		return Result{}, err
	}
	browseRoot, err := defaultBrowseRoot(options.BrowseRoot)
	if err != nil {
		return Result{}, err
	}
	// 默认生成一个单机可运行配置：agentd 对外监听，内部托管 loopback WebSocket app-server。
	listen := strings.TrimSpace(options.Listen)
	if listen == "" {
		listen = defaultAgentDListen(ctx)
	}
	appServerListen := strings.TrimSpace(options.AppServerListen)
	if appServerListen == "" {
		appServerListen = "ws://127.0.0.1:4222"
	}

	cfg := config.Config{
		Listen: listen,
		Auth: config.AuthConfig{
			Token: token,
		},
		Runtime: config.RuntimeConfig{
			Type: "codex_app_server",
		},
		AppServer: config.AppServerConfig{
			Transport:   "ws",
			Managed:     true,
			Listen:      appServerListen,
			WSTokenFile: tokenFile,
		},
		Codex: config.CodexConfig{
			Bin:         defaultCodexBin(),
			DefaultArgs: []string{"--no-alt-screen"},
			Env: map[string]string{
				"TERM": "xterm-256color",
			},
		},
		Session: config.SessionConfig{
			OutputBufferBytes: 128 * 1024,
		},
		ScanRoots:   []string{scanRoot},
		BrowseRoots: []string{browseRoot},
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return Result{}, fmt.Errorf("编码配置失败：%w", err)
	}
	if err := os.WriteFile(cfgPath, append(raw, '\n'), 0o600); err != nil {
		return Result{}, fmt.Errorf("写入配置文件失败：%w", err)
	}

	result, err := Pair(ctx, cfgPath)
	if err != nil {
		return Result{}, err
	}
	result.Created = true
	result.ScanRoot = scanRoot
	result.BrowseRoot = browseRoot
	result.AppServerListen = appServerListen
	result.AppServerTokenFile = tokenFile
	return result, nil
}

func Pair(ctx context.Context, configPath string) (Result, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return Result{}, err
	}
	cfg, err := config.LoadForDoctor(cfgPath)
	if err != nil {
		return Result{}, err
	}
	return ResultFromConfig(ctx, cfgPath, cfg), nil
}

func ResultFromConfig(ctx context.Context, configPath string, cfg config.Config) Result {
	endpoint, warnings := endpointForListen(ctx, cfg.Listen)
	token := strings.TrimSpace(cfg.Auth.Token)
	if token == "" {
		warnings = append(warnings, "配置中没有 auth.token，iPad 无法完成鉴权；请重新执行 agentd setup --force")
	}
	scanRoot := ""
	if len(cfg.ScanRoots) > 0 {
		scanRoot = cfg.ScanRoots[0]
	}
	browseRoot := ""
	if len(cfg.BrowseRoots) > 0 {
		browseRoot = cfg.BrowseRoots[0]
	}
	return Result{
		ConfigPath:         configPath,
		Endpoint:           endpoint,
		Token:              token,
		ConnectURL:         ConnectURL(endpoint, token),
		PairURL:            PairURL(endpoint, token),
		ScanRoot:           scanRoot,
		BrowseRoot:         browseRoot,
		AppServerListen:    cfg.AppServer.Listen,
		AppServerTokenFile: cfg.AppServer.WSTokenFile,
		Warnings:           warnings,
	}
}

func ConnectURL(endpoint, token string) string {
	return connectionURL("connect", endpoint, token)
}

func PairURL(endpoint, token string) string {
	return connectionURL("pair", endpoint, token)
}

func connectionURL(route, endpoint, token string) string {
	values := url.Values{}
	values.Set("endpoint", endpoint)
	values.Set("token", token)
	return "mimiremote://" + route + "?" + values.Encode()
}

func resolveConfigPath(path string) (string, error) {
	value := strings.TrimSpace(path)
	if value == "" {
		value = config.DefaultPath()
	}
	if strings.HasPrefix(value, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		value = filepath.Join(home, strings.TrimPrefix(value, "~/"))
	}
	abs, err := filepath.Abs(value)
	if err != nil {
		return "", fmt.Errorf("解析配置路径失败：%w", err)
	}
	return abs, nil
}

func defaultScanRoot(raw string) (string, error) {
	if strings.TrimSpace(raw) != "" {
		return filepath.Abs(raw)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	codeDir := filepath.Join(home, "code")
	if stat, err := os.Stat(codeDir); err == nil && stat.IsDir() {
		return codeDir, nil
	}
	cwd, err := os.Getwd()
	if err == nil && strings.HasPrefix(cwd, home) {
		// 没有 ~/code 时优先使用用户当前运行 setup 的目录，避免默认扫描整个 Home。
		return cwd, nil
	}
	return home, nil
}

// defaultBrowseRoot 决定 iPad 目录浏览/打开 workspace 的授权根。和 scan root 分开：
// scan root 控制项目发现 + gateway 项目 allowlist，browse root 只扩大“可打开的目录”，
// 默认给整个用户 Home，这样 ~/finance 这类不在扫描根里的目录也能打开。
func defaultBrowseRoot(raw string) (string, error) {
	if strings.TrimSpace(raw) != "" {
		return filepath.Abs(raw)
	}
	return os.UserHomeDir()
}

func defaultAgentDListen(ctx context.Context) string {
	if ip := firstTailscaleIP(ctx); ip != "" {
		return net.JoinHostPort(ip, defaultAgentDPort)
	}
	return net.JoinHostPort("127.0.0.1", defaultAgentDPort)
}

func defaultCodexBin() string {
	if path, err := exec.LookPath("codex"); err == nil && strings.TrimSpace(path) != "" {
		return path
	}
	return "codex"
}

func endpointForListen(ctx context.Context, listen string) (string, []string) {
	host, port := splitListen(listen)
	warnings := []string{}
	if port == "" {
		port = defaultAgentDPort
	}
	if host == "" {
		host = "127.0.0.1"
	}
	if host == "0.0.0.0" || host == "::" || host == "[::]" {
		if ip := firstTailscaleIP(ctx); ip != "" {
			host = ip
		} else {
			host = "127.0.0.1"
			warnings = append(warnings, "agentd 绑定在所有网卡，但未检测到 Tailscale IP；请确认 iPad 能访问这台 Mac")
		}
	}
	if isLoopbackHost(host) {
		warnings = append(warnings, "当前 Endpoint 是本机地址，只适合 Mac 本机或模拟器；iPad 真机建议安装并登录 Tailscale 后重新执行 agentd setup --force")
	}
	return (&url.URL{Scheme: "http", Host: net.JoinHostPort(host, port)}).String(), warnings
}

func splitListen(listen string) (string, string) {
	value := strings.TrimSpace(listen)
	if value == "" {
		return "", ""
	}
	if strings.Contains(value, "://") {
		if parsed, err := url.Parse(value); err == nil {
			value = parsed.Host
		}
	}
	host, port, err := net.SplitHostPort(value)
	if err == nil {
		return strings.Trim(host, "[]"), port
	}
	if strings.Count(value, ":") == 0 {
		return value, ""
	}
	return "", ""
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

func firstTailscaleIP(ctx context.Context) string {
	bin, err := exec.LookPath("tailscale")
	if err != nil {
		return ""
	}
	runCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(runCtx, bin, "ip", "-4").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		ip := strings.TrimSpace(line)
		if net.ParseIP(ip) != nil {
			return ip
		}
	}
	return ""
}

func randomHex(bytes int) (string, error) {
	buf := make([]byte, bytes)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("生成随机 token 失败：%w", err)
	}
	return hex.EncodeToString(buf), nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
