package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/doctor"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

func TestCodexHistoryMessagesEndpointReturnsRolloutMessages(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	rolloutPath := filepath.Join(home, ".codex", "sessions", "rollout.jsonl")
	writeFile(t, rolloutPath, strings.Join([]string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"hello from history"}}`,
		"",
	}, "\n"))
	writeCodexState(t, home, "thread-history-1", projectDir, rolloutPath)

	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
	t.Cleanup(manager.Shutdown)

	// 先走会话列表拿到 codex_ 前缀的历史会话 ID，再请求 messages，覆盖真实 iOS 调用顺序。
	listRec := httptest.NewRecorder()
	handler.ServeHTTP(listRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=300", nil))
	if listRec.Code != http.StatusOK {
		t.Fatalf("期望历史会话列表返回 200，实际 %d body=%s", listRec.Code, listRec.Body.String())
	}
	listBody := decodeJSON(t, listRec)
	items, ok := listBody["sessions"].([]any)
	if !ok || len(items) != 1 {
		t.Fatalf("期望发现 1 个 Codex 历史会话：%v", listBody)
	}
	historyID, _ := items[0].(map[string]any)["id"].(string)
	if historyID != "codex_thread-history-1" {
		t.Fatalf("历史会话 ID 异常：%q", historyID)
	}

	msgRec := httptest.NewRecorder()
	handler.ServeHTTP(msgRec, authedRequest(t, http.MethodGet, "/api/sessions/"+historyID+"/messages?limit=50", nil))
	if msgRec.Code != http.StatusOK {
		t.Fatalf("期望历史 messages 返回 200，实际 %d body=%s", msgRec.Code, msgRec.Body.String())
	}
	msgBody := decodeJSON(t, msgRec)
	messages, ok := msgBody["messages"].([]any)
	if !ok || len(messages) != 2 {
		t.Fatalf("期望解析 2 条历史消息：%v", msgBody)
	}
	if messages[0].(map[string]any)["role"] != "user" || messages[0].(map[string]any)["content"] != "hi" {
		t.Fatalf("第一条历史消息异常：%v", messages[0])
	}
	if messages[1].(map[string]any)["role"] != "assistant" || messages[1].(map[string]any)["content"] != "hello from history" {
		t.Fatalf("第二条历史消息异常：%v", messages[1])
	}
}

func TestCodexHistoryMessagesEndpointHonorsLimit(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	rolloutPath := filepath.Join(home, ".codex", "sessions", "rollout-limited.jsonl")
	writeFile(t, rolloutPath, strings.Join([]string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}`,
		`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"three"}}`,
		"",
	}, "\n"))
	writeCodexState(t, home, "thread-history-limit", projectDir, rolloutPath)

	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
	t.Cleanup(manager.Shutdown)

	msgRec := httptest.NewRecorder()
	handler.ServeHTTP(msgRec, authedRequest(t, http.MethodGet, "/api/sessions/codex_thread-history-limit/messages?limit=2", nil))
	if msgRec.Code != http.StatusOK {
		t.Fatalf("期望历史 messages 返回 200，实际 %d body=%s", msgRec.Code, msgRec.Body.String())
	}
	msgBody := decodeJSON(t, msgRec)
	messages, ok := msgBody["messages"].([]any)
	if !ok || len(messages) != 2 {
		t.Fatalf("期望按 limit 返回 2 条历史消息：%v", msgBody)
	}
	if messages[0].(map[string]any)["content"] != "two" || messages[1].(map[string]any)["content"] != "three" {
		t.Fatalf("limit 应返回最近消息窗口：%v", messages)
	}
}

func TestProjectScopedSessionsFindHistoryBeyondGlobalLimit(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	otherDir := filepath.Join(t.TempDir(), "other")
	t.Setenv("HOME", home)

	fixtures := make([]codexThreadFixture, 0, 302)
	for i := 0; i < 301; i++ {
		fixtures = append(fixtures, codexThreadFixture{
			ID:        fmt.Sprintf("other-%03d", i),
			Title:     "Other Project",
			CWD:       otherDir,
			UpdatedAt: 1780309000000 + int64(i),
		})
	}
	fixtures = append(fixtures, codexThreadFixture{
		ID:        "target-old-thread",
		Title:     "Target Old Thread",
		CWD:       projectDir,
		UpdatedAt: 1780308000000,
	})
	writeCodexStateRows(t, home, fixtures)

	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
	t.Cleanup(manager.Shutdown)

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=300", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("期望项目会话列表返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	items, ok := body["sessions"].([]any)
	if !ok || len(items) != 1 {
		t.Fatalf("目标项目旧历史不应被全局最近 300 条截断：%v", body)
	}
	if got := items[0].(map[string]any)["id"]; got != "codex_target-old-thread" {
		t.Fatalf("期望查到目标项目旧会话，实际 %v", got)
	}
}

func TestProjectSessionsExcludeSubagentsAndNonInteractiveSources(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	writeModernCodexStateRows(t, home, []codexThreadFixture{
		{ID: "main-thread", Title: "Main Thread", CWD: projectDir, Source: "vscode", ThreadSource: "user", UpdatedAt: 1780308004000},
		{ID: "child-edge", Title: "Child Edge", CWD: projectDir, Source: "vscode", ThreadSource: "user", UpdatedAt: 1780308003000},
		{ID: "child-json", Title: "Child JSON", CWD: projectDir, Source: `{"subagent":{"thread_spawn":{"parent_thread_id":"main-thread"}}}`, ThreadSource: "subagent", UpdatedAt: 1780308002000},
		{ID: "exec-thread", Title: "Exec Thread", CWD: projectDir, Source: "exec", ThreadSource: "user", UpdatedAt: 1780308001000},
	}, map[string]string{"child-edge": "main-thread"})

	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
	t.Cleanup(manager.Shutdown)

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=300", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("期望项目会话列表返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	items, ok := body["sessions"].([]any)
	if !ok || len(items) != 1 {
		t.Fatalf("侧栏应只展示顶层交互会话：%v", body)
	}
	if got := items[0].(map[string]any)["id"]; got != "codex_main-thread" {
		t.Fatalf("期望只保留 main-thread，实际 %v", got)
	}

	debugRec := httptest.NewRecorder()
	handler.ServeHTTP(debugRec, authedRequest(t, http.MethodGet, "/api/debug/codex-history?project_id=demo&limit=20", nil))
	if debugRec.Code != http.StatusOK {
		t.Fatalf("期望历史诊断接口返回 200，实际 %d body=%s", debugRec.Code, debugRec.Body.String())
	}
	debugBody := decodeJSON(t, debugRec)
	counts := debugBody["counts"].(map[string]any)
	if counts["included"] != float64(1) || counts["subagent"] != float64(2) || counts["unsupported_source"] != float64(1) {
		t.Fatalf("诊断应区分顶层会话、子 Agent 和非交互来源：%v", debugBody)
	}
}

func TestCodexHistoryDebugEndpointExplainsProjectRows(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)
	writeCodexStateRows(t, home, []codexThreadFixture{{
		ID:        "debug-thread",
		Title:     "Debug Thread",
		CWD:       projectDir,
		UpdatedAt: 1780308000000,
	}})

	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
	t.Cleanup(manager.Shutdown)

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/debug/codex-history?project_id=demo&limit=20", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("期望历史诊断接口返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["database_exists"] != true || body["query_mode"] != "project_path" {
		t.Fatalf("诊断基础字段异常：%v", body)
	}
	counts := body["counts"].(map[string]any)
	included, ok := counts["included"].(float64)
	if !ok || included != 1 {
		t.Fatalf("诊断应说明纳入了 1 条历史：%v", body)
	}
	rows := body["rows"].([]any)
	if rows[0].(map[string]any)["reason"] != "included" {
		t.Fatalf("诊断行应标记 included：%v", rows[0])
	}
}

func TestWebSocketInputReturnsOutputForHi(t *testing.T) {
	fakeCodex := writeFakeCodex(t)
	projectDir := t.TempDir()
	handler, manager := newAcceptanceRouter(t, projectDir, fakeCodex)
	t.Cleanup(manager.Shutdown)

	server := httptest.NewServer(handler)
	defer server.Close()

	createReq := authedHTTPClientRequest(t, http.MethodPost, server.URL+"/api/sessions", map[string]any{
		"project_id": "demo",
		"cols":       120,
		"rows":       32,
	})
	createResp, err := http.DefaultClient.Do(createReq)
	if err != nil {
		t.Fatal(err)
	}
	defer createResp.Body.Close()
	if createResp.StatusCode != http.StatusCreated {
		t.Fatalf("期望创建会话返回 201，实际 %d", createResp.StatusCode)
	}
	var created struct {
		Session session.Session `json:"session"`
		WSURL   string          `json:"ws_url"`
	}
	if err := json.NewDecoder(createResp.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + created.WSURL
	header := http.Header{}
	header.Set("Authorization", "Bearer "+testToken)
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// 发送 hi 后必须能从同一条 WebSocket 收到 Codex 子进程输出，否则 iOS 侧不会出现助手消息。
	if err := conn.WriteJSON(map[string]any{"type": "input", "data": "hi\r", "client_message_id": "client-hi"}); err != nil {
		t.Fatal(err)
	}
	// gorilla/websocket 读超时后连接状态不可继续复用，所以这里只设置一个整体读窗口。
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("发送 hi 后未在 WebSocket output 中收到 fake Codex 回复：%v", err)
		}
		data, _ := event["data"].(string)
		if event["type"] == "output" && strings.Contains(data, "hello from fake codex") {
			return
		}
	}
}

func TestWebSocketAllowsSecondClientForSameSession(t *testing.T) {
	fakeCodex := writeFakeCodex(t)
	projectDir := t.TempDir()
	handler, manager := newAcceptanceRouter(t, projectDir, fakeCodex)
	t.Cleanup(manager.Shutdown)

	server := httptest.NewServer(handler)
	defer server.Close()

	createReq := authedHTTPClientRequest(t, http.MethodPost, server.URL+"/api/sessions", map[string]any{
		"project_id": "demo",
		"cols":       120,
		"rows":       32,
	})
	createResp, err := http.DefaultClient.Do(createReq)
	if err != nil {
		t.Fatal(err)
	}
	defer createResp.Body.Close()
	if createResp.StatusCode != http.StatusCreated {
		t.Fatalf("期望创建会话返回 201，实际 %d", createResp.StatusCode)
	}
	var created struct {
		WSURL string `json:"ws_url"`
	}
	if err := json.NewDecoder(createResp.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + created.WSURL
	header := http.Header{}
	header.Set("Authorization", "Bearer "+testToken)
	first, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, resp, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		if resp != nil {
			t.Fatalf("第二个 WebSocket 不应被 409 拒绝，status=%d err=%v", resp.StatusCode, err)
		}
		t.Fatal(err)
	}
	defer second.Close()

	if err := second.WriteJSON(map[string]any{"type": "input", "data": "hi\r"}); err != nil {
		t.Fatal(err)
	}
	readOutputContains(t, first, "hello from fake codex")
	readOutputContains(t, second, "hello from fake codex")
}

func readOutputContains(t *testing.T, conn *websocket.Conn, want string) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("未收到包含 %q 的 output：%v", want, err)
		}
		data, _ := event["data"].(string)
		if event["type"] == "output" && strings.Contains(data, want) {
			return
		}
	}
}

func newAcceptanceRouter(t *testing.T, projectDir, codexBin string) (http.Handler, *session.Manager) {
	t.Helper()

	cfg := config.Config{
		Listen: "127.0.0.1:0",
		Auth:   config.AuthConfig{Token: testToken},
		Codex: config.CodexConfig{
			Bin: codexBin,
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
	checker := doctor.NewChecker("test", cfg, registry)
	return NewRouter(cfg, registry, manager, checker, "test"), manager
}

type codexThreadFixture struct {
	ID           string
	Title        string
	CWD          string
	RolloutPath  string
	Source       string
	ThreadSource string
	Preview      string
	UpdatedAt    int64
}

func writeCodexState(t *testing.T, home, threadID, cwd, rolloutPath string) {
	t.Helper()
	writeCodexStateRows(t, home, []codexThreadFixture{{
		ID:          threadID,
		Title:       "History Title",
		CWD:         cwd,
		RolloutPath: rolloutPath,
		UpdatedAt:   1780308001000,
	}})
}

func writeCodexStateRows(t *testing.T, home string, rows []codexThreadFixture) {
	t.Helper()
	db := filepath.Join(home, ".codex", "state_5.sqlite")
	if err := os.MkdirAll(filepath.Dir(db), 0o755); err != nil {
		t.Fatal(err)
	}
	sql := `
create table threads (
	id text primary key,
	title text,
	cwd text,
	rollout_path text,
	created_at_ms integer,
	updated_at_ms integer,
	archived integer
);
`
	var builder strings.Builder
	builder.WriteString(sql)
	for _, row := range rows {
		title := row.Title
		if title == "" {
			title = row.ID
		}
		updatedAt := row.UpdatedAt
		if updatedAt == 0 {
			updatedAt = 1780308001000
		}
		builder.WriteString("insert into threads (id, title, cwd, rollout_path, created_at_ms, updated_at_ms, archived) values (")
		builder.WriteString(quoteSQL(row.ID))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(title))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(row.CWD))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(row.RolloutPath))
		builder.WriteString(", ")
		builder.WriteString(fmt.Sprintf("%d, %d, 0", updatedAt-1000, updatedAt))
		builder.WriteString(");\n")
	}
	cmd := exec.Command("sqlite3", db, builder.String())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("创建 Codex state fixture 失败：%v output=%s", err, out)
	}
}

func writeModernCodexStateRows(t *testing.T, home string, rows []codexThreadFixture, childToParent map[string]string) {
	t.Helper()
	db := filepath.Join(home, ".codex", "state_5.sqlite")
	if err := os.MkdirAll(filepath.Dir(db), 0o755); err != nil {
		t.Fatal(err)
	}
	var builder strings.Builder
	builder.WriteString(`
create table threads (
	id text primary key,
	title text,
	cwd text,
	rollout_path text,
	source text,
	thread_source text,
	preview text,
	created_at_ms integer,
	updated_at_ms integer,
	archived integer
);
create table thread_spawn_edges (
	parent_thread_id text not null,
	child_thread_id text not null,
	status text,
	primary key (parent_thread_id, child_thread_id)
);
`)
	for _, row := range rows {
		title := row.Title
		if title == "" {
			title = row.ID
		}
		source := row.Source
		if source == "" {
			source = "vscode"
		}
		preview := row.Preview
		if preview == "" {
			preview = title
		}
		updatedAt := row.UpdatedAt
		if updatedAt == 0 {
			updatedAt = 1780308001000
		}
		builder.WriteString("insert into threads (id, title, cwd, rollout_path, source, thread_source, preview, created_at_ms, updated_at_ms, archived) values (")
		builder.WriteString(quoteSQL(row.ID))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(title))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(row.CWD))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(row.RolloutPath))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(source))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(row.ThreadSource))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(preview))
		builder.WriteString(", ")
		builder.WriteString(fmt.Sprintf("%d, %d, 0", updatedAt-1000, updatedAt))
		builder.WriteString(");\n")
	}
	for child, parent := range childToParent {
		builder.WriteString("insert into thread_spawn_edges (parent_thread_id, child_thread_id, status) values (")
		builder.WriteString(quoteSQL(parent))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(child))
		builder.WriteString(", 'running');\n")
	}
	cmd := exec.Command("sqlite3", db, builder.String())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("创建现代 Codex state fixture 失败：%v output=%s", err, out)
	}
}

func writeFakeCodex(t *testing.T) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "codex-fake")
	writeFile(t, path, `#!/bin/sh
printf 'fake codex ready\n'
while IFS= read -r line; do
  case "$line" in
    hi*) printf 'hello from fake codex\n'; exit 0 ;;
  esac
done
`)
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func requireSQLite(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 不可用，跳过 Codex history fixture 测试")
	}
}

func quoteSQL(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func authedHTTPClientRequest(t *testing.T, method, url string, body any) *http.Request {
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
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req
}
