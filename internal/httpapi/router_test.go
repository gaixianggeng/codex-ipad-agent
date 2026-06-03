package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
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

func TestPositiveSeqParsesOnlyPositiveIntegers(t *testing.T) {
	cases := map[string]int64{
		"":    0,
		"0":   0,
		"-1":  0,
		"bad": 0,
		"42":  42,
	}
	for raw, want := range cases {
		if got := positiveSeq(raw); got != want {
			t.Fatalf("positiveSeq(%q)=%d, want %d", raw, got, want)
		}
	}
}

func TestSameOriginOrNoOrigin(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://agentd.local/api/sessions/sess/ws", nil)
	req.Host = "agentd.local"
	if !sameOriginOrNoOrigin(req) {
		t.Fatal("没有 Origin 的原生客户端/WebSocket 请求应允许")
	}

	req = httptest.NewRequest(http.MethodGet, "http://agentd.local/api/sessions/sess/ws", nil)
	req.Host = "agentd.local"
	req.Header.Set("Origin", "http://agentd.local")
	if !sameOriginOrNoOrigin(req) {
		t.Fatal("同源浏览器 WebSocket 应允许")
	}

	req = httptest.NewRequest(http.MethodGet, "http://agentd.local/api/sessions/sess/ws", nil)
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

func TestSessionsRejectsMalformedCursor(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/sessions?cursor=not-base64!", nil))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("坏 cursor 应返回 400，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestSessionTraceEndpointReturnsRecentTraceEvents(t *testing.T) {
	server := newTestServer(t)
	dir := t.TempDir()
	s, err := server.manager.Create(session.CreateRequest{
		Project: projects.Project{ID: "demo", Name: "Demo", Path: dir, RealPath: dir},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Stop() })

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/sessions/"+s.ID+"/trace", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 trace 返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	trace, ok := body["trace"].([]any)
	if !ok || len(trace) == 0 {
		t.Fatalf("trace 响应应包含最近事件：%v", body)
	}
	first := trace[0].(map[string]any)
	if first["type"] != "session_created" {
		t.Fatalf("首个 trace 事件应记录 session_created：%v", trace)
	}
}

func TestSessionDetailAfterSeqOmitsAlreadySeenRecentOutput(t *testing.T) {
	server := newTestServer(t)
	dir := t.TempDir()
	s, err := server.manager.Create(session.CreateRequest{
		Project: projects.Project{ID: "demo", Name: "Demo", Path: dir, RealPath: dir},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Stop() })

	if err := s.Write("hello\n"); err != nil {
		t.Fatal(err)
	}
	lastSeq := waitForSessionSeq(t, s)

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/sessions/"+s.ID+"/?after_seq="+strconv.FormatInt(lastSeq, 10), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("期望 session detail 返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["recent_output"] != "" {
		t.Fatalf("after_seq 已到最新水位时不应重复返回 recent_output：%v", body)
	}
	if got := int64(body["last_seq"].(float64)); got != lastSeq {
		t.Fatalf("last_seq 应仍返回当前水位，got=%d want=%d", got, lastSeq)
	}
}

func waitForSessionSeq(t *testing.T, s *session.Session) int64 {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		snapshot := s.RecentOutputSnapshot()
		if snapshot.LastSeq > 0 {
			return snapshot.LastSeq
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("等待 session 输出超时")
	return 0
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
		"project_id":        "demo",
		"prompt":            "帮我测试",
		"cols":              120,
		"rows":              32,
		"client_message_id": "client-create-1",
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
	if created["client_message_id"] != "client-create-1" {
		t.Fatalf("创建响应应回传 client_message_id：%v", created)
	}
	firstMessage, ok := created["first_message"].(map[string]any)
	if !ok {
		t.Fatalf("带 client_message_id 的创建响应应返回 first_message：%v", created)
	}
	if firstMessage["id"] != "client:client-create-1" ||
		firstMessage["session_id"] != sessionID ||
		firstMessage["client_message_id"] != "client-create-1" ||
		firstMessage["role"] != "user" ||
		firstMessage["kind"] != "message" ||
		firstMessage["content"] != "帮我测试" ||
		firstMessage["send_status"] != "confirmed" {
		t.Fatalf("first_message 字段异常：%v", firstMessage)
	}
	if revision, _ := firstMessage["revision"].(float64); revision != 1 {
		t.Fatalf("first_message revision 应为 1：%v", firstMessage)
	}

	listRec := httptest.NewRecorder()
	server.handler.ServeHTTP(listRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=20", nil))
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
