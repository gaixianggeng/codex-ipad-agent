package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/doctor"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

func TestAppServerConfigRequiresAuthAndReturnsSanitizedMetadata(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/app-server/config", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("config metadata 必须要求 Bearer Token，got=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}
	if connections.Load() != 0 {
		t.Fatalf("读取 metadata 不应连接 app-server upstream，connections=%d", connections.Load())
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/config", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("config metadata 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
	}
	bodyText := rec.Body.String()
	if strings.Contains(bodyText, testToken) || strings.Contains(bodyText, "real_path") || strings.Contains(bodyText, "RealPath") {
		t.Fatalf("config metadata 不应泄漏 token 或 RealPath：%s", bodyText)
	}
	body := decodeJSON(t, rec)
	if got, _ := body["gateway_ws_url"].(string); got == "" || !strings.HasPrefix(got, "ws://") || !strings.Contains(got, appServerGatewayPath) {
		t.Fatalf("config metadata 应返回 gateway ws url：%v", body)
	}
	runtime, ok := body["runtime"].(map[string]any)
	if !ok || runtime["managed"] != true || runtime["transport"] != "ws" || runtime["gateway_available"] != true {
		t.Fatalf("runtime metadata 异常：%v", body)
	}
	projects, ok := body["projects"].([]any)
	if !ok || len(projects) != 1 {
		t.Fatalf("projects metadata 异常：%v", body)
	}
	project := projects[0].(map[string]any)
	if project["id"] != "demo" || project["path"] == "" {
		t.Fatalf("projects 应只返回安全字段：%v", project)
	}
}

func TestAppServerGatewayRejectsMissingBearerTokenBeforeUpstreamDial(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), nil)
	if err == nil {
		_ = conn.Close()
		t.Fatal("未带 Bearer Token 的 gateway WS 不应连接成功")
	}
	if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("未授权 gateway WS 应返回 401，resp=%v err=%v", resp, err)
	}
	if connections.Load() != 0 {
		t.Fatalf("未授权请求必须在连接 upstream 前被拒绝，connections=%d", connections.Load())
	}
}

func TestAppServerGatewaySendsConfiguredUpstreamToken(t *testing.T) {
	upstreamToken := "upstream-capability-token"
	upstreamURL, received, _ := fakeAppServerUpstreamWithAuth(t, upstreamToken, nil)
	handler, projectDir := appServerGatewayRouterFixtureWithTokenFile(t, upstreamURL, upstreamToken)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	authorized := []byte(fmt.Sprintf(
		`{"id":8,"method":"thread/start","params":{"cwd":%q,"approvalPolicy":"on-request","sandbox":"workspace-write"}}`,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, authorized); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-received:
		if !bytes.Equal(got, authorized) {
			t.Fatalf("合法帧必须原样转发：got=%s want=%s", got, authorized)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到合法帧，可能 upstream Authorization 未发送")
	}
}

func TestAppServerGatewayRejectsEmptyUpstreamTokenFileBeforeDial(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	tokenFile := filepath.Join(t.TempDir(), "empty-token")
	if err := os.WriteFile(tokenFile, []byte(" \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.WSTokenFile = tokenFile
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err == nil {
		_ = conn.Close()
		t.Fatal("空 upstream token file 不应连接成功")
	}
	if resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("空 upstream token file 应返回 503，resp=%v err=%v", resp, err)
	}
	if connections.Load() != 0 {
		t.Fatalf("上游 token 配置无效时不应拨 upstream，connections=%d", connections.Load())
	}
}

func TestAppServerGatewayRejectsNonLoopbackUpstreamBeforeDial(t *testing.T) {
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, "ws://203.0.113.10:4222", nil)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err == nil {
		_ = conn.Close()
		t.Fatal("非 loopback upstream 不应连接成功")
	}
	if resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("非 loopback upstream 应返回 503，resp=%v err=%v", resp, err)
	}
}

func TestAppServerGatewayRejectsUnsafeMethodWithoutForwarding(t *testing.T) {
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"id":1,"method":"session/delete","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	errFrame := readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "method 不允许") || string(errFrame.id) != "1" {
		t.Fatalf("非法 method 应返回同 id JSON-RPC error：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayRejectsUnauthorizedThreadIDWithoutForwarding(t *testing.T) {
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	cases := []struct {
		name    string
		payload string
		want    string
	}{
		{
			name:    "thread read",
			payload: `{"id":11,"method":"thread/read","params":{"threadId":"thread-outside","includeTurns":true}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name: "turn start",
			payload: fmt.Sprintf(
				`{"id":12,"method":"turn/start","params":{"threadId":"thread-outside","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
				projectDir,
				projectDir,
			),
			want: "threadId 未由当前 gateway 连接授权",
		},
		{
			name: "thread resume",
			payload: fmt.Sprintf(
				`{"id":13,"method":"thread/resume","params":{"threadId":"thread-outside","cwd":%q,"approvalPolicy":"on-request","sandbox":"workspace-write"}}`,
				projectDir,
			),
			want: "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "turn interrupt",
			payload: `{"id":14,"method":"turn/interrupt","params":{"threadId":"thread-outside","turnId":"turn-1"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := conn.WriteMessage(websocket.TextMessage, []byte(tc.payload)); err != nil {
				t.Fatal(err)
			}
			errFrame := readGatewayError(t, conn)
			if !strings.Contains(errFrame.message, tc.want) {
				t.Fatalf("unauthorized thread error 应包含 %q，got=%+v", tc.want, errFrame)
			}
		})
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayAuthorizesThreadIDsFromThreadListResponse(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame appServerGatewayFrame
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("fake upstream 收到非法 JSON：%v", err)
			return
		}
		if frame.Method != "thread/list" {
			return
		}
		response := fmt.Sprintf(
			`{"id":%s,"result":{"data":[{"id":"thread-authorized","cwd":%q}]}}`,
			string(*frame.ID),
			projectDir,
		)
		if err := conn.WriteMessage(websocket.TextMessage, []byte(response)); err != nil {
			t.Errorf("fake upstream 写 thread/list 响应失败：%v", err)
		}
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	authorizeGatewayThread(t, conn, received, projectDir, "thread-authorized")

	readFrame := []byte(`{"id":31,"method":"thread/read","params":{"threadId":"thread-authorized","includeTurns":true}}`)
	if err := conn.WriteMessage(websocket.TextMessage, readFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if !bytes.Equal(got, readFrame) {
			t.Fatalf("已授权 thread/read 必须原样转发：got=%s want=%s", got, readFrame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到已授权 thread/read")
	}
}

func TestAppServerGatewayKeepsAuthorizedThreadAcrossReconnects(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-reconnect")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	first := dialAuthedGateway(t, server.URL)
	authorizeGatewayThread(t, first, received, projectDir, "thread-reconnect")
	_ = first.Close()

	second := dialAuthedGateway(t, server.URL)
	defer second.Close()

	turnFrame := []byte(fmt.Sprintf(
		`{"id":32,"method":"turn/start","params":{"threadId":"thread-reconnect","cwd":%q,"input":[{"type":"text","text":"after reconnect"}],"approvalPolicy":"on-request","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		projectDir,
		projectDir,
	))
	if err := second.WriteMessage(websocket.TextMessage, turnFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if !bytes.Equal(got, turnFrame) {
			t.Fatalf("重连后已授权 turn/start 必须原样转发：got=%s want=%s", got, turnFrame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到重连后的已授权 turn/start")
	}
}

func TestAppServerGatewayRejectsUnsafeCWDAndSandbox(t *testing.T) {
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	outsideDir := t.TempDir()
	cases := []struct {
		name    string
		payload map[string]any
		want    string
	}{
		{
			name: "cwd outside allowlist",
			payload: map[string]any{
				"id":     2,
				"method": "thread/start",
				"params": map[string]any{
					"cwd":            outsideDir,
					"approvalPolicy": "on-request",
					"sandbox":        "workspace-write",
				},
			},
			want: "cwd",
		},
		{
			name: "thread list missing cwd",
			payload: map[string]any{
				"id":     6,
				"method": "thread/list",
				"params": map[string]any{
					"limit": 20,
				},
			},
			want: "cwd",
		},
		{
			name: "danger full access",
			payload: map[string]any{
				"id":     3,
				"method": "turn/start",
				"params": map[string]any{
					"threadId":       "thread-1",
					"cwd":            projectDir,
					"approvalPolicy": "on-request",
					"sandboxPolicy": map[string]any{
						"type":          "dangerFullAccess",
						"writableRoots": []string{projectDir},
					},
				},
			},
			want: "dangerFullAccess",
		},
		{
			name: "approval policy never",
			payload: map[string]any{
				"id":     4,
				"method": "turn/start",
				"params": map[string]any{
					"threadId":       "thread-1",
					"cwd":            projectDir,
					"approvalPolicy": "never",
					"sandboxPolicy": map[string]any{
						"type":          "workspaceWrite",
						"writableRoots": []string{projectDir},
						"networkAccess": false,
					},
				},
			},
			want: "approvalPolicy=never",
		},
		{
			name: "network access",
			payload: map[string]any{
				"id":     5,
				"method": "turn/start",
				"params": map[string]any{
					"threadId":       "thread-1",
					"cwd":            projectDir,
					"approvalPolicy": "on-request",
					"sandboxPolicy": map[string]any{
						"type":          "workspaceWrite",
						"writableRoots": []string{projectDir},
						"networkAccess": true,
					},
				},
			},
			want: "networkAccess",
		},
		{
			name: "network access string",
			payload: map[string]any{
				"id":     9,
				"method": "turn/start",
				"params": map[string]any{
					"threadId":       "thread-1",
					"cwd":            projectDir,
					"approvalPolicy": "on-request",
					"sandboxPolicy": map[string]any{
						"type":          "workspaceWrite",
						"writableRoots": []string{projectDir},
						"networkAccess": "true",
					},
				},
			},
			want: "networkAccess",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			payload, err := json.Marshal(tc.payload)
			if err != nil {
				t.Fatal(err)
			}
			if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
				t.Fatal(err)
			}
			errFrame := readGatewayError(t, conn)
			if !strings.Contains(errFrame.message, tc.want) {
				t.Fatalf("unsafe policy error 应包含 %q，got=%+v", tc.want, errFrame)
			}
		})
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayDoesNotScanPromptTextForDangerFullAccess(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-1")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	authorizeGatewayThread(t, conn, received, projectDir, "thread-1")

	authorized := []byte(fmt.Sprintf(
		`{"id":10,"method":"turn/start","params":{"threadId":"thread-1","cwd":%q,"input":[{"type":"text","text":"danger-full-access"}],"approvalPolicy":"on-request","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		projectDir,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, authorized); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-received:
		if !bytes.Equal(got, authorized) {
			t.Fatalf("prompt 中的策略 token 不应被 gateway 当作策略字段：got=%s want=%s", got, authorized)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到合法 prompt 帧")
	}
}

func TestAppServerGatewayForwardsAuthorizedFrameUnchanged(t *testing.T) {
	upstreamResponse := []byte(`{"id":7,"result":{"ok":true}}`)
	upstreamNotification := []byte(`{"method":"item/agentMessage/delta","params":{"delta":"hello"}}`)
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame appServerGatewayFrame
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("fake upstream 收到非法 JSON：%v", err)
			return
		}
		if frame.Method == "thread/list" {
			respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-1")
			return
		}
		if err := conn.WriteMessage(websocket.TextMessage, upstreamResponse); err != nil {
			t.Errorf("fake upstream 写响应失败：%v", err)
		}
		if err := conn.WriteMessage(websocket.TextMessage, upstreamNotification); err != nil {
			t.Errorf("fake upstream 写通知失败：%v", err)
		}
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	authorizeGatewayThread(t, conn, received, projectDir, "thread-1")

	authorized := []byte(fmt.Sprintf(
		`{"id":7,"method":"turn/start","params":{"threadId":"thread-1","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		projectDir,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, authorized); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-received:
		if !bytes.Equal(got, authorized) {
			t.Fatalf("合法帧必须原样转发：got=%s want=%s", got, authorized)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到合法帧")
	}

	got := readGatewayRaw(t, conn)
	if !bytes.Equal(got, upstreamResponse) {
		t.Fatalf("upstream 响应必须原样返回：got=%s want=%s", got, upstreamResponse)
	}
	notification := readGatewayRaw(t, conn)
	if !bytes.Equal(notification, upstreamNotification) {
		t.Fatalf("upstream notification 必须原样返回：got=%s want=%s", notification, upstreamNotification)
	}
}

func authorizeGatewayThread(t *testing.T, conn *websocket.Conn, received <-chan []byte, projectDir string, threadID string) {
	t.Helper()
	listFrame := []byte(fmt.Sprintf(
		`{"id":30,"method":"thread/list","params":{"cwd":%q,"limit":20}}`,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, listFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if !bytes.Equal(got, listFrame) {
			t.Fatalf("thread/list 授权请求必须原样转发：got=%s want=%s", got, listFrame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到 thread/list 授权请求")
	}
	raw := readGatewayRaw(t, conn)
	if !bytes.Contains(raw, []byte(threadID)) {
		t.Fatalf("thread/list 授权响应应包含 thread id %s：%s", threadID, raw)
	}
}

func respondToThreadListAuthorization(t *testing.T, conn *websocket.Conn, payload []byte, projectDir string, threadID string) {
	t.Helper()
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		t.Errorf("fake upstream 收到非法 JSON：%v", err)
		return
	}
	if frame.Method != "thread/list" {
		return
	}
	response := fmt.Sprintf(
		`{"id":%s,"result":{"data":[{"id":%q,"cwd":%q}]}}`,
		string(*frame.ID),
		threadID,
		projectDir,
	)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(response)); err != nil {
		t.Errorf("fake upstream 写 thread/list 响应失败：%v", err)
	}
}

func appServerGatewayRouterFixture(t *testing.T, upstreamURL string) (http.Handler, string) {
	t.Helper()
	return appServerGatewayRouterFixtureWithConfig(t, upstreamURL, nil)
}

func appServerGatewayRouterFixtureWithTokenFile(t *testing.T, upstreamURL string, token string) (http.Handler, string) {
	t.Helper()
	tokenFile := filepath.Join(t.TempDir(), "app-server-token")
	if err := os.WriteFile(tokenFile, []byte(token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.WSTokenFile = tokenFile
	})
}

func appServerGatewayRouterFixtureWithConfig(t *testing.T, upstreamURL string, customize func(*config.Config)) (http.Handler, string) {
	t.Helper()
	cfg, registry, manager, checker, projectDir := appServerGatewayBaseFixture(t)
	cfg.AppServer = config.AppServerConfig{
		Transport: "ws",
		Managed:   true,
		Listen:    upstreamURL,
	}
	if customize != nil {
		customize(&cfg)
	}
	return NewRouterWithRuntime(cfg, registry, manager, checker, "test", nil), projectDir
}

func appServerGatewayBaseFixture(t *testing.T) (config.Config, *projects.Registry, *session.Manager, *doctor.Checker, string) {
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
	return cfg, registry, manager, checker, projectDir
}

func fakeAppServerUpstream(t *testing.T, onFrame func(conn *websocket.Conn, messageType int, payload []byte)) (string, <-chan []byte, *atomic.Int64) {
	t.Helper()
	return fakeAppServerUpstreamWithAuth(t, "", onFrame)
}

func fakeAppServerUpstreamWithAuth(t *testing.T, expectedToken string, onFrame func(conn *websocket.Conn, messageType int, payload []byte)) (string, <-chan []byte, *atomic.Int64) {
	t.Helper()
	received := make(chan []byte, 8)
	var connections atomic.Int64
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		connections.Add(1)
		if expectedToken != "" && req.Header.Get("Authorization") != "Bearer "+expectedToken {
			http.Error(w, "missing upstream token", http.StatusUnauthorized)
			return
		}
		conn, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			messageType, payload, err := conn.ReadMessage()
			if err != nil {
				return
			}
			received <- append([]byte(nil), payload...)
			if onFrame != nil {
				onFrame(conn, messageType, payload)
			}
		}
	}))
	t.Cleanup(server.Close)
	return wsURL(server.URL, "/"), received, &connections
}

func wsURL(serverURL string, path string) string {
	parsed, err := url.Parse(serverURL)
	if err != nil {
		return serverURL
	}
	switch parsed.Scheme {
	case "https":
		parsed.Scheme = "wss"
	default:
		parsed.Scheme = "ws"
	}
	parsed.Path = path
	return parsed.String()
}

func dialAuthedGateway(t *testing.T, serverURL string) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.DefaultDialer.Dial(wsURL(serverURL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

type gatewayErrorFrame struct {
	id      json.RawMessage
	message string
}

func readGatewayError(t *testing.T, conn *websocket.Conn) gatewayErrorFrame {
	t.Helper()
	raw := readGatewayRaw(t, conn)
	var frame struct {
		ID    json.RawMessage `json:"id"`
		Error struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatalf("gateway error 不是合法 JSON：%v raw=%s", err, raw)
	}
	if frame.Error.Code != appServerPolicyErrorCode || frame.Error.Message == "" {
		t.Fatalf("gateway error code/message 异常：%+v raw=%s", frame, raw)
	}
	return gatewayErrorFrame{id: frame.ID, message: frame.Error.Message}
}

func readGatewayRaw(t *testing.T, conn *websocket.Conn) []byte {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	messageType, payload, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if messageType != websocket.TextMessage {
		t.Fatalf("期望 text message，got=%d payload=%s", messageType, payload)
	}
	return payload
}

func assertNoUpstreamFrame(t *testing.T, received <-chan []byte) {
	t.Helper()
	select {
	case payload := <-received:
		t.Fatalf("非法帧不应转发到 upstream：%s", payload)
	case <-time.After(150 * time.Millisecond):
	}
}
