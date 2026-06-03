package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
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
		`{"timestamp":"2026-06-01T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"four"}}`,
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
	if messages[0].(map[string]any)["content"] != "three" || messages[1].(map[string]any)["content"] != "four" {
		t.Fatalf("limit 应返回最近消息窗口：%v", messages)
	}
	if msgBody["has_more_before"] != true {
		t.Fatalf("第一页应标记还有更早消息：%v", msgBody)
	}
	cursor, ok := msgBody["previous_cursor"].(string)
	if !ok || cursor == "" {
		t.Fatalf("第一页应返回 previous_cursor：%v", msgBody)
	}

	olderRec := httptest.NewRecorder()
	handler.ServeHTTP(olderRec, authedRequest(t, http.MethodGet, "/api/sessions/codex_thread-history-limit/messages?limit=2&before="+cursor, nil))
	if olderRec.Code != http.StatusOK {
		t.Fatalf("期望更早 messages 返回 200，实际 %d body=%s", olderRec.Code, olderRec.Body.String())
	}
	olderBody := decodeJSON(t, olderRec)
	olderMessages, ok := olderBody["messages"].([]any)
	if !ok || len(olderMessages) != 2 {
		t.Fatalf("期望按 cursor 返回更早 2 条历史消息：%v", olderBody)
	}
	if olderMessages[0].(map[string]any)["content"] != "one" || olderMessages[1].(map[string]any)["content"] != "two" {
		t.Fatalf("cursor 应返回更早消息窗口：%v", olderMessages)
	}
	if olderBody["has_more_before"] != false {
		t.Fatalf("第二页已到开头，不应标记更多：%v", olderBody)
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

func TestProjectSessionsReturnCursorPage(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	writeCodexStateRows(t, home, []codexThreadFixture{
		{ID: "thread-new", Title: "New Thread", CWD: projectDir, UpdatedAt: 1780308003000},
		{ID: "thread-mid", Title: "Mid Thread", CWD: projectDir, UpdatedAt: 1780308002000},
		{ID: "thread-old", Title: "Old Thread", CWD: projectDir, UpdatedAt: 1780308001000},
	})

	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
	t.Cleanup(manager.Shutdown)

	firstRec := httptest.NewRecorder()
	handler.ServeHTTP(firstRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=2", nil))
	if firstRec.Code != http.StatusOK {
		t.Fatalf("期望第一页返回 200，实际 %d body=%s", firstRec.Code, firstRec.Body.String())
	}
	firstBody := decodeJSON(t, firstRec)
	firstItems, ok := firstBody["sessions"].([]any)
	if !ok || len(firstItems) != 2 {
		t.Fatalf("第一页应返回 2 条会话：%v", firstBody)
	}
	if got := firstItems[0].(map[string]any)["id"]; got != "codex_thread-new" {
		t.Fatalf("第一页应按 updated_at 倒序返回 newest，实际 %v", got)
	}
	if got := firstItems[1].(map[string]any)["id"]; got != "codex_thread-mid" {
		t.Fatalf("第一页第二条异常：%v", got)
	}
	if firstBody["has_more"] != true {
		t.Fatalf("第一页应标记还有更多：%v", firstBody)
	}
	cursor, ok := firstBody["next_cursor"].(string)
	if !ok || cursor == "" {
		t.Fatalf("第一页应返回 next_cursor：%v", firstBody)
	}

	secondRec := httptest.NewRecorder()
	handler.ServeHTTP(secondRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=2&cursor="+cursor, nil))
	if secondRec.Code != http.StatusOK {
		t.Fatalf("期望第二页返回 200，实际 %d body=%s", secondRec.Code, secondRec.Body.String())
	}
	secondBody := decodeJSON(t, secondRec)
	secondItems, ok := secondBody["sessions"].([]any)
	if !ok || len(secondItems) != 1 {
		t.Fatalf("第二页应只返回剩余 1 条会话：%v", secondBody)
	}
	if got := secondItems[0].(map[string]any)["id"]; got != "codex_thread-old" {
		t.Fatalf("第二页应从 cursor 后继续，实际 %v", got)
	}
	if secondBody["has_more"] != false {
		t.Fatalf("第二页应标记没有更多：%v", secondBody)
	}
}

func TestProjectSessionsCursorPageUsesStableIDTieBreaker(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	writeCodexStateRows(t, home, []codexThreadFixture{
		{ID: "alpha", Title: "Alpha", CWD: projectDir, UpdatedAt: 1780308003000},
		{ID: "beta", Title: "Beta", CWD: projectDir, UpdatedAt: 1780308003000},
		{ID: "gamma", Title: "Gamma", CWD: projectDir, UpdatedAt: 1780308003000},
	})

	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
	t.Cleanup(manager.Shutdown)

	firstRec := httptest.NewRecorder()
	handler.ServeHTTP(firstRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=2", nil))
	if firstRec.Code != http.StatusOK {
		t.Fatalf("期望第一页返回 200，实际 %d body=%s", firstRec.Code, firstRec.Body.String())
	}
	firstBody := decodeJSON(t, firstRec)
	firstItems, ok := firstBody["sessions"].([]any)
	if !ok || len(firstItems) != 2 {
		t.Fatalf("第一页应返回 2 条会话：%v", firstBody)
	}
	if got := sessionIDs(firstItems); strings.Join(got, ",") != "codex_gamma,codex_beta" {
		t.Fatalf("相同 updated_at 应按 id desc 稳定排序，实际：%v", got)
	}
	cursor, ok := firstBody["next_cursor"].(string)
	if !ok || cursor == "" {
		t.Fatalf("第一页应返回 next_cursor：%v", firstBody)
	}

	secondRec := httptest.NewRecorder()
	handler.ServeHTTP(secondRec, authedRequest(t, http.MethodGet, "/api/sessions?project_id=demo&limit=2&cursor="+cursor, nil))
	if secondRec.Code != http.StatusOK {
		t.Fatalf("期望第二页返回 200，实际 %d body=%s", secondRec.Code, secondRec.Body.String())
	}
	secondBody := decodeJSON(t, secondRec)
	secondItems, ok := secondBody["sessions"].([]any)
	if !ok || len(secondItems) != 1 {
		t.Fatalf("第二页应只返回剩余 1 条会话：%v", secondBody)
	}
	if got := sessionIDs(secondItems); strings.Join(got, ",") != "codex_alpha" {
		t.Fatalf("cursor 后一页应继续返回 beta 之前的记录，实际：%v", got)
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
	scan := body["scan"].(map[string]any)
	if scan["requested_limit"] != float64(20) ||
		scan["row_scan_limit"] != float64(20) ||
		scan["rows_returned"] != float64(1) ||
		scan["project_filtered"] != true {
		t.Fatalf("诊断应暴露轻量扫描统计：%v", body)
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
		Session session.SessionSnapshot `json:"session"`
		WSURL   string                  `json:"ws_url"`
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
			if seq, _ := event["seq"].(float64); seq <= 0 {
				t.Fatalf("实时 output 应带正数 seq：%v", event)
			}
			break
		}
	}

	traceReq := authedHTTPClientRequest(t, http.MethodGet, server.URL+"/api/sessions/"+created.Session.ID+"/trace", nil)
	traceResp, err := http.DefaultClient.Do(traceReq)
	if err != nil {
		t.Fatal(err)
	}
	defer traceResp.Body.Close()
	if traceResp.StatusCode != http.StatusOK {
		t.Fatalf("期望 trace 返回 200，实际 %d", traceResp.StatusCode)
	}
	var traceBody struct {
		Trace []session.TraceEvent `json:"trace"`
	}
	if err := json.NewDecoder(traceResp.Body).Decode(&traceBody); err != nil {
		t.Fatal(err)
	}
	if !traceEventExists(traceBody.Trace, "ws_connected") || !traceEventExists(traceBody.Trace, "ws_input") {
		t.Fatalf("trace 应记录 WebSocket 连接和输入：%+v", traceBody.Trace)
	}
}

func TestWebSocketInputWithClientMessageIDReturnsUserConfirmation(t *testing.T) {
	projectDir := t.TempDir()
	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
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
		Session session.SessionSnapshot `json:"session"`
		WSURL   string                  `json:"ws_url"`
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

	if err := conn.WriteJSON(map[string]any{"type": "input", "data": "hello\r\n", "client_message_id": "client-ws-1"}); err != nil {
		t.Fatal(err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("未收到 message_completed 用户确认：%v", err)
		}
		if event["type"] != "message_completed" {
			continue
		}
		if event["session_id"] != created.Session.ID || event["client_message_id"] != "client-ws-1" {
			t.Fatalf("message_completed 顶层元数据异常：%v", event)
		}
		message, ok := event["message"].(map[string]any)
		if !ok {
			t.Fatalf("message_completed 缺少 message：%v", event)
		}
		if message["id"] != "client:client-ws-1" ||
			message["session_id"] != created.Session.ID ||
			message["client_message_id"] != "client-ws-1" ||
			message["role"] != "user" ||
			message["kind"] != "message" ||
			message["content"] != "hello" ||
			message["send_status"] != "confirmed" {
			t.Fatalf("用户确认消息字段异常：%v", message)
		}
		if revision, _ := message["revision"].(float64); revision != 1 {
			t.Fatalf("用户确认 revision 应为 1：%v", message)
		}
		if createdAt, _ := message["created_at"].(string); createdAt == "" {
			t.Fatalf("用户确认应带 created_at：%v", message)
		}
		break
	}
}

func TestWebSocketInputWithoutClientMessageIDOnlyWritesPTY(t *testing.T) {
	projectDir := t.TempDir()
	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
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
		Session session.SessionSnapshot `json:"session"`
		WSURL   string                  `json:"ws_url"`
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

	if err := conn.WriteJSON(map[string]any{"type": "input", "data": "legacy\r"}); err != nil {
		t.Fatal(err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	sawPTYOutput := false
	for {
		var event map[string]any
		err := conn.ReadJSON(&event)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				break
			}
			t.Fatalf("读取 WebSocket 事件失败：%v", err)
		}
		if event["type"] == "message_completed" {
			t.Fatalf("无 client_message_id 的旧协议输入不应生成用户确认：%v", event)
		}
		data, _ := event["data"].(string)
		if event["type"] == "output" && strings.Contains(data, "legacy") {
			sawPTYOutput = true
		}
	}
	if !sawPTYOutput {
		t.Fatal("无 client_message_id 的旧协议输入仍应写入 PTY")
	}

	trace := sessionTraceEvents(t, server.URL, created.Session.ID)
	if traceEventExists(trace, "rollout_assistant_poll_started") {
		t.Fatalf("无 client_message_id 的旧协议输入不应启动 rollout poller：%+v", trace)
	}
}

func TestWebSocketForwardsNewRolloutAssistantMessage(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	rolloutPath := filepath.Join(home, ".codex", "sessions", "rollout-live.jsonl")
	writeFile(t, rolloutPath, strings.Join([]string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"旧问题"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"旧回答"}}`,
		"",
	}, "\n"))
	writeCodexState(t, home, "thread-live", projectDir, rolloutPath)

	fakeCodex := writeFakeCodex(t)
	handler, manager := newAcceptanceRouter(t, projectDir, fakeCodex)
	t.Cleanup(manager.Shutdown)

	server := httptest.NewServer(handler)
	defer server.Close()

	createReq := authedHTTPClientRequest(t, http.MethodPost, server.URL+"/api/sessions", map[string]any{
		"project_id": "demo",
		"resume_id":  "thread-live",
		"cols":       120,
		"rows":       32,
	})
	createResp, err := http.DefaultClient.Do(createReq)
	if err != nil {
		t.Fatal(err)
	}
	defer createResp.Body.Close()
	if createResp.StatusCode != http.StatusCreated {
		t.Fatalf("期望创建 resume 会话返回 201，实际 %d", createResp.StatusCode)
	}
	var created struct {
		Session session.SessionSnapshot `json:"session"`
		WSURL   string                  `json:"ws_url"`
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

	if err := conn.WriteJSON(map[string]any{"type": "input", "data": "继续\r", "client_message_id": "client-live-1"}); err != nil {
		t.Fatal(err)
	}
	appendFile(t, rolloutPath, `{"timestamp":"`+time.Now().UTC().Add(2*time.Second).Format(time.RFC3339Nano)+`","type":"event_msg","payload":{"type":"agent_message","message":"新的结构化回答"}}`+"\n")

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("未收到 rollout assistant message_completed：%v trace=%+v", err, sessionTraceEvents(t, server.URL, created.Session.ID))
		}
		if event["type"] != "message_completed" {
			continue
		}
		message, ok := event["message"].(map[string]any)
		if !ok || message["role"] != "assistant" {
			continue
		}
		if message["session_id"] != created.Session.ID ||
			message["content"] != "新的结构化回答" ||
			message["send_status"] != "confirmed" {
			t.Fatalf("assistant message_completed 字段异常：%v", message)
		}
		if id, _ := message["id"].(string); !strings.HasPrefix(id, "rollout:") {
			t.Fatalf("assistant 应保留 rollout 稳定 id：%v", message)
		}
		break
	}
}

func TestWebSocketForwardsLateRolloutAssistantWithoutNewInput(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	rolloutPath := filepath.Join(home, ".codex", "sessions", "rollout-late.jsonl")
	writeFile(t, rolloutPath, `{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"旧回答"}}`+"\n")
	writeCodexState(t, home, "thread-late", projectDir, rolloutPath)

	fakeCodex := writeFakeCodex(t)
	handler, manager := newAcceptanceRouter(t, projectDir, fakeCodex)
	t.Cleanup(manager.Shutdown)

	server := httptest.NewServer(handler)
	defer server.Close()

	createReq := authedHTTPClientRequest(t, http.MethodPost, server.URL+"/api/sessions", map[string]any{
		"project_id": "demo",
		"resume_id":  "thread-late",
		"cols":       120,
		"rows":       32,
	})
	createResp, err := http.DefaultClient.Do(createReq)
	if err != nil {
		t.Fatal(err)
	}
	defer createResp.Body.Close()
	if createResp.StatusCode != http.StatusCreated {
		t.Fatalf("期望创建 resume 会话返回 201，实际 %d", createResp.StatusCode)
	}
	var created struct {
		Session session.SessionSnapshot `json:"session"`
		WSURL   string                  `json:"ws_url"`
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

	// 只发一次输入，随后“两段回复”分先后落盘，期间不再有任何 WS 输入。
	// 连接级 poller 必须持续存活，否则第一段之后就停摆——正是“长回复/最后一条收不到”的根因。
	if err := conn.WriteJSON(map[string]any{"type": "input", "data": "继续\r", "client_message_id": "client-late-1"}); err != nil {
		t.Fatal(err)
	}

	readAssistant := func(want string) {
		_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		for {
			var event map[string]any
			if err := conn.ReadJSON(&event); err != nil {
				t.Fatalf("未收到 assistant %q：%v trace=%+v", want, err, sessionTraceEvents(t, server.URL, created.Session.ID))
			}
			if event["type"] != "message_completed" {
				continue
			}
			message, ok := event["message"].(map[string]any)
			if !ok || message["role"] != "assistant" {
				continue
			}
			if message["content"] == want {
				return
			}
		}
	}

	appendFile(t, rolloutPath, `{"timestamp":"`+time.Now().UTC().Add(time.Second).Format(time.RFC3339Nano)+`","type":"event_msg","payload":{"type":"agent_message","message":"第一段回复"}}`+"\n")
	readAssistant("第一段回复")

	// 第二段在第一段被消费之后才落盘，且没有任何新输入触发——只能靠常驻 poller 兜住。
	appendFile(t, rolloutPath, `{"timestamp":"`+time.Now().UTC().Add(2*time.Second).Format(time.RFC3339Nano)+`","type":"event_msg","payload":{"type":"agent_message","message":"第二段迟到回复"}}`+"\n")
	readAssistant("第二段迟到回复")
}

func TestWebSocketAttachForwardsAssistantForInitialPrompt(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	rolloutPath := filepath.Join(home, ".codex", "sessions", "rollout-initial-prompt.jsonl")
	writeFile(t, rolloutPath, strings.Join([]string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"旧问题"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"旧回答"}}`,
		"",
	}, "\n"))
	writeCodexState(t, home, "thread-initial-prompt", projectDir, rolloutPath)

	fakeCodex := writeFakeCodex(t)
	handler, manager := newAcceptanceRouter(t, projectDir, fakeCodex)
	t.Cleanup(manager.Shutdown)

	server := httptest.NewServer(handler)
	defer server.Close()

	createReq := authedHTTPClientRequest(t, http.MethodPost, server.URL+"/api/sessions", map[string]any{
		"project_id":        "demo",
		"resume_id":         "thread-initial-prompt",
		"prompt":            "继续",
		"client_message_id": "client-initial-1",
		"cols":              120,
		"rows":              32,
	})
	createResp, err := http.DefaultClient.Do(createReq)
	if err != nil {
		t.Fatal(err)
	}
	defer createResp.Body.Close()
	if createResp.StatusCode != http.StatusCreated {
		t.Fatalf("期望创建带 prompt 的 resume 会话返回 201，实际 %d", createResp.StatusCode)
	}
	var created struct {
		Session      session.SessionSnapshot `json:"session"`
		WSURL        string                  `json:"ws_url"`
		FirstMessage agentMessage            `json:"first_message"`
	}
	if err := json.NewDecoder(createResp.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}
	if created.FirstMessage.ID != "client:client-initial-1" ||
		created.FirstMessage.ClientMessageID != "client-initial-1" ||
		created.FirstMessage.Role != "user" ||
		created.FirstMessage.Content != "继续" {
		t.Fatalf("POST first_message 用户确认异常：%+v", created.FirstMessage)
	}

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + created.WSURL
	header := http.Header{}
	header.Set("Authorization", "Bearer "+testToken)
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	appendFile(t, rolloutPath, `{"timestamp":"`+time.Now().UTC().Add(2*time.Second).Format(time.RFC3339Nano)+`","type":"event_msg","payload":{"type":"agent_message","message":"首条 prompt 的结构化回答"}}`+"\n")

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("WS attach 后未收到首条 prompt 的 assistant message_completed：%v trace=%+v", err, sessionTraceEvents(t, server.URL, created.Session.ID))
		}
		if event["type"] != "message_completed" {
			continue
		}
		message, ok := event["message"].(map[string]any)
		if !ok || message["role"] != "assistant" {
			continue
		}
		if message["session_id"] != created.Session.ID ||
			message["content"] != "首条 prompt 的结构化回答" ||
			message["send_status"] != "confirmed" {
			t.Fatalf("首条 prompt assistant message_completed 字段异常：%v", message)
		}
		if id, _ := message["id"].(string); !strings.HasPrefix(id, "rollout:") {
			t.Fatalf("assistant 应保留 rollout 稳定 id：%v", message)
		}
		break
	}
}

func TestWebSocketAttachMapsNewSessionThreadAndForwardsAssistant(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)

	oldRolloutPath := filepath.Join(home, ".codex", "sessions", "rollout-old-new-session.jsonl")
	writeFile(t, oldRolloutPath, `{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"旧回答"}}`+"\n")
	writeCodexState(t, home, "old-thread-before-new-session", projectDir, oldRolloutPath)

	fakeCodex := writeFakeCodex(t)
	handler, manager := newAcceptanceRouter(t, projectDir, fakeCodex)
	t.Cleanup(manager.Shutdown)

	server := httptest.NewServer(handler)
	defer server.Close()

	createReq := authedHTTPClientRequest(t, http.MethodPost, server.URL+"/api/sessions", map[string]any{
		"project_id":        "demo",
		"prompt":            "新会话问题",
		"client_message_id": "client-new-session-1",
		"cols":              120,
		"rows":              32,
	})
	createResp, err := http.DefaultClient.Do(createReq)
	if err != nil {
		t.Fatal(err)
	}
	defer createResp.Body.Close()
	if createResp.StatusCode != http.StatusCreated {
		t.Fatalf("期望创建新会话返回 201，实际 %d", createResp.StatusCode)
	}
	var created struct {
		Session      session.SessionSnapshot `json:"session"`
		WSURL        string                  `json:"ws_url"`
		FirstMessage agentMessage            `json:"first_message"`
	}
	if err := json.NewDecoder(createResp.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}
	if created.Session.ResumeID != "" || created.FirstMessage.ClientMessageID != "client-new-session-1" {
		t.Fatalf("新会话 fixture 异常：resume_id=%q first_client_message_id=%q", created.Session.ResumeID, created.FirstMessage.ClientMessageID)
	}

	rolloutPath := filepath.Join(home, ".codex", "sessions", "rollout-new-session.jsonl")
	writeFile(t, rolloutPath, `{"timestamp":"`+time.Now().UTC().Format(time.RFC3339Nano)+`","type":"event_msg","payload":{"type":"user_message","message":"新会话问题"}}`+"\n")
	insertCodexStateRow(t, home, codexThreadFixture{
		ID:          "thread-new-session",
		Title:       "New Session",
		CWD:         projectDir,
		RolloutPath: rolloutPath,
		UpdatedAt:   time.Now().UTC().Add(time.Second).UnixMilli(),
	})

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + created.WSURL
	header := http.Header{}
	header.Set("Authorization", "Bearer "+testToken)
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	appendFile(t, rolloutPath, `{"timestamp":"`+time.Now().UTC().Add(2*time.Second).Format(time.RFC3339Nano)+`","type":"event_msg","payload":{"type":"agent_message","message":"新会话结构化回答"}}`+"\n")

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("新会话未通过 thread 映射收到 assistant message_completed：%v trace=%+v", err, sessionTraceEvents(t, server.URL, created.Session.ID))
		}
		if event["type"] != "message_completed" {
			continue
		}
		message, ok := event["message"].(map[string]any)
		if !ok || message["role"] != "assistant" {
			continue
		}
		if message["session_id"] != created.Session.ID ||
			message["content"] != "新会话结构化回答" ||
			message["send_status"] != "confirmed" {
			t.Fatalf("新会话 assistant message_completed 字段异常：%v", message)
		}
		break
	}

	trace := sessionTraceEvents(t, server.URL, created.Session.ID)
	if !traceEventExists(trace, "history_thread_mapped") {
		t.Fatalf("新会话应记录 history_thread_mapped trace：%+v", trace)
	}
}

func TestWebSocketResumeForkRemapsToNewThreadAndForwardsAssistant(t *testing.T) {
	requireSQLite(t)

	home := t.TempDir()
	projectDir := t.TempDir()
	t.Setenv("HOME", home)
	now := time.Now().UTC()

	// 父 thread：会话开始前很久就创建（created_at 旧），但 resume 时被 Codex 触碰过（updated_at 新）。
	parentRolloutPath := filepath.Join(home, ".codex", "sessions", "rollout-fork-parent.jsonl")
	writeFile(t, parentRolloutPath, `{"timestamp":"2026-05-01T10:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"父 thread 旧回答"}}`+"\n")
	writeCodexStateRows(t, home, []codexThreadFixture{{
		ID:          "resume-fork-parent",
		Title:       "Fork Parent",
		CWD:         projectDir,
		RolloutPath: parentRolloutPath,
		CreatedAt:   now.Add(-time.Hour).UnixMilli(),
		UpdatedAt:   now.UnixMilli(),
	}})

	fakeCodex := writeFakeCodex(t)
	handler, manager := newAcceptanceRouter(t, projectDir, fakeCodex)
	t.Cleanup(manager.Shutdown)

	server := httptest.NewServer(handler)
	defer server.Close()

	createReq := authedHTTPClientRequest(t, http.MethodPost, server.URL+"/api/sessions", map[string]any{
		"project_id":        "demo",
		"resume_id":         "resume-fork-parent",
		"prompt":            "继续",
		"client_message_id": "client-fork-1",
		"cols":              120,
		"rows":              32,
	})
	createResp, err := http.DefaultClient.Do(createReq)
	if err != nil {
		t.Fatal(err)
	}
	defer createResp.Body.Close()
	if createResp.StatusCode != http.StatusCreated {
		t.Fatalf("期望创建 resume 会话返回 201，实际 %d", createResp.StatusCode)
	}
	var created struct {
		Session session.SessionSnapshot `json:"session"`
		WSURL   string                  `json:"ws_url"`
	}
	if err := json.NewDecoder(createResp.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}
	if created.Session.ResumeID != "resume-fork-parent" {
		t.Fatalf("resume 会话 fixture 异常：resume_id=%q", created.Session.ResumeID)
	}

	// 会话开始之后，Codex 把对话 fork 成了新 thread（created_at 在会话开始之后）。
	childRolloutPath := filepath.Join(home, ".codex", "sessions", "rollout-fork-child.jsonl")
	writeFile(t, childRolloutPath, `{"timestamp":"`+now.Format(time.RFC3339Nano)+`","type":"event_msg","payload":{"type":"user_message","message":"继续"}}`+"\n")
	insertCodexStateRow(t, home, codexThreadFixture{
		ID:          "resume-fork-child",
		Title:       "Fork Child",
		CWD:         projectDir,
		RolloutPath: childRolloutPath,
		CreatedAt:   now.UnixMilli(),
		UpdatedAt:   now.Add(2 * time.Second).UnixMilli(),
	})

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + created.WSURL
	header := http.Header{}
	header.Set("Authorization", "Bearer "+testToken)
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	appendFile(t, childRolloutPath, `{"timestamp":"`+now.Add(3*time.Second).Format(time.RFC3339Nano)+`","type":"event_msg","payload":{"type":"agent_message","message":"fork 后的结构化回答"}}`+"\n")

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("resume fork 未通过 thread 重映射收到 assistant message_completed：%v trace=%+v", err, sessionTraceEvents(t, server.URL, created.Session.ID))
		}
		if event["type"] != "message_completed" {
			continue
		}
		message, ok := event["message"].(map[string]any)
		if !ok || message["role"] != "assistant" {
			continue
		}
		// 旧 resume thread 的“父 thread 旧回答”不能被转发；只接受 fork 后的新回答。
		if message["content"] == "父 thread 旧回答" {
			t.Fatalf("不应转发旧 resume thread 的历史回答：%v", message)
		}
		if message["session_id"] != created.Session.ID ||
			message["content"] != "fork 后的结构化回答" ||
			message["send_status"] != "confirmed" {
			t.Fatalf("resume fork assistant message_completed 字段异常：%v", message)
		}
		break
	}

	trace := sessionTraceEvents(t, server.URL, created.Session.ID)
	if !traceEventExists(trace, "history_thread_mapped") {
		t.Fatalf("resume fork 应记录 history_thread_mapped trace：%+v", trace)
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
		Session session.SessionSnapshot `json:"session"`
		WSURL   string                  `json:"ws_url"`
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

func TestWebSocketAfterSeqSkipsAlreadySeenOutput(t *testing.T) {
	projectDir := t.TempDir()
	handler, manager := newAcceptanceRouter(t, projectDir, "/bin/cat")
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
		Session session.SessionSnapshot `json:"session"`
		WSURL   string                  `json:"ws_url"`
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
	if err := first.WriteJSON(map[string]any{"type": "input", "data": "hi\r"}); err != nil {
		t.Fatal(err)
	}
	lastSeq := readOutputContainsAndDrainQuiet(t, first, "hi")
	_ = first.Close()

	secondURL := wsURL + "?after_seq=" + fmt.Sprintf("%d", lastSeq)
	second, _, err := websocket.DefaultDialer.Dial(secondURL, header)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()

	_ = second.SetReadDeadline(time.Now().Add(time.Second))
	var event map[string]any
	if err := second.ReadJSON(&event); err != nil {
		t.Fatalf("after_seq 连接应先收到 session 元数据：%v", err)
	}
	if event["type"] != "session" {
		t.Fatalf("after_seq 连接首条消息应是 session，实际 %v", event)
	}

	_ = second.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
	if err := second.ReadJSON(&event); err == nil {
		if event["type"] == "output" {
			t.Fatalf("after_seq 已到最新水位时不应 replay 旧 output：%v", event)
		}
		t.Fatalf("after_seq 连接不应收到额外事件：%v", event)
	}
}

func readOutputContains(t *testing.T, conn *websocket.Conn, want string) int64 {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("未收到包含 %q 的 output：%v", want, err)
		}
		data, _ := event["data"].(string)
		if event["type"] == "output" && strings.Contains(data, want) {
			if seq, _ := event["seq"].(float64); seq <= 0 {
				t.Fatalf("实时 output 应带正数 seq：%v", event)
			} else {
				return int64(seq)
			}
		}
	}
}

func readOutputContainsAndDrainQuiet(t *testing.T, conn *websocket.Conn, want string) int64 {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var maxSeq int64
	found := false
	for {
		var event map[string]any
		if err := conn.ReadJSON(&event); err != nil {
			if found {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					return maxSeq
				}
			}
			t.Fatalf("未收到包含 %q 的 output：%v", want, err)
		}
		if event["type"] != "output" {
			continue
		}
		seq := int64(event["seq"].(float64))
		if seq > maxSeq {
			maxSeq = seq
		}
		data, _ := event["data"].(string)
		if strings.Contains(data, want) {
			found = true
			// PTY 输出可能把正文和换行拆成多个 chunk；找到目标输出后继续读一个短窗口，
			// 用真正最新的 seq 模拟浏览器本地水位。
			_ = conn.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
		}
	}
}

func sessionLastSeq(t *testing.T, serverURL string, sessionID string) int64 {
	t.Helper()
	req := authedHTTPClientRequest(t, http.MethodGet, serverURL+"/api/sessions/"+sessionID, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("期望 session detail 返回 200，实际 %d", resp.StatusCode)
	}
	var body struct {
		LastSeq int64 `json:"last_seq"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.LastSeq <= 0 {
		t.Fatalf("session detail 应返回正数 last_seq：%+v", body)
	}
	return body.LastSeq
}

func sessionTraceEvents(t *testing.T, serverURL string, sessionID string) []session.TraceEvent {
	t.Helper()
	req := authedHTTPClientRequest(t, http.MethodGet, serverURL+"/api/sessions/"+sessionID+"/trace", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("期望 trace 返回 200，实际 %d", resp.StatusCode)
	}
	var body struct {
		Trace []session.TraceEvent `json:"trace"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body.Trace
}

func traceEventExists(events []session.TraceEvent, eventType string) bool {
	for _, event := range events {
		if event.Type == eventType {
			return true
		}
	}
	return false
}

func sessionIDs(items []any) []string {
	ids := make([]string, 0, len(items))
	for _, item := range items {
		row, ok := item.(map[string]any)
		if !ok {
			continue
		}
		id, _ := row["id"].(string)
		ids = append(ids, id)
	}
	return ids
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
	CreatedAt    int64
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
		createdAt := row.CreatedAt
		if createdAt == 0 {
			createdAt = updatedAt - 1000
		}
		rolloutPath := fixtureRolloutPath(t, home, row)
		builder.WriteString("insert into threads (id, title, cwd, rollout_path, created_at_ms, updated_at_ms, archived) values (")
		builder.WriteString(quoteSQL(row.ID))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(title))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(row.CWD))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(rolloutPath))
		builder.WriteString(", ")
		builder.WriteString(fmt.Sprintf("%d, %d, 0", createdAt, updatedAt))
		builder.WriteString(");\n")
	}
	cmd := exec.Command("sqlite3", db, builder.String())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("创建 Codex state fixture 失败：%v output=%s", err, out)
	}
}

func insertCodexStateRow(t *testing.T, home string, row codexThreadFixture) {
	t.Helper()
	db := filepath.Join(home, ".codex", "state_5.sqlite")
	title := row.Title
	if title == "" {
		title = row.ID
	}
	updatedAt := row.UpdatedAt
	if updatedAt == 0 {
		updatedAt = time.Now().UTC().UnixMilli()
	}
	createdAt := row.CreatedAt
	if createdAt == 0 {
		createdAt = updatedAt - 1000
	}
	rolloutPath := fixtureRolloutPath(t, home, row)
	sql := "insert into threads (id, title, cwd, rollout_path, created_at_ms, updated_at_ms, archived) values (" +
		quoteSQL(row.ID) + ", " +
		quoteSQL(title) + ", " +
		quoteSQL(row.CWD) + ", " +
		quoteSQL(rolloutPath) + ", " +
		fmt.Sprintf("%d, %d, 0", createdAt, updatedAt) +
		");"
	cmd := exec.Command("sqlite3", db, sql)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("追加 Codex state fixture 失败：%v output=%s", err, out)
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
		rolloutPath := fixtureRolloutPath(t, home, row)
		builder.WriteString("insert into threads (id, title, cwd, rollout_path, source, thread_source, preview, created_at_ms, updated_at_ms, archived) values (")
		builder.WriteString(quoteSQL(row.ID))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(title))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(row.CWD))
		builder.WriteString(", ")
		builder.WriteString(quoteSQL(rolloutPath))
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

func fixtureRolloutPath(t *testing.T, home string, row codexThreadFixture) string {
	t.Helper()
	if row.RolloutPath != "" {
		return row.RolloutPath
	}
	path := filepath.Join(home, ".codex", "sessions", row.ID+".jsonl")
	message, err := json.Marshal(row.ID)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, `{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":`+string(message)+`}}`+"\n")
	return path
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

func appendFile(t *testing.T, path, content string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(content); err != nil {
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
