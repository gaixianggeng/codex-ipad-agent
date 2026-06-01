package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

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

func TestSessionsRejectsUnknownProject(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/sessions", map[string]any{
		"project_id": "missing",
		"prompt":     "hello",
	}))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("期望未知项目返回 400，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["error"] == "" {
		t.Fatalf("期望返回错误信息：%v", body)
	}
}

func TestCreateSessionAndListSessions(t *testing.T) {
	server := newTestServer(t)
	createRec := httptest.NewRecorder()

	server.handler.ServeHTTP(createRec, authedRequest(t, http.MethodPost, "/api/sessions", map[string]any{
		"project_id": "demo",
		"prompt":     "帮我测试",
		"cols":       120,
		"rows":       32,
	}))

	if createRec.Code != http.StatusCreated {
		t.Fatalf("期望创建会话返回 201，实际 %d body=%s", createRec.Code, createRec.Body.String())
	}
	created := decodeJSON(t, createRec)
	sessionObj, ok := created["session"].(map[string]any)
	if !ok {
		t.Fatalf("创建会话响应缺少 session：%v", created)
	}
	sessionID, _ := sessionObj["id"].(string)
	if sessionID == "" || sessionObj["project_id"] != "demo" || sessionObj["status"] != "running" {
		t.Fatalf("创建会话字段异常：%v", sessionObj)
	}
	if created["ws_url"] != "/api/sessions/"+sessionID+"/ws" {
		t.Fatalf("ws_url 异常：%v", created)
	}

	listRec := httptest.NewRecorder()
	server.handler.ServeHTTP(listRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&cursor=next&limit=20", nil))
	if listRec.Code != http.StatusOK {
		t.Fatalf("期望会话列表返回 200，实际 %d body=%s", listRec.Code, listRec.Body.String())
	}
	listed := decodeJSON(t, listRec)
	sessions, ok := listed["sessions"].([]any)
	if !ok || len(sessions) == 0 {
		t.Fatalf("会话列表响应异常：%v", listed)
	}

	otherProjectRec := httptest.NewRecorder()
	server.handler.ServeHTTP(otherProjectRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=missing", nil))
	if otherProjectRec.Code != http.StatusOK {
		t.Fatalf("期望其他项目过滤返回 200，实际 %d body=%s", otherProjectRec.Code, otherProjectRec.Body.String())
	}
	otherProjectBody := decodeJSON(t, otherProjectRec)
	otherProjectSessions, ok := otherProjectBody["sessions"].([]any)
	if !ok || len(otherProjectSessions) != 0 {
		t.Fatalf("project_id 过滤应排除其他项目会话：%v", otherProjectBody)
	}
}

func TestSessionMessagesReturnsEmptyPageForLiveSession(t *testing.T) {
	server := newTestServer(t)
	createRec := httptest.NewRecorder()
	server.handler.ServeHTTP(createRec, authedRequest(t, http.MethodPost, "/api/sessions", map[string]any{
		"project_id": "demo",
	}))
	created := decodeJSON(t, createRec)
	sessionObj := created["session"].(map[string]any)
	sessionID := sessionObj["id"].(string)

	msgRec := httptest.NewRecorder()
	server.handler.ServeHTTP(msgRec, authedRequest(t, http.MethodGet, "/api/sessions/"+sessionID+"/messages?before=cursor&limit=50", nil))

	if msgRec.Code != http.StatusOK {
		t.Fatalf("期望消息接口返回 200，实际 %d body=%s", msgRec.Code, msgRec.Body.String())
	}
	body := decodeJSON(t, msgRec)
	messages, ok := body["messages"].([]any)
	if !ok || len(messages) != 0 {
		t.Fatalf("期望 live session 消息页为空：%v", body)
	}
}

func TestSessionMessagesDoesNot404ForMissingCodexHistory(t *testing.T) {
	server := newTestServer(t)
	msgRec := httptest.NewRecorder()

	server.handler.ServeHTTP(msgRec, authedRequest(t, http.MethodGet, "/api/sessions/codex_missing-thread/messages", nil))

	if msgRec.Code != http.StatusOK {
		t.Fatalf("缺失 Codex rollout 不应让详情页 404，实际 %d body=%s", msgRec.Code, msgRec.Body.String())
	}
	body := decodeJSON(t, msgRec)
	messages, ok := body["messages"].([]any)
	if !ok || len(messages) != 0 {
		t.Fatalf("期望缺失历史返回空消息页：%v", body)
	}
}
