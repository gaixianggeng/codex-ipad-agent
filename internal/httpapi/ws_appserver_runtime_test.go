package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/appserver"
)

func TestAppServerSessionWebSocketForwardsStructuredEvents(t *testing.T) {
	cfg, registry, manager, checker, projectDir := runtimeRouterFixture(t)
	fake := &fakeAppServerRPC{notifications: make(chan appserver.Notification, 8)}
	fake.handler = func(method string, params map[string]any, result any) error {
		switch method {
		case "account/rateLimits/read":
			*(result.(*map[string]any)) = map[string]any{
				"rateLimits": map[string]any{
					"limitId": "codex",
				},
			}
		case "thread/read":
			*(result.(*appServerThreadEnvelope)) = appServerThreadEnvelope{Thread: appServerThread{
				ID:        "thread-ws",
				Preview:   "ws",
				CWD:       projectDir,
				CreatedAt: 1_780_300_000,
				UpdatedAt: 1_780_300_000,
				Status:    appServerThreadStatus{Type: "idle"},
			}}
		case "turn/start":
			if params["threadId"] != "thread-ws" {
				t.Fatalf("turn/start 应发送到当前 thread：%v", params)
			}
			*(result.(*appServerTurnEnvelope)) = appServerTurnEnvelope{Turn: appServerTurn{ID: "turn-ws", Status: "inProgress"}}
		default:
			t.Fatalf("不期望调用 method=%s params=%v", method, params)
		}
		return nil
	}
	runtime := NewCodexAppServerRuntime(registry, fake)
	handler := NewRouterWithRuntime(cfg, registry, manager, checker, "test", runtime)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, _, err := websocket.DefaultDialer.Dial(wsURL(server.URL, "/api/sessions/codex_thread-ws/ws"), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	var sessionMsg wsMessage
	if err := conn.ReadJSON(&sessionMsg); err != nil {
		t.Fatal(err)
	}
	if sessionMsg.Type != "session" || sessionMsg.SessionID != "codex_thread-ws" {
		t.Fatalf("连接后应先收到 session 快照：%+v", sessionMsg)
	}

	if err := conn.WriteJSON(wsMessage{Type: "input", Data: "hi", ClientMessageID: "client-ws"}); err != nil {
		t.Fatal(err)
	}
	var confirm wsMessage
	if err := conn.ReadJSON(&confirm); err != nil {
		t.Fatal(err)
	}
	if confirm.Type != "message_completed" || confirm.TurnID != "turn-ws" || confirm.ClientMessageID != "client-ws" {
		t.Fatalf("input 后应收到本地用户消息确认：%+v", confirm)
	}

	fake.notifications <- appserver.Notification{
		Method: "item/agentMessage/delta",
		Params: []byte(`{"threadId":"thread-ws","turnId":"turn-ws","itemId":"assistant-1","delta":"hello"}`),
	}
	var delta wsMessage
	if err := readWSMessageWithTimeout(conn, &delta); err != nil {
		t.Fatal(err)
	}
	if delta.Type != "assistant_delta" || delta.Data != "hello" || delta.TurnID != "turn-ws" || delta.ItemID != "assistant-1" {
		t.Fatalf("app-server assistant delta 映射异常：%+v", delta)
	}
	if delta.MessageID != "appserver:turn-ws:assistant-1" {
		t.Fatalf("assistant delta 应使用和历史页一致的稳定 message_id：%+v", delta)
	}
	if delta.Seq <= 0 || delta.Revision <= 0 {
		t.Fatalf("结构化事件必须带 seq/revision：%+v", delta)
	}

	fake.notifications <- appserver.Notification{
		Method: "item/completed",
		Params: []byte(`{"threadId":"thread-ws","turnId":"turn-ws","item":{"type":"agentMessage","id":"assistant-1","text":"hello world"}}`),
	}
	var completed wsMessage
	if err := readWSMessageWithTimeout(conn, &completed); err != nil {
		t.Fatal(err)
	}
	if completed.Type != "message_completed" || completed.Message == nil {
		t.Fatalf("app-server item/completed 应映射为 message_completed：%+v", completed)
	}
	if completed.Message.ID != "appserver:turn-ws:assistant-1" || completed.Message.Content != "hello world" {
		t.Fatalf("completed agentMessage 应用全文覆盖 streaming 气泡：%+v", completed)
	}
	if completed.Message.Revision <= int(delta.Revision) || completed.Revision <= delta.Revision {
		t.Fatalf("completed 应带更新 revision，保证 iOS 能覆盖 delta：delta=%+v completed=%+v", delta, completed)
	}

	resultCh := make(chan any, 1)
	errCh := make(chan *appserver.RPCError, 1)
	approvalCtx, approvalCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer approvalCancel()
	go func() {
		result, rpcErr := runtime.HandleServerRequest(approvalCtx, appserver.ServerRequest{
			Method: "item/commandExecution/requestApproval",
			Params: []byte(`{"threadId":"thread-ws","turnId":"turn-ws","itemId":"cmd-approval","command":"go test ./...","reason":"run tests"}`),
		})
		resultCh <- result
		errCh <- rpcErr
	}()

	var approval wsMessage
	if err := readWSMessageWithTimeout(conn, &approval); err != nil {
		t.Fatal(err)
	}
	if approval.Type != "approval_request" || approval.Approval == nil {
		t.Fatalf("server request 应广播 approval_request：%+v", approval)
	}
	payload, ok := approval.Approval.(map[string]any)
	if !ok || payload["id"] != "cmd-approval" {
		t.Fatalf("approval_request 应带稳定 approval id：%+v", approval.Approval)
	}
	if err := conn.WriteJSON(wsMessage{Type: "approval_decision", ApprovalID: "cmd-approval", Decision: "accept"}); err != nil {
		t.Fatal(err)
	}
	var rpcErr *appserver.RPCError
	select {
	case rpcErr = <-errCh:
	case <-time.After(2 * time.Second):
		t.Fatal("WS approval_decision 后 server request 未返回")
	}
	if rpcErr != nil {
		t.Fatal(rpcErr)
	}
	result := readApprovalResult(t, resultCh).(map[string]any)
	if decision := result["decision"]; decision != "accept" {
		t.Fatalf("WS approval_decision 应让 server request 返回 accept，got=%v", decision)
	}
	if _, hasMessage := result["message"]; hasMessage {
		t.Fatalf("v2 approval response 不能携带协议外 message 字段：%+v", result)
	}
}

func wsURL(serverURL string, path string) string {
	return "ws" + strings.TrimPrefix(serverURL, "http") + path
}

func readWSMessageWithTimeout(conn *websocket.Conn, out *wsMessage) error {
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	return conn.ReadJSON(out)
}
