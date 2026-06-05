package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const AppName = "codex-ipad-agent"

type Config struct {
	Listen      string          `json:"listen"`
	Auth        AuthConfig      `json:"auth"`
	Runtime     RuntimeConfig   `json:"runtime"`
	AppServer   AppServerConfig `json:"app_server"`
	Codex       CodexConfig     `json:"codex"`
	Session     SessionConfig   `json:"session"`
	Projects    []ProjectConfig `json:"projects"`
	ScanRoots   []string        `json:"scan_roots"`
	DevInsecure bool            `json:"dev_insecure"`
}

type AuthConfig struct {
	Token           string `json:"token"`
	AllowQueryToken bool   `json:"allow_query_token"`
}

type CodexConfig struct {
	Bin         string            `json:"bin"`
	DefaultArgs []string          `json:"default_args"`
	Env         map[string]string `json:"env"`
}

type RuntimeConfig struct {
	Type        string `json:"type"`
	FallbackPTY bool   `json:"fallback_pty"`
}

type AppServerConfig struct {
	Transport   string `json:"transport"`
	Managed     bool   `json:"managed"`
	Listen      string `json:"listen,omitempty"`
	WSTokenFile string `json:"ws_token_file,omitempty"`
}

type SessionConfig struct {
	OutputBufferBytes int `json:"output_buffer_bytes"`
}

type ProjectConfig struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
}

func DefaultPath() string {
	if v := strings.TrimSpace(os.Getenv("AGENTD_CONFIG")); v != "" {
		return v
	}
	dir, err := UserConfigDir()
	if err != nil {
		return "config.json"
	}
	return filepath.Join(dir, "config.json")
}

func UserConfigDir() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, AppName), nil
}

func Load(path string) (Config, error) {
	cfg, err := load(path)
	if err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func LoadForDoctor(path string) (Config, error) {
	return load(path)
}

func load(path string) (Config, error) {
	cfg := defaults()
	path = expandPath(path)
	if path != "" {
		if b, err := os.ReadFile(path); err == nil {
			if err := json.Unmarshal(b, &cfg); err != nil {
				return Config{}, fmt.Errorf("解析配置文件失败：%w", err)
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return Config{}, fmt.Errorf("读取配置文件失败：%w", err)
		}
	}

	applyEnv(&cfg)
	cfg.Runtime.Type = normalizeRuntimeType(cfg.Runtime.Type)
	cfg.AppServer.Transport = strings.TrimSpace(strings.ToLower(cfg.AppServer.Transport))
	scanned, err := discoverProjects(cfg.ScanRoots)
	if err != nil {
		return Config{}, err
	}
	cfg.Projects = mergeProjects(cfg.Projects, scanned)
	return cfg, nil
}

func expandPath(path string) string {
	value := strings.TrimSpace(path)
	if !strings.HasPrefix(value, "~/") {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return value
	}
	return filepath.Join(home, strings.TrimPrefix(value, "~/"))
}

func defaults() Config {
	return Config{
		Listen: "127.0.0.1:8787",
		Runtime: RuntimeConfig{
			Type:        "pty",
			FallbackPTY: true,
		},
		AppServer: AppServerConfig{
			Transport: "stdio",
			Managed:   true,
		},
		Codex: CodexConfig{
			Bin:         "codex",
			DefaultArgs: []string{"--no-alt-screen"},
			Env: map[string]string{
				"TERM": "xterm-256color",
			},
		},
		Session: SessionConfig{
			OutputBufferBytes: 128 * 1024,
		},
	}
}

func applyEnv(cfg *Config) {
	if v := os.Getenv("AGENTD_LISTEN"); v != "" {
		cfg.Listen = v
	} else {
		bind := os.Getenv("AGENTD_BIND")
		port := os.Getenv("AGENTD_PORT")
		if bind != "" || port != "" {
			if bind == "" {
				bind = "127.0.0.1"
			}
			if port == "" {
				port = "8787"
			}
			cfg.Listen = net.JoinHostPort(bind, port)
		}
	}
	if v := os.Getenv("AGENTD_TOKEN"); v != "" {
		cfg.Auth.Token = v
	}
	if v := os.Getenv("AGENTD_ALLOW_QUERY_TOKEN"); v == "1" || strings.EqualFold(v, "true") {
		cfg.Auth.AllowQueryToken = true
	}
	if v := os.Getenv("AGENTD_CODEX_BIN"); v != "" {
		cfg.Codex.Bin = v
	}
	if v := os.Getenv("AGENTD_CODEX_ARGS"); v != "" {
		cfg.Codex.DefaultArgs = strings.Fields(v)
	}
	if v := os.Getenv("AGENTD_RUNTIME"); v != "" {
		cfg.Runtime.Type = normalizeRuntimeType(v)
	}
	if v := os.Getenv("AGENTD_APP_SERVER_TRANSPORT"); v != "" {
		cfg.AppServer.Transport = strings.TrimSpace(strings.ToLower(v))
	}
	if v := os.Getenv("AGENTD_APP_SERVER_LISTEN"); v != "" {
		cfg.AppServer.Listen = strings.TrimSpace(v)
	}
	if v := os.Getenv("AGENTD_APP_SERVER_WS_TOKEN_FILE"); v != "" {
		cfg.AppServer.WSTokenFile = strings.TrimSpace(v)
	}
	if v := os.Getenv("AGENTD_APP_SERVER_MANAGED"); v != "" {
		cfg.AppServer.Managed = truthy(v)
	}
	if v := os.Getenv("AGENTD_APP_SERVER_FALLBACK_PTY"); v != "" {
		cfg.Runtime.FallbackPTY = truthy(v)
	}
	if v := os.Getenv("AGENTD_DEV_INSECURE"); v == "1" || strings.EqualFold(v, "true") {
		cfg.DevInsecure = true
	}
	if v := os.Getenv("AGENTD_OUTPUT_BUFFER_BYTES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			cfg.Session.OutputBufferBytes = n
		}
	}
	if v := os.Getenv("AGENTD_PROJECTS"); v != "" {
		cfg.Projects = parseProjectsEnv(v)
	}
	if v := os.Getenv("AGENTD_SCAN_ROOTS"); v != "" {
		cfg.ScanRoots = splitCSV(v)
	}
}

func truthy(raw string) bool {
	return raw == "1" || strings.EqualFold(raw, "true") || strings.EqualFold(raw, "yes")
}

func normalizeRuntimeType(raw string) string {
	value := strings.TrimSpace(strings.ToLower(raw))
	switch value {
	case "app_server", "app-server", "codex-app-server":
		return "codex_app_server"
	default:
		return value
	}
}

func parseProjectsEnv(raw string) []ProjectConfig {
	parts := splitCSV(raw)
	projects := make([]ProjectConfig, 0, len(parts))
	seen := map[string]int{}
	for _, path := range parts {
		name := filepath.Base(path)
		id := sanitizeID(name)
		seen[id]++
		if seen[id] > 1 {
			id = fmt.Sprintf("%s-%d", id, seen[id])
		}
		projects = append(projects, ProjectConfig{ID: id, Name: name, Path: path})
	}
	return projects
}

func splitCSV(raw string) []string {
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		item := strings.TrimSpace(part)
		if item != "" {
			out = append(out, item)
		}
	}
	return out
}

func discoverProjects(roots []string) ([]ProjectConfig, error) {
	var projects []ProjectConfig
	for _, root := range roots {
		abs, err := filepath.Abs(root)
		if err != nil {
			return nil, fmt.Errorf("解析扫描根目录失败 %s：%w", root, err)
		}
		entries, err := os.ReadDir(abs)
		if err != nil {
			return nil, fmt.Errorf("读取扫描根目录失败 %s：%w", abs, err)
		}

		// 根目录本身也加入，方便用户仍然能在整个工作区运行 Codex。
		projects = append(projects, projectFromPath(abs))
		for _, entry := range entries {
			if !entry.IsDir() || skipScanDir(entry.Name()) {
				continue
			}
			child := filepath.Join(abs, entry.Name())
			projects = append(projects, projectFromPath(child))
		}
	}
	return projects, nil
}

func skipScanDir(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch name {
	case "node_modules", "vendor", "dist", "build", "target", "tmp", "temp":
		return true
	default:
		return false
	}
}

func projectFromPath(path string) ProjectConfig {
	name := filepath.Base(path)
	return ProjectConfig{ID: sanitizeID(name), Name: name, Path: path}
}

func mergeProjects(explicit, scanned []ProjectConfig) []ProjectConfig {
	merged := make([]ProjectConfig, 0, len(explicit)+len(scanned))
	seenPath := map[string]bool{}
	seenID := map[string]int{}
	add := func(project ProjectConfig) {
		abs, err := filepath.Abs(project.Path)
		if err == nil {
			project.Path = abs
		}
		key := project.Path
		if seenPath[key] {
			return
		}
		seenPath[key] = true
		if project.ID == "" {
			project.ID = sanitizeID(filepath.Base(project.Path))
		}
		baseID := project.ID
		seenID[baseID]++
		if seenID[baseID] > 1 {
			project.ID = fmt.Sprintf("%s-%d", baseID, seenID[baseID])
		}
		if project.Name == "" {
			project.Name = filepath.Base(project.Path)
		}
		merged = append(merged, project)
	}
	for _, project := range explicit {
		add(project)
	}
	for _, project := range scanned {
		add(project)
	}
	return merged
}

func sanitizeID(raw string) string {
	raw = strings.ToLower(raw)
	var b strings.Builder
	for _, r := range raw {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r)
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '-' || r == '_':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	id := strings.Trim(b.String(), "-_")
	if id == "" {
		return "project"
	}
	return id
}

func (c Config) Validate() error {
	if c.Listen == "" {
		return fmt.Errorf("listen 不能为空")
	}
	if c.Auth.Token == "" && !c.DevInsecure {
		return fmt.Errorf("AGENTD_TOKEN 或 auth.token 不能为空；开发临时绕过请设置 AGENTD_DEV_INSECURE=true")
	}
	if c.Auth.Token != "" && len(c.Auth.Token) < 16 {
		return fmt.Errorf("token 太短，建议至少 32 字符")
	}
	if strings.Contains(strings.ToLower(c.Auth.Token), "change-me") {
		return fmt.Errorf("token 仍是示例占位值，请执行 agentd setup 生成随机 token")
	}
	if c.Codex.Bin == "" {
		return fmt.Errorf("codex.bin 不能为空")
	}
	switch normalizeRuntimeType(c.Runtime.Type) {
	case "pty", "codex_app_server":
	default:
		return fmt.Errorf("runtime.type 只支持 pty 或 codex_app_server")
	}
	switch strings.ToLower(strings.TrimSpace(c.AppServer.Transport)) {
	case "stdio", "unix", "ws", "off":
	default:
		return fmt.Errorf("app_server.transport 只支持 stdio、unix、ws 或 off")
	}
	if strings.EqualFold(c.AppServer.Transport, "ws") && c.AppServer.Listen != "" && !isLoopbackListen(c.AppServer.Listen) {
		return fmt.Errorf("app_server.listen 只允许 loopback；iPad 应连接 agentd，不应直连 Codex app-server")
	}
	if c.Session.OutputBufferBytes <= 0 {
		return fmt.Errorf("session.output_buffer_bytes 必须大于 0")
	}
	if len(c.Projects) == 0 {
		return fmt.Errorf("projects 不能为空；可在 config.json 配置，或设置 AGENTD_PROJECTS=/path/a,/path/b 或 AGENTD_SCAN_ROOTS=/workspace")
	}
	return nil
}

func isLoopbackListen(raw string) bool {
	value := strings.TrimSpace(raw)
	if value == "" {
		return true
	}
	if strings.Contains(value, "://") {
		parsed, err := url.Parse(value)
		if err != nil {
			return false
		}
		value = parsed.Host
	}
	if strings.HasPrefix(value, "127.") || strings.HasPrefix(value, "localhost:") || strings.HasPrefix(value, "[::1]:") || strings.HasPrefix(value, "::1:") {
		return true
	}
	host, _, err := net.SplitHostPort(value)
	if err != nil {
		return value == "localhost" || value == "::1"
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
