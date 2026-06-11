package httpapi

import (
	"encoding/json"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// maxDirectoryListEntries 限制单次目录浏览响应的条目数，避免异常巨大的目录拖垮 iPad 端渲染。
const maxDirectoryListEntries = 1000

type directoryListRequest struct {
	Path string `json:"path"`
}

type directoryListResponse struct {
	Path       string           `json:"path"`
	ParentPath *string          `json:"parent_path"`
	Entries    []directoryEntry `json:"entries"`
	Truncated  bool             `json:"truncated,omitempty"`
}

type directoryEntry struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	IsDir     bool   `json:"is_dir"`
	CanOpen   bool   `json:"can_open"`
	CanBrowse bool   `json:"can_browse"`
}

// directoryListHandler 只服务于“选择工作区”的目录浏览：仅列目录、不递归、
// 复用 projects allowlist 作为边界，不开放成通用文件管理接口。
func (r *Router) directoryListHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload directoryListRequest
	decoder := json.NewDecoder(req.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体不是合法 JSON")
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		path = r.defaultBrowseRoot()
		if path == "" {
			writeError(w, http.StatusBadRequest, "path 不能为空（服务端未配置 browse_roots/scan_roots，无默认浏览根）")
			return
		}
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		// 与 workspace resolve 一致：不区分“不存在”和“不在 allowlist 内”，避免变成文件系统探测接口。
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	realPath := scope.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是目录")
		return
	}
	dirEntries, err := os.ReadDir(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}

	entries := make([]directoryEntry, 0, len(dirEntries))
	truncated := false
	for _, entry := range dirEntries {
		name := entry.Name()
		if skipBrowseDir(name) {
			continue
		}
		childPath := filepath.Join(realPath, name)
		switch {
		case entry.IsDir():
			// realPath 已经过 EvalSymlinks，真实子目录必然仍在允许根内。
		case entry.Type()&fs.ModeSymlink != 0:
			resolved, err := filepath.EvalSymlinks(childPath)
			if err != nil {
				continue
			}
			resolvedStat, err := os.Stat(resolved)
			if err != nil || !resolvedStat.IsDir() {
				continue
			}
			if !r.allowedRealPath(resolved) {
				// symlink 跳出允许根：不展示，避免目录浏览变成边界绕过入口。
				continue
			}
		default:
			continue
		}
		if len(entries) >= maxDirectoryListEntries {
			truncated = true
			break
		}
		entries = append(entries, directoryEntry{
			Name:      name,
			Path:      childPath,
			IsDir:     true,
			CanOpen:   true,
			CanBrowse: true,
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})

	writeJSON(w, http.StatusOK, directoryListResponse{
		Path:       realPath,
		ParentPath: r.browsableParent(realPath),
		Entries:    entries,
		Truncated:  truncated,
	})
}

// defaultBrowseRoot 让 iPad 端不带 path 也能进入浏览：优先第一个 browse root，
// 没配置时退回第一个 scan root。
func (r *Router) defaultBrowseRoot() string {
	for _, roots := range [][]string{r.cfg.BrowseRoots, r.cfg.ScanRoots} {
		for _, root := range roots {
			value := strings.TrimSpace(root)
			if value == "" {
				continue
			}
			abs, err := filepath.Abs(value)
			if err != nil {
				continue
			}
			return abs
		}
	}
	return ""
}

// allowedRealPath 判断已 canonical 化的路径是否在授权边界（projects ∪ browse_roots）内。
func (r *Router) allowedRealPath(realPath string) bool {
	if _, ok := r.projects.FindByPath(realPath); ok {
		return true
	}
	return r.realPathInBrowseRoots(realPath)
}

func (r *Router) browsableParent(realPath string) *string {
	parent := filepath.Dir(realPath)
	if parent == realPath {
		return nil
	}
	if !r.allowedRealPath(parent) {
		return nil
	}
	return &parent
}

// skipBrowseDir 与项目扫描的隐藏规则保持同一口径：隐藏目录、macOS Library 和常见缓存目录
// 不出现在浏览列表里；确有需要时仍可手输完整路径打开。
func skipBrowseDir(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch name {
	case "Library", "node_modules", "vendor", "dist", "build", "target", "tmp", "temp":
		return true
	default:
		return false
	}
}
