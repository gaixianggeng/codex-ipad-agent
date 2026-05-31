package projects

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
)

var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

type Project struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Path     string `json:"path"`
	RealPath string `json:"-"`
}

type Registry struct {
	projects map[string]Project
	list     []Project
}

func NewRegistry(configs []config.ProjectConfig) (*Registry, error) {
	registry := &Registry{projects: map[string]Project{}}
	for _, item := range configs {
		project, err := normalize(item)
		if err != nil {
			return nil, err
		}
		if _, exists := registry.projects[project.ID]; exists {
			return nil, fmt.Errorf("项目 ID 重复：%s", project.ID)
		}
		registry.projects[project.ID] = project
		registry.list = append(registry.list, project)
	}
	sort.Slice(registry.list, func(i, j int) bool {
		return registry.list[i].Name < registry.list[j].Name
	})
	return registry, nil
}

func normalize(item config.ProjectConfig) (Project, error) {
	if item.ID == "" {
		return Project{}, fmt.Errorf("项目 ID 不能为空：%s", item.Path)
	}
	if !idPattern.MatchString(item.ID) {
		return Project{}, fmt.Errorf("项目 ID 只能包含字母、数字、下划线和短横线：%s", item.ID)
	}
	if item.Name == "" {
		item.Name = item.ID
	}
	abs, err := filepath.Abs(item.Path)
	if err != nil {
		return Project{}, fmt.Errorf("解析项目路径失败：%w", err)
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return Project{}, fmt.Errorf("项目路径不可访问 %s：%w", abs, err)
	}
	stat, err := os.Stat(realPath)
	if err != nil {
		return Project{}, fmt.Errorf("读取项目路径失败 %s：%w", realPath, err)
	}
	if !stat.IsDir() {
		return Project{}, fmt.Errorf("项目路径不是目录：%s", realPath)
	}
	return Project{ID: item.ID, Name: item.Name, Path: abs, RealPath: realPath}, nil
}

func (r *Registry) List() []Project {
	out := make([]Project, len(r.list))
	copy(out, r.list)
	return out
}

func (r *Registry) Get(id string) (Project, bool) {
	project, ok := r.projects[id]
	return project, ok
}

func (r *Registry) FindByPath(path string) (Project, bool) {
	realPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		realPath, _ = filepath.Abs(path)
	}
	realPath = filepath.Clean(realPath)

	// Codex 历史里的 cwd 经常是项目的子目录；这里选“最深的父级项目”，
	// 这样配置 scan root 和具体项目同时存在时，会优先归到具体项目。
	var (
		best      Project
		bestDepth = -1
	)
	for _, project := range r.list {
		projectPath := filepath.Clean(project.RealPath)
		rel, err := filepath.Rel(projectPath, realPath)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			continue
		}
		depth := len(strings.Split(projectPath, string(os.PathSeparator)))
		if depth > bestDepth {
			best = project
			bestDepth = depth
		}
	}
	if bestDepth >= 0 {
		return best, true
	}
	return Project{}, false
}
