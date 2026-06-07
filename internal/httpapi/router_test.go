package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/doctor"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

const testToken = "0123456789abcdef0123456789abcdef"

type testServer struct {
	handler http.Handler
	manager *session.Manager
}

func newTestServer(t *testing.T) testServer {
	t.Helper()

	projectDir := t.TempDir()
	cfg := config.Config{
		Listen: "127.0.0.1:0",
		Auth:   config.AuthConfig{Token: testToken},
		Codex: config.CodexConfig{
			Bin: "/bin/cat",
			Env: map[string]string{"TERM": "xterm-256color"},
		},
		Session: config.SessionConfig{OutputBufferBytes: 8 * 1024},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: projectDir,
		}},
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	manager := session.NewManager(session.Options{
		CodexBin:     cfg.Codex.Bin,
		DefaultArgs:  cfg.Codex.DefaultArgs,
		Env:          cfg.Codex.Env,
		OutputBuffer: cfg.Session.OutputBufferBytes,
	})
	t.Cleanup(manager.Shutdown)

	checker := doctor.NewChecker("test", cfg, registry)
	return testServer{
		handler: NewRouter(cfg, registry, manager, checker, "test"),
		manager: manager,
	}
}

func TestSameOriginOrNoOrigin(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://agentd.local/api/app-server/ws", nil)
	req.Host = "agentd.local"
	if !sameOriginOrNoOrigin(req) {
		t.Fatal("没有 Origin 的原生客户端/WebSocket 请求应允许")
	}

	req = httptest.NewRequest(http.MethodGet, "http://agentd.local/api/app-server/ws", nil)
	req.Host = "agentd.local"
	req.Header.Set("Origin", "http://agentd.local")
	if !sameOriginOrNoOrigin(req) {
		t.Fatal("同源浏览器 WebSocket 应允许")
	}

	req = httptest.NewRequest(http.MethodGet, "http://agentd.local/api/app-server/ws", nil)
	req.Host = "agentd.local"
	req.Header.Set("Origin", "http://evil.local")
	if sameOriginOrNoOrigin(req) {
		t.Fatal("跨源 WebSocket 不应通过 Origin 校验")
	}
}

func TestActiveSessionSnapshotsFiltersByProjectBeforePagination(t *testing.T) {
	now := time.Unix(100, 0)
	list := []*session.Session{
		{ID: "sess_demo", ProjectID: "demo", Title: "demo", Status: "running", UpdatedAt: now},
		{ID: "sess_other", ProjectID: "other", Title: "other", Status: "running", UpdatedAt: now},
	}

	all := activeSessionSnapshots(list, "")
	if len(all) != 2 {
		t.Fatalf("全局列表应保留所有运行会话，got=%v", all)
	}

	demo := activeSessionSnapshots(list, "demo")
	if len(demo) != 1 || demo[0].ID != "sess_demo" {
		t.Fatalf("项目列表应在 snapshot 阶段排除无关运行会话，got=%v", demo)
	}

	missing := activeSessionSnapshots(list, "missing")
	if len(missing) != 0 {
		t.Fatalf("未知项目不应保留运行会话，got=%v", missing)
	}
}

func TestActiveSessionSnapshotWindowUsesCursorAndBoundedTopK(t *testing.T) {
	now := time.UnixMilli(1_780_308_003_000)
	list := []*session.Session{
		{ID: "sess_alpha", ProjectID: "demo", Title: "alpha", Status: "running", UpdatedAt: now},
		{ID: "sess_delta", ProjectID: "demo", Title: "delta", Status: "running", UpdatedAt: now},
		{ID: "sess_beta", ProjectID: "demo", Title: "beta", Status: "running", UpdatedAt: now},
		{ID: "sess_gamma", ProjectID: "demo", Title: "gamma", Status: "running", UpdatedAt: now},
		{ID: "sess_other", ProjectID: "other", Title: "other", Status: "running", UpdatedAt: now.Add(time.Second)},
	}

	firstWindow := activeSessionSnapshotWindow(list, "demo", sessionPageCursor{}, false, 2)
	if got := sessionSnapshotIDs(firstWindow); len(got) != 2 || got[0] != "sess_gamma" || got[1] != "sess_delta" {
		t.Fatalf("active window 应只保留按 updated_at/id 排序后的 top K，got=%v", got)
	}

	cursor := sessionPageCursor{ID: "sess_delta", UpdatedAtMS: now.UnixMilli()}
	secondWindow := activeSessionSnapshotWindow(list, "demo", cursor, true, 2)
	if got := sessionSnapshotIDs(secondWindow); len(got) != 2 || got[0] != "sess_beta" || got[1] != "sess_alpha" {
		t.Fatalf("active window 应在 cursor 后继续并保持稳定 id tie-breaker，got=%v", got)
	}
}

func TestDecodeSessionCursorRejectsMalformedNonEmptyCursor(t *testing.T) {
	if _, hasCursor, err := decodeSessionCursor(""); err != nil || hasCursor {
		t.Fatalf("空 cursor 应被视为未分页，has=%v err=%v", hasCursor, err)
	}

	invalidJSON := base64.RawURLEncoding.EncodeToString([]byte("{"))
	missingFields := base64.RawURLEncoding.EncodeToString([]byte(`{"id":"sess_1"}`))
	for _, raw := range []string{"not-base64!", invalidJSON, missingFields} {
		if _, hasCursor, err := decodeSessionCursor(raw); err == nil || hasCursor {
			t.Fatalf("非空无效 cursor 应返回错误且不启用分页，raw=%q has=%v err=%v", raw, hasCursor, err)
		}
	}
}

func authedRequest(t *testing.T, method, path string, body any) *http.Request {
	t.Helper()

	var reader *bytes.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(data)
	} else {
		reader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Authorization", "Bearer "+testToken)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req
}

func decodeJSON(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()

	var out map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&out); err != nil {
		t.Fatalf("响应不是合法 JSON：%v body=%q", err, rec.Body.String())
	}
	return out
}

func sessionSnapshotIDs(items []session.SessionSnapshot) []string {
	ids := make([]string, 0, len(items))
	for _, item := range items {
		ids = append(ids, item.ID)
	}
	return ids
}

func TestHealthzDoesNotRequireAuth(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 healthz 返回 200，实际 %d", rec.Code)
	}
	body := decodeJSON(t, rec)
	if body["ok"] != true || body["version"] != "test" {
		t.Fatalf("healthz 响应异常：%v", body)
	}
}

func TestProjectsRejectsMissingBearerToken(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/projects", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("期望未携带 token 被拒绝，实际 %d", rec.Code)
	}
}

func TestProjectsReturnsConfiguredProjects(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/projects", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("期望项目列表返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	items, ok := body["projects"].([]any)
	if !ok || len(items) != 1 {
		t.Fatalf("项目列表响应异常：%v", body)
	}
	project := items[0].(map[string]any)
	if project["id"] != "demo" || project["name"] != "Demo" {
		t.Fatalf("项目字段异常：%v", project)
	}
	if !filepath.IsAbs(project["path"].(string)) {
		t.Fatalf("项目路径应为绝对路径：%v", project)
	}
}

func TestWorkspaceResolveReturnsCanonicalChildWorkspace(t *testing.T) {
	server := newTestServer(t)

	projectDir := configuredProjectPath(t, server.handler)
	childDir := filepath.Join(projectDir, "ios")
	if err := os.Mkdir(childDir, 0o755); err != nil {
		t.Fatal(err)
	}
	realChildDir, err := filepath.EvalSymlinks(childDir)
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": childDir,
	}))

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 workspace resolve 返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	workspace, ok := body["workspace"].(map[string]any)
	if !ok {
		t.Fatalf("workspace 响应异常：%v", body)
	}
	if workspace["id"] == "" || !strings.HasPrefix(workspace["id"].(string), "ws_") {
		t.Fatalf("workspace id 应由服务端生成稳定 hash：%v", workspace)
	}
	if workspace["name"] != "ios" || workspace["path"] != realChildDir {
		t.Fatalf("workspace 基础字段异常：%v", workspace)
	}
	if workspace["root_project_id"] != "demo" || workspace["trusted"] != true || workspace["can_start_session"] != true {
		t.Fatalf("workspace 应继承 allowlist 根项目能力：%v", workspace)
	}
}

func TestWorkspaceResolveRejectsOutsidePathWithoutLeakingDetails(t *testing.T) {
	server := newTestServer(t)
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.Mkdir(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": outside,
	}))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("allowlist 外路径应被拒绝，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), outside) {
		t.Fatalf("拒绝响应不应泄漏外部路径：%s", rec.Body.String())
	}
}

func TestWorkspaceResolveRejectsFileInsideAllowlist(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	filePath := filepath.Join(projectDir, "README.md")
	if err := os.WriteFile(filePath, []byte("demo"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": filePath,
	}))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("allowlist 内文件不能作为 workspace，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}

func configuredProjectPath(t *testing.T, handler http.Handler) string {
	t.Helper()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/projects", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("读取项目列表失败：%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	items, ok := body["projects"].([]any)
	if !ok || len(items) == 0 {
		t.Fatalf("项目列表响应异常：%v", body)
	}
	project := items[0].(map[string]any)
	path, ok := project["path"].(string)
	if !ok || path == "" {
		t.Fatalf("项目 path 异常：%v", project)
	}
	return path
}

func TestLegacySessionsEndpointsAreRemoved(t *testing.T) {
	server := newTestServer(t)
	for _, path := range []string{
		"/api/sessions",
		"/api/sessions/codex_thread-demo",
		"/api/sessions/codex_thread-demo/messages",
		"/api/sessions/codex_thread-demo/trace",
		"/api/sessions/codex_thread-demo/ws",
	} {
		rec := httptest.NewRecorder()
		server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, path, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("%s 应已下线并返回 404，实际 %d body=%s", path, rec.Code, rec.Body.String())
		}
	}
}

func TestWebPWAStaticRootIsRemoved(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("Web/PWA 根页面应已下线并返回 404，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}
