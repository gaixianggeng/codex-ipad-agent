package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/codexhistory"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/doctor"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

func TestSessionsAPIUsesInjectedRuntimeForListAndCreate(t *testing.T) {
	cfg, registry, manager, checker, projectDir := runtimeRouterFixture(t)
	fake := &fakeSessionRuntime{
		listPage: SessionListPage{
			Sessions: []session.SessionSnapshot{{
				ID:        "codex_thread-list",
				ProjectID: "demo",
				Project:   "Demo",
				Dir:       projectDir,
				Title:     "listed",
				Status:    "history",
				Source:    "codex",
				UpdatedAt: time.Unix(100, 0),
			}},
		},
		createResult: RuntimeCreateResult{
			Snapshot: session.SessionSnapshot{
				ID:        "codex_thread-create",
				ProjectID: "demo",
				Project:   "Demo",
				Dir:       projectDir,
				Title:     "created",
				Status:    "running",
				Source:    "codex",
				CreatedAt: time.Unix(101, 0),
				UpdatedAt: time.Unix(101, 0),
			},
		},
	}
	handler := NewRouterWithRuntime(cfg, registry, manager, checker, "test", fake)

	listRec := httptest.NewRecorder()
	handler.ServeHTTP(listRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=20", nil))
	if listRec.Code != http.StatusOK {
		t.Fatalf("list 应返回 200，实际 %d body=%s", listRec.Code, listRec.Body.String())
	}
	if !fake.listCalled || fake.listProjectID != "demo" || fake.listLimit != 20 {
		t.Fatalf("list 未正确委托 runtime：%+v", fake)
	}

	createRec := httptest.NewRecorder()
	handler.ServeHTTP(createRec, authedRequest(t, http.MethodPost, "/api/sessions", map[string]any{
		"project_id":        "demo",
		"prompt":            "hello",
		"resume_id":         "thread-old",
		"title":             "custom",
		"cols":              120,
		"rows":              32,
		"client_message_id": "client-1",
	}))
	if createRec.Code != http.StatusCreated {
		t.Fatalf("create 应返回 201，实际 %d body=%s", createRec.Code, createRec.Body.String())
	}
	if !fake.createCalled {
		t.Fatal("create 未委托 runtime")
	}
	if fake.createRequest.Project.ID != "demo" || fake.createRequest.Project.RealPath != projectDir {
		t.Fatalf("router 必须把 project_id 映射为 allowlist 项目：%+v", fake.createRequest.Project)
	}
	if fake.createRequest.Prompt != "hello" || fake.createRequest.ResumeID != "thread-old" || fake.createRequest.ClientMessageID != "client-1" {
		t.Fatalf("create request 字段丢失：%+v", fake.createRequest)
	}
	body := decodeJSON(t, createRec)
	if body["client_message_id"] != "client-1" {
		t.Fatalf("create 响应应保留 client_message_id：%v", body)
	}
	firstMessage, ok := body["first_message"].(map[string]any)
	if !ok || firstMessage["send_status"] != "confirmed" {
		t.Fatalf("create 响应应包含本地回显确认：%v", body)
	}
}

func TestSessionResourceUsesInjectedRuntime(t *testing.T) {
	cfg, registry, manager, checker, _ := runtimeRouterFixture(t)
	fake := &fakeSessionRuntime{
		detail: SessionDetail{
			Snapshot: session.SessionSnapshot{
				ID:        "codex_thread-detail",
				ProjectID: "demo",
				Title:     "detail",
				Status:    "running",
				Source:    "codex",
			},
			RecentOutput: "tail",
			LastSeq:      7,
		},
		messages: codexhistory.MessagePage{Messages: []codexhistory.Message{}},
		trace:    []session.TraceEvent{{Time: time.Unix(1, 0), Type: "runtime_trace"}},
	}
	handler := NewRouterWithRuntime(cfg, registry, manager, checker, "test", fake)

	detailRec := httptest.NewRecorder()
	handler.ServeHTTP(detailRec, authedRequest(t, http.MethodGet, "/api/sessions/codex_thread-detail?after_seq=5", nil))
	if detailRec.Code != http.StatusOK || !fake.detailCalled || fake.detailAfterSeq != 5 {
		t.Fatalf("detail 未正确委托 runtime：code=%d fake=%+v body=%s", detailRec.Code, fake, detailRec.Body.String())
	}

	messagesRec := httptest.NewRecorder()
	handler.ServeHTTP(messagesRec, authedRequest(t, http.MethodGet, "/api/sessions/codex_thread-detail/messages?limit=50&before=cursor", nil))
	if messagesRec.Code != http.StatusOK || !fake.messagesCalled || fake.messagesBefore != "cursor" || fake.messagesLimit != 50 {
		t.Fatalf("messages 未正确委托 runtime：code=%d fake=%+v body=%s", messagesRec.Code, fake, messagesRec.Body.String())
	}
	body := decodeJSON(t, messagesRec)
	if messages, ok := body["messages"].([]any); !ok || len(messages) != 0 {
		t.Fatalf("空消息页必须保持 JSON []，不能变成 null：%v", body)
	}

	traceRec := httptest.NewRecorder()
	handler.ServeHTTP(traceRec, authedRequest(t, http.MethodGet, "/api/sessions/codex_thread-detail/trace", nil))
	if traceRec.Code != http.StatusOK || !fake.traceCalled {
		t.Fatalf("trace 未正确委托 runtime：code=%d fake=%+v body=%s", traceRec.Code, fake, traceRec.Body.String())
	}

	deleteRec := httptest.NewRecorder()
	handler.ServeHTTP(deleteRec, authedRequest(t, http.MethodDelete, "/api/sessions/codex_thread-detail", nil))
	if deleteRec.Code != http.StatusOK || !fake.stopCalled || fake.stopID != "codex_thread-detail" {
		t.Fatalf("delete 未正确委托 runtime：code=%d fake=%+v body=%s", deleteRec.Code, fake, deleteRec.Body.String())
	}
}

func runtimeRouterFixture(t *testing.T) (config.Config, *projects.Registry, *session.Manager, *doctor.Checker, string) {
	t.Helper()
	projectDir := t.TempDir()
	cfg := config.Config{
		Listen: "127.0.0.1:0",
		Auth:   config.AuthConfig{Token: testToken},
		Codex:  config.CodexConfig{Bin: "/bin/cat", Env: map[string]string{"TERM": "xterm-256color"}},
		Session: config.SessionConfig{
			OutputBufferBytes: 8 * 1024,
		},
		Projects: []config.ProjectConfig{{ID: "demo", Name: "Demo", Path: projectDir}},
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	project, ok := registry.Get("demo")
	if !ok {
		t.Fatal("测试项目不存在")
	}
	manager := session.NewManager(session.Options{CodexBin: cfg.Codex.Bin, Env: cfg.Codex.Env, OutputBuffer: cfg.Session.OutputBufferBytes})
	t.Cleanup(manager.Shutdown)
	checker := doctor.NewChecker("test", cfg, registry)
	return cfg, registry, manager, checker, project.RealPath
}

type fakeSessionRuntime struct {
	listCalled    bool
	listProjectID string
	listLimit     int
	listPage      SessionListPage

	createCalled  bool
	createRequest RuntimeCreateRequest
	createResult  RuntimeCreateResult

	detailCalled   bool
	detailAfterSeq int64
	detail         SessionDetail

	stopCalled bool
	stopID     string

	messagesCalled bool
	messagesBefore string
	messagesLimit  int
	messages       codexhistory.MessagePage

	traceCalled bool
	trace       []session.TraceEvent
}

func (f *fakeSessionRuntime) ListSessions(ctx context.Context, projectID string, limit int, cursor sessionPageCursor, hasCursor bool) (SessionListPage, error) {
	f.listCalled = true
	f.listProjectID = projectID
	f.listLimit = limit
	return f.listPage, nil
}

func (f *fakeSessionRuntime) CreateSession(ctx context.Context, req RuntimeCreateRequest) (RuntimeCreateResult, error) {
	f.createCalled = true
	f.createRequest = req
	return f.createResult, nil
}

func (f *fakeSessionRuntime) SessionDetail(ctx context.Context, id string, afterSeq int64) (SessionDetail, error) {
	f.detailCalled = true
	f.detailAfterSeq = afterSeq
	return f.detail, nil
}

func (f *fakeSessionRuntime) StopSession(ctx context.Context, id string) error {
	f.stopCalled = true
	f.stopID = id
	return nil
}

func (f *fakeSessionRuntime) SessionMessages(ctx context.Context, id string, before string, limit int) (codexhistory.MessagePage, error) {
	f.messagesCalled = true
	f.messagesBefore = before
	f.messagesLimit = limit
	if f.messages.Messages == nil {
		f.messages.Messages = []codexhistory.Message{}
	}
	return f.messages, nil
}

func (f *fakeSessionRuntime) SessionTrace(ctx context.Context, id string) ([]session.TraceEvent, error) {
	f.traceCalled = true
	return f.trace, nil
}

func TestRuntimeRouterFixtureUsesAbsoluteProjectPath(t *testing.T) {
	_, _, _, _, projectDir := runtimeRouterFixture(t)
	if !strings.HasPrefix(projectDir, "/") {
		t.Fatalf("测试项目路径应为绝对路径：%s", projectDir)
	}
}
