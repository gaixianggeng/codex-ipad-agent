package projects

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
)

func TestRegistryLoadsValidProject(t *testing.T) {
	dir := t.TempDir()
	registry, err := NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}})
	if err != nil {
		t.Fatal(err)
	}
	project, ok := registry.Get("demo")
	if !ok {
		t.Fatal("期望能按 ID 查询项目")
	}
	if project.RealPath == "" || !filepath.IsAbs(project.Path) {
		t.Fatalf("路径未正确规范化：%+v", project)
	}
}

func TestRegistryRejectsInvalidID(t *testing.T) {
	_, err := NewRegistry([]config.ProjectConfig{{ID: "../bad", Name: "bad", Path: t.TempDir()}})
	if err == nil {
		t.Fatal("期望非法项目 ID 被拒绝")
	}
}

func TestFindByPathMatchesNestedProjectAndPrefersDeepest(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "app")
	nested := filepath.Join(child, "Sources")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := NewRegistry([]config.ProjectConfig{
		{ID: "workspace", Name: "Workspace", Path: root},
		{ID: "app", Name: "App", Path: child},
	})
	if err != nil {
		t.Fatal(err)
	}

	project, ok := registry.FindByPath(nested)
	if !ok {
		t.Fatal("期望子目录能匹配到项目")
	}
	if project.ID != "app" {
		t.Fatalf("期望优先匹配最深项目，实际 %+v", project)
	}
}
