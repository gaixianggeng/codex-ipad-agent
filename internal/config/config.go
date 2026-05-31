package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type Config struct {
	Listen      string          `json:"listen"`
	Auth        AuthConfig      `json:"auth"`
	Codex       CodexConfig     `json:"codex"`
	Session     SessionConfig   `json:"session"`
	Projects    []ProjectConfig `json:"projects"`
	ScanRoots   []string        `json:"scan_roots"`
	DevInsecure bool            `json:"dev_insecure"`
}

type AuthConfig struct {
	Token string `json:"token"`
}

type CodexConfig struct {
	Bin         string            `json:"bin"`
	DefaultArgs []string          `json:"default_args"`
	Env         map[string]string `json:"env"`
}

type SessionConfig struct {
	OutputBufferBytes int `json:"output_buffer_bytes"`
}

type ProjectConfig struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
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
	scanned, err := discoverProjects(cfg.ScanRoots)
	if err != nil {
		return Config{}, err
	}
	cfg.Projects = mergeProjects(cfg.Projects, scanned)
	return cfg, nil
}

func defaults() Config {
	return Config{
		Listen: "127.0.0.1:8787",
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
	if v := os.Getenv("AGENTD_CODEX_BIN"); v != "" {
		cfg.Codex.Bin = v
	}
	if v := os.Getenv("AGENTD_CODEX_ARGS"); v != "" {
		cfg.Codex.DefaultArgs = strings.Fields(v)
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
	if c.Codex.Bin == "" {
		return fmt.Errorf("codex.bin 不能为空")
	}
	if c.Session.OutputBufferBytes <= 0 {
		return fmt.Errorf("session.output_buffer_bytes 必须大于 0")
	}
	if len(c.Projects) == 0 {
		return fmt.Errorf("projects 不能为空；可在 config.json 配置，或设置 AGENTD_PROJECTS=/path/a,/path/b 或 AGENTD_SCAN_ROOTS=/workspace")
	}
	return nil
}
