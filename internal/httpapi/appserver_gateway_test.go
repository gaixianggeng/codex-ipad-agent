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

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
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
		`{"id":8,"method":"thread/start","params":{"cwd":%q,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}}`,
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
				`{"id":12,"method":"turn/start","params":{"threadId":"thread-outside","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
				projectDir,
				projectDir,
			),
			want: "threadId 未由当前 gateway 连接授权",
		},
		{
			name: "thread resume",
			payload: fmt.Sprintf(
				`{"id":13,"method":"thread/resume","params":{"threadId":"thread-outside","cwd":%q,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}}`,
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
		`{"id":32,"method":"turn/start","params":{"threadId":"thread-reconnect","cwd":%q,"input":[{"type":"text","text":"after reconnect"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
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

func TestAppServerGatewayBindsBrowseWorkspaceToExactCWD(t *testing.T) {
	browseRoot := t.TempDir()
	financeDir := filepath.Join(browseRoot, "finance")
	documentsDir := filepath.Join(browseRoot, "Documents")
	for _, dir := range []string{financeDir, documentsDir} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	realFinanceDir, err := filepath.EvalSymlinks(financeDir)
	if err != nil {
		t.Fatal(err)
	}
	realDocumentsDir, err := filepath.EvalSymlinks(documentsDir)
	if err != nil {
		t.Fatal(err)
	}
	financeFile := filepath.Join(realFinanceDir, "report.csv")
	if err := os.WriteFile(financeFile, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	documentsFile := filepath.Join(realDocumentsDir, "note.md")
	if err := os.WriteFile(documentsFile, []byte("note"), 0o644); err != nil {
		t.Fatal(err)
	}

	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, realFinanceDir, "thread-browse")
	})
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.BrowseRoots = []string{browseRoot}
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	// browse_roots 内的目录可以作为 thread/list cwd 并授权线程。
	authorizeGatewayThread(t, conn, received, realFinanceDir, "thread-browse")

	turnFrame := []byte(fmt.Sprintf(
		`{"id":61,"method":"turn/start","params":{"threadId":"thread-browse","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		realFinanceDir,
		realFinanceDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, turnFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if !bytes.Equal(got, turnFrame) {
			t.Fatalf("browse workspace 同 cwd 的 turn/start 应原样转发：got=%s want=%s", got, turnFrame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到 browse workspace 的 turn/start")
	}

	// 绑定目录内的结构化输入路径允许通过。
	mentionFrame := []byte(fmt.Sprintf(
		`{"id":62,"method":"turn/start","params":{"threadId":"thread-browse","cwd":%q,"input":[{"type":"mention","name":"report","path":%q}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		realFinanceDir,
		financeFile,
		realFinanceDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, mentionFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if !bytes.Equal(got, mentionFrame) {
			t.Fatalf("绑定目录内 mention 输入应原样转发：got=%s want=%s", got, mentionFrame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到 mention turn/start")
	}

	// 同一 browse root 下的 sibling 目录：cwd 与输入路径都必须被拒。
	siblingTurn := []byte(fmt.Sprintf(
		`{"id":63,"method":"turn/start","params":{"threadId":"thread-browse","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		realDocumentsDir,
		realDocumentsDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, siblingTurn); err != nil {
		t.Fatal(err)
	}
	errFrame := readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "必须匹配已授权 thread 的工作区") {
		t.Fatalf("sibling 目录 turn/start 应被精确绑定拒绝：%+v", errFrame)
	}

	siblingMention := []byte(fmt.Sprintf(
		`{"id":64,"method":"turn/start","params":{"threadId":"thread-browse","cwd":%q,"input":[{"type":"mention","name":"note","path":%q}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		realFinanceDir,
		documentsFile,
		realFinanceDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, siblingMention); err != nil {
		t.Fatal(err)
	}
	errFrame = readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "turn/start.input path") {
		t.Fatalf("sibling 目录的输入路径应被拒绝：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayThreadCachePrunesExpiredEntries(t *testing.T) {
	router := &Router{gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	expiredAt := time.Now().Add(-appServerGatewayThreadCacheTTL - time.Second)
	router.gatewayThreads["thread-expired"] = appServerGatewayAllowedThread{
		id:       "thread-expired",
		scopeID:  "demo",
		lastSeen: expiredAt,
	}

	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-fresh", scopeID: "demo"})

	if _, ok := router.gatewayThreads["thread-expired"]; ok {
		t.Fatal("过期 gateway thread 授权应在写入新授权时被裁剪")
	}
	if _, ok := router.gatewayThread("thread-fresh"); !ok {
		t.Fatal("新写入的 gateway thread 授权不应被裁剪")
	}
}

func TestAppServerGatewayThreadCachePrunesOldestWhenFull(t *testing.T) {
	router := &Router{gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	baseSeen := time.Now().Add(-time.Hour)
	for i := 0; i < appServerGatewayThreadCacheMax; i++ {
		id := fmt.Sprintf("thread-%04d", i)
		router.gatewayThreads[id] = appServerGatewayAllowedThread{
			id:       id,
			scopeID:  "demo",
			lastSeen: baseSeen.Add(time.Duration(i) * time.Second),
		}
	}

	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-new", scopeID: "demo"})

	if len(router.gatewayThreads) > appServerGatewayThreadCacheMax {
		t.Fatalf("gateway thread 授权缓存应有容量上限，got=%d max=%d", len(router.gatewayThreads), appServerGatewayThreadCacheMax)
	}
	if _, ok := router.gatewayThreads["thread-0000"]; ok {
		t.Fatal("容量超限时应裁剪最久未使用的 gateway thread 授权")
	}
	if _, ok := router.gatewayThread("thread-new"); !ok {
		t.Fatal("新写入的 gateway thread 授权应保留")
	}
}

func TestAppServerGatewayObservesThreadResponseOnlyWithPendingRequest(t *testing.T) {
	_, registry, _, _, projectDir := appServerGatewayBaseFixture(t)
	router := &Router{
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := &appServerGatewayPolicy{
		router:                router,
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
	payload := []byte(fmt.Sprintf(
		`{"id":42,"result":{"data":[{"id":"thread-pending","cwd":%q}]}}`,
		projectDir,
	))

	if forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload); !forward || policyErr != nil {
		t.Fatalf("普通上游响应应继续转发：forward=%v err=%+v", forward, policyErr)
	}
	if _, ok := router.gatewayThread("thread-pending"); ok {
		t.Fatal("没有 pending thread 请求时，上游业务帧不应创建授权")
	}

	id := json.RawMessage("42")
	if err := policy.rememberPendingThreadResponse(&id, "thread/list", projectDir, "demo"); err != nil {
		t.Fatal(err)
	}
	if forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload); !forward || policyErr != nil {
		t.Fatalf("thread/list 响应应继续转发：forward=%v err=%+v", forward, policyErr)
	}
	if _, ok := router.gatewayThread("thread-pending"); !ok {
		t.Fatal("存在 pending thread 请求时，上游响应仍必须创建授权")
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
		{
			name: "config approval policy never snake case",
			payload: map[string]any{
				"id":     15,
				"method": "thread/start",
				"params": map[string]any{
					"cwd":            projectDir,
					"approvalPolicy": "on-request",
					"sandbox":        "workspace-write",
					"config": map[string]any{
						"approval_policy": "never",
					},
				},
			},
			want: "approvalPolicy=never",
		},
		{
			name: "config danger full access snake case",
			payload: map[string]any{
				"id":     16,
				"method": "thread/start",
				"params": map[string]any{
					"cwd":            projectDir,
					"approvalPolicy": "on-request",
					"sandbox":        "workspace-write",
					"config": map[string]any{
						"sandbox_mode": "danger-full-access",
					},
				},
			},
			want: "dangerFullAccess",
		},
		{
			name: "config network access snake case",
			payload: map[string]any{
				"id":     17,
				"method": "thread/start",
				"params": map[string]any{
					"cwd":            projectDir,
					"approvalPolicy": "on-request",
					"sandbox":        "workspace-write",
					"config": map[string]any{
						"network_access": true,
					},
				},
			},
			want: "networkAccess",
		},
		{
			name: "input must be array",
			payload: map[string]any{
				"id":     11,
				"method": "turn/start",
				"params": map[string]any{
					"threadId":       "thread-1",
					"cwd":            projectDir,
					"input":          map[string]any{"type": "text", "text": "hi"},
					"approvalPolicy": "on-request",
					"sandboxPolicy": map[string]any{
						"type":          "workspaceWrite",
						"writableRoots": []string{projectDir},
						"networkAccess": false,
					},
				},
			},
			want: "turn/start.input 必须是数组",
		},
		{
			name: "unknown input type",
			payload: map[string]any{
				"id":     12,
				"method": "turn/start",
				"params": map[string]any{
					"threadId":       "thread-1",
					"cwd":            projectDir,
					"input":          []any{map[string]any{"type": "audio", "url": "https://example.test/a.wav"}},
					"approvalPolicy": "on-request",
					"sandboxPolicy": map[string]any{
						"type":          "workspaceWrite",
						"writableRoots": []string{projectDir},
						"networkAccess": false,
					},
				},
			},
			want: "类型不支持",
		},
		{
			name: "image file URL",
			payload: map[string]any{
				"id":     13,
				"method": "turn/start",
				"params": map[string]any{
					"threadId":       "thread-1",
					"cwd":            projectDir,
					"input":          []any{map[string]any{"type": "image", "url": "file:///tmp/screen.png"}},
					"approvalPolicy": "on-request",
					"sandboxPolicy": map[string]any{
						"type":          "workspaceWrite",
						"writableRoots": []string{projectDir},
						"networkAccess": false,
					},
				},
			},
			want: "不允许 file URL",
		},
		{
			name: "local image outside allowlist",
			payload: map[string]any{
				"id":     14,
				"method": "turn/start",
				"params": map[string]any{
					"threadId":       "thread-1",
					"cwd":            projectDir,
					"input":          []any{map[string]any{"type": "localImage", "path": filepath.Join(outsideDir, "screen.png")}},
					"approvalPolicy": "on-request",
					"sandboxPolicy": map[string]any{
						"type":          "workspaceWrite",
						"writableRoots": []string{projectDir},
						"networkAccess": false,
					},
				},
			},
			want: "path 必须来自 projects allowlist",
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
		`{"id":10,"method":"turn/start","params":{"threadId":"thread-1","cwd":%q,"input":[{"type":"text","text":"danger-full-access"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
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

func TestAppServerGatewayRewritesMissingSafeDefaults(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-safe-default")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	threadStart := []byte(fmt.Sprintf(
		`{"id":50,"method":"thread/start","params":{"cwd":%q,"sandbox":"custom","approvalsReviewer":"auto_review","permissions":{"sandbox":"workspace-write"},"runtimeWorkspaceRoots":["/tmp/other"],"dynamicTools":{"shell":true},"environments":{"SECRET":"token"},"config":{"feature":true}}}`,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, threadStart); err != nil {
		t.Fatal(err)
	}
	gotThreadStart := readUpstreamFrame(t, received)
	threadParams := decodeGatewayParamsForTest(t, gotThreadStart)
	if threadParams["approvalPolicy"] != "on-request" || threadParams["approvalsReviewer"] != "user" || threadParams["sandbox"] != "workspace-write" {
		t.Fatalf("thread/start 应补安全默认值：%s", gotThreadStart)
	}
	assertGatewayParamAbsent(t, threadParams, "permissions", "runtimeWorkspaceRoots", "dynamicTools", "environments", "config")

	authorizeGatewayThread(t, conn, received, projectDir, "thread-safe-default")

	turnStart := []byte(fmt.Sprintf(
		`{"id":51,"method":"turn/start","params":{"threadId":"thread-safe-default","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-failure","approvalsReviewer":"auto_review","permissions":{"sandbox":"workspace-write"},"runtimeWorkspaceRoots":["/tmp/other"],"dynamicTools":{"shell":true},"environments":{"SECRET":"token"},"config":{"feature":true},"outputSchema":{"type":"object"}}}`,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, turnStart); err != nil {
		t.Fatal(err)
	}
	gotTurnStart := readUpstreamFrame(t, received)
	turnParams := decodeGatewayParamsForTest(t, gotTurnStart)
	if turnParams["approvalPolicy"] != "on-request" {
		t.Fatalf("turn/start 应强制 approvalPolicy=on-request：%s", gotTurnStart)
	}
	if turnParams["approvalsReviewer"] != "user" {
		t.Fatalf("turn/start 应强制 approvalsReviewer=user：%s", gotTurnStart)
	}
	assertGatewayParamAbsent(t, turnParams, "permissions", "runtimeWorkspaceRoots", "dynamicTools", "environments", "config", "outputSchema")
	sandbox, ok := turnParams["sandboxPolicy"].(map[string]any)
	if !ok {
		t.Fatalf("turn/start 应补 sandboxPolicy：%s", gotTurnStart)
	}
	if sandbox["type"] != "workspaceWrite" || sandbox["networkAccess"] != false {
		t.Fatalf("sandboxPolicy 应使用 workspaceWrite 且禁用网络：%v", sandbox)
	}
	roots, ok := sandbox["writableRoots"].([]any)
	if !ok || len(roots) != 1 || roots[0] != projectDir {
		t.Fatalf("sandboxPolicy.writableRoots 应限制为当前 cwd：%v", sandbox)
	}
}

func TestAppServerGatewaySanitizesParamsForAllAllowedMethods(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-sanitize")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	dangerousTail := `"permissions":{"sandbox":"workspace-write"},"runtimeWorkspaceRoots":["/tmp/other"],"dynamicTools":{"shell":true},"environments":{"SECRET":"token"},"config":{"feature":true},"outputSchema":{"type":"object"},"approvalsReviewer":"auto_review"`
	emptyParamFrames := []string{
		`{"id":60,"method":"initialize","params":{` + dangerousTail + `}}`,
		`{"method":"initialized","params":{` + dangerousTail + `}}`,
		`{"id":61,"method":"model/list","params":{` + dangerousTail + `}}`,
		`{"id":62,"method":"account/rateLimits/read","params":{` + dangerousTail + `}}`,
	}
	for _, frame := range emptyParamFrames {
		if err := conn.WriteMessage(websocket.TextMessage, []byte(frame)); err != nil {
			t.Fatal(err)
		}
		params := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
		assertGatewayParamsOnly(t, params)
	}

	initialize := []byte(`{"id":67,"method":"initialize","params":{"clientInfo":{"name":"mimi_remote","title":"Mimi Remote","version":"0.1.0","extra":"drop"},"capabilities":{"experimentalApi":true,"requestAttestation":false,"unknownFlag":true},` + dangerousTail + `}}`)
	if err := conn.WriteMessage(websocket.TextMessage, initialize); err != nil {
		t.Fatal(err)
	}
	initializeParams := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
	assertGatewayParamsOnly(t, initializeParams, "clientInfo", "capabilities")
	clientInfo, ok := initializeParams["clientInfo"].(map[string]any)
	if !ok {
		t.Fatalf("initialize 应保留 clientInfo：%v", initializeParams)
	}
	assertGatewayParamsOnly(t, clientInfo, "name", "title", "version")
	if clientInfo["name"] != "mimi_remote" || clientInfo["title"] != "Mimi Remote" || clientInfo["version"] != "0.1.0" {
		t.Fatalf("initialize clientInfo 内容异常：%v", clientInfo)
	}
	capabilities, ok := initializeParams["capabilities"].(map[string]any)
	if !ok {
		t.Fatalf("initialize 应保留安全 capabilities：%v", initializeParams)
	}
	assertGatewayParamsOnly(t, capabilities, "experimentalApi", "requestAttestation")
	if capabilities["experimentalApi"] != true || capabilities["requestAttestation"] != false {
		t.Fatalf("initialize capabilities 内容异常：%v", capabilities)
	}

	threadList := []byte(fmt.Sprintf(
		`{"id":63,"method":"thread/list","params":{"cwd":%q,"limit":20,"cursor":"next",%s}}`,
		projectDir,
		dangerousTail,
	))
	if err := conn.WriteMessage(websocket.TextMessage, threadList); err != nil {
		t.Fatal(err)
	}
	threadListParams := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
	assertGatewayParamsOnly(t, threadListParams, "cwd", "limit", "cursor")
	if threadListParams["cwd"] != projectDir || threadListParams["cursor"] != "next" {
		t.Fatalf("thread/list 合法参数应保留：%v", threadListParams)
	}
	_ = readGatewayRaw(t, conn)

	authorizeGatewayThread(t, conn, received, projectDir, "thread-sanitize")

	threadResume := []byte(fmt.Sprintf(
		`{"id":64,"method":"thread/resume","params":{"threadId":"thread-sanitize","cwd":%q,"excludeTurns":false,"sandbox":"custom","ephemeral":true,%s}}`,
		projectDir,
		dangerousTail,
	))
	if err := conn.WriteMessage(websocket.TextMessage, threadResume); err != nil {
		t.Fatal(err)
	}
	threadResumeParams := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
	assertGatewayParamsOnly(t, threadResumeParams, "cwd", "threadId", "excludeTurns", "approvalPolicy", "approvalsReviewer", "sandbox")
	if threadResumeParams["threadId"] != "thread-sanitize" ||
		threadResumeParams["cwd"] != projectDir ||
		threadResumeParams["excludeTurns"] != true ||
		threadResumeParams["approvalPolicy"] != "on-request" ||
		threadResumeParams["approvalsReviewer"] != "user" ||
		threadResumeParams["sandbox"] != "workspace-write" {
		t.Fatalf("thread/resume 合法参数和安全默认值异常：%v", threadResumeParams)
	}

	threadRead := []byte(`{"id":65,"method":"thread/read","params":{"threadId":"thread-sanitize","includeTurns":true,` + dangerousTail + `}}`)
	if err := conn.WriteMessage(websocket.TextMessage, threadRead); err != nil {
		t.Fatal(err)
	}
	threadReadParams := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
	assertGatewayParamsOnly(t, threadReadParams, "threadId", "includeTurns")
	if threadReadParams["threadId"] != "thread-sanitize" || threadReadParams["includeTurns"] != true {
		t.Fatalf("thread/read 合法参数应保留：%v", threadReadParams)
	}

	interrupt := []byte(`{"id":66,"method":"turn/interrupt","params":{"threadId":"thread-sanitize","turnId":"turn-1",` + dangerousTail + `}}`)
	if err := conn.WriteMessage(websocket.TextMessage, interrupt); err != nil {
		t.Fatal(err)
	}
	interruptParams := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
	assertGatewayParamsOnly(t, interruptParams, "threadId", "turnId")
	if interruptParams["threadId"] != "thread-sanitize" || interruptParams["turnId"] != "turn-1" {
		t.Fatalf("turn/interrupt 合法参数应保留：%v", interruptParams)
	}
}

func TestAppServerGatewayRewritesPermissionsApprovalResponse(t *testing.T) {
	var sentApprovalRequest atomic.Bool
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		if sentApprovalRequest.Swap(true) {
			return
		}
		request := []byte(`{"id":"perm-req","method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"perm-1","permissions":{"sandbox":"danger-full-access","networkAccess":true}}}`)
		if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
			t.Errorf("fake upstream 写 permissions request 失败：%v", err)
		}
	})
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	initialize := []byte(`{"id":1,"method":"initialize","params":{}}`)
	if err := conn.WriteMessage(websocket.TextMessage, initialize); err != nil {
		t.Fatal(err)
	}
	if got := readUpstreamFrame(t, received); !bytes.Equal(got, initialize) {
		t.Fatalf("initialize 应原样转发：got=%s want=%s", got, initialize)
	}
	if got := readGatewayRaw(t, conn); !bytes.Contains(got, []byte(`item/permissions/requestApproval`)) {
		t.Fatalf("gateway 应转发上游 permissions request：%s", got)
	}

	malicious := []byte(`{"id":"perm-req","result":{"permissions":{"sandbox":"danger-full-access","networkAccess":true},"scope":"forever","strictAutoReview":false}}`)
	if err := conn.WriteMessage(websocket.TextMessage, malicious); err != nil {
		t.Fatal(err)
	}
	got := readUpstreamFrame(t, received)
	params := decodeGatewayResultForTest(t, got)
	permissions, ok := params["permissions"].(map[string]any)
	if !ok || len(permissions) != 0 {
		t.Fatalf("permissions approval response 必须被改写为空权限：%s", got)
	}
	if params["scope"] != "turn" || params["strictAutoReview"] != true {
		t.Fatalf("permissions approval response 必须限制在当前 turn 且开启 strictAutoReview：%s", got)
	}
	if bytes.Contains(got, []byte("danger-full-access")) || bytes.Contains(got, []byte("networkAccess")) {
		t.Fatalf("permissions approval response 不应透传危险权限：%s", got)
	}
}

func TestAppServerGatewayServerRequestPendingUsesLongerTTLThanThreadResponses(t *testing.T) {
	oldThreadTTL := appServerGatewayPendingThreadTTL
	oldServerTTL := appServerGatewayPendingServerRequestTTL
	appServerGatewayPendingThreadTTL = time.Nanosecond
	appServerGatewayPendingServerRequestTTL = time.Minute
	t.Cleanup(func() {
		appServerGatewayPendingThreadTTL = oldThreadTTL
		appServerGatewayPendingServerRequestTTL = oldServerTTL
	})

	var sentApprovalRequest atomic.Bool
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		if sentApprovalRequest.Swap(true) {
			return
		}
		request := []byte(`{"id":"perm-long","method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"perm-long"}}`)
		if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
			t.Errorf("fake upstream 写 permissions request 失败：%v", err)
		}
	})
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	initialize := []byte(`{"id":1,"method":"initialize","params":{}}`)
	if err := conn.WriteMessage(websocket.TextMessage, initialize); err != nil {
		t.Fatal(err)
	}
	_ = readUpstreamFrame(t, received)
	_ = readGatewayRaw(t, conn)
	time.Sleep(5 * time.Millisecond)

	response := []byte(`{"id":"perm-long","result":{"permissions":{"sandbox":"danger-full-access"}}}`)
	if err := conn.WriteMessage(websocket.TextMessage, response); err != nil {
		t.Fatal(err)
	}
	got := readUpstreamFrame(t, received)
	if !bytes.Contains(got, []byte(`"scope":"turn"`)) {
		t.Fatalf("server request pending 不应被 thread TTL 清理：%s", got)
	}
}

func TestAppServerGatewayRejectsOverflowServerRequestBeforeForwardingToClient(t *testing.T) {
	oldMax := appServerGatewayPendingServerRequestMax
	appServerGatewayPendingServerRequestMax = 1
	t.Cleanup(func() {
		appServerGatewayPendingServerRequestMax = oldMax
	})

	var sentRequests atomic.Bool
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		if sentRequests.Swap(true) {
			return
		}
		first := []byte(`{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","itemId":"approval-1"}}`)
		second := []byte(`{"id":"approval-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","itemId":"approval-2"}}`)
		if err := conn.WriteMessage(websocket.TextMessage, first); err != nil {
			t.Errorf("fake upstream 写第一个 server request 失败：%v", err)
		}
		if err := conn.WriteMessage(websocket.TextMessage, second); err != nil {
			t.Errorf("fake upstream 写第二个 server request 失败：%v", err)
		}
	})
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	initialize := []byte(`{"id":1,"method":"initialize","params":{}}`)
	if err := conn.WriteMessage(websocket.TextMessage, initialize); err != nil {
		t.Fatal(err)
	}
	_ = readUpstreamFrame(t, received)
	firstRequest := readGatewayRaw(t, conn)
	if !bytes.Contains(firstRequest, []byte("approval-1")) {
		t.Fatalf("第一个 server request 应转发给客户端：%s", firstRequest)
	}
	upstreamError := readUpstreamFrame(t, received)
	if !bytes.Contains(upstreamError, []byte("approval-2")) || !bytes.Contains(upstreamError, []byte("pending server request")) {
		t.Fatalf("第二个 server request 应 fail-closed 回 upstream：%s", upstreamError)
	}
	_ = conn.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	if _, payload, err := conn.ReadMessage(); err == nil {
		t.Fatalf("pending 满的 server request 不应继续转发给客户端：%s", payload)
	}
}

func TestAppServerGatewayRejectsUnknownClientResponse(t *testing.T) {
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	unknownResponse := []byte(`{"id":"not-from-upstream","result":{"ok":true}}`)
	if err := conn.WriteMessage(websocket.TextMessage, unknownResponse); err != nil {
		t.Fatal(err)
	}
	errFrame := readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "response id") {
		t.Fatalf("未知 response id 错误文案异常：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayRejectsTooManyPendingThreadRequests(t *testing.T) {
	oldMax := appServerGatewayPendingThreadMax
	appServerGatewayPendingThreadMax = 2
	t.Cleanup(func() {
		appServerGatewayPendingThreadMax = oldMax
	})

	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	for id := 1; id <= 2; id++ {
		frame := []byte(fmt.Sprintf(`{"id":%d,"method":"thread/list","params":{"cwd":%q}}`, id, projectDir))
		if err := conn.WriteMessage(websocket.TextMessage, frame); err != nil {
			t.Fatal(err)
		}
		_ = readUpstreamFrame(t, received)
	}

	overflow := []byte(fmt.Sprintf(`{"id":3,"method":"thread/list","params":{"cwd":%q}}`, projectDir))
	if err := conn.WriteMessage(websocket.TextMessage, overflow); err != nil {
		t.Fatal(err)
	}
	errFrame := readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "pending thread") {
		t.Fatalf("pending 上限错误文案异常：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayRejectsOversizedClientFrameBeforeUpstream(t *testing.T) {
	oldLimit := appServerGatewayReadLimit
	appServerGatewayReadLimit = 128
	t.Cleanup(func() {
		appServerGatewayReadLimit = oldLimit
	})

	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	large := []byte(`{"id":1,"method":"model/list","params":{"padding":"` + strings.Repeat("x", 512) + `"}}`)
	if err := conn.WriteMessage(websocket.TextMessage, large); err != nil {
		t.Fatal(err)
	}
	assertNoUpstreamFrame(t, received)
	_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("超大 frame 后 gateway 应关闭连接")
	}
}

func TestAppServerGatewayForwardsModelList(t *testing.T) {
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	authorized := []byte(`{"id":41,"method":"model/list","params":{}}`)
	if err := conn.WriteMessage(websocket.TextMessage, authorized); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-received:
		if !bytes.Equal(got, authorized) {
			t.Fatalf("model/list 必须原样转发：got=%s want=%s", got, authorized)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到 model/list 帧")
	}
}

func TestAppServerGatewayForwardsStructuredUserInputUnchanged(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-structured")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	localImage := filepath.Join(projectDir, "screen.png")
	skillPath := filepath.Join(projectDir, "skills", "review.md")
	if err := os.MkdirAll(filepath.Dir(skillPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(localImage, []byte("png"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(skillPath, []byte("skill"), 0o600); err != nil {
		t.Fatal(err)
	}

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	authorizeGatewayThread(t, conn, received, projectDir, "thread-structured")

	authorized := []byte(fmt.Sprintf(
		`{"id":21,"method":"turn/start","params":{"threadId":"thread-structured","cwd":%q,"input":[{"type":"text","text":"看图并检查引用","text_elements":[]},{"type":"image","url":"data:image/png;base64,AA==","detail":"high"},{"type":"localImage","path":%q,"detail":"original"},{"type":"skill","name":"review","path":%q},{"type":"mention","name":"project","path":%q}],"model":"gpt-5-codex","effort":"high","serviceTier":"priority","approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		projectDir,
		localImage,
		skillPath,
		projectDir,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, authorized); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-received:
		if !bytes.Equal(got, authorized) {
			t.Fatalf("结构化 input 必须原样转发：got=%s want=%s", got, authorized)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到结构化 input 帧")
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
		`{"id":7,"method":"turn/start","params":{"threadId":"thread-1","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
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

func readUpstreamFrame(t *testing.T, received <-chan []byte) []byte {
	t.Helper()
	select {
	case payload := <-received:
		return payload
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到帧")
	}
	return nil
}

func decodeGatewayParamsForTest(t *testing.T, payload []byte) map[string]any {
	t.Helper()
	var frame struct {
		Params map[string]any `json:"params"`
	}
	if err := json.Unmarshal(payload, &frame); err != nil {
		t.Fatalf("gateway frame 不是合法 JSON：%v raw=%s", err, payload)
	}
	if frame.Params == nil {
		t.Fatalf("gateway frame 缺少 params：%s", payload)
	}
	return frame.Params
}

func decodeGatewayResultForTest(t *testing.T, payload []byte) map[string]any {
	t.Helper()
	var frame struct {
		Result map[string]any `json:"result"`
	}
	if err := json.Unmarshal(payload, &frame); err != nil {
		t.Fatalf("gateway frame 不是合法 JSON：%v raw=%s", err, payload)
	}
	if frame.Result == nil {
		t.Fatalf("gateway frame 缺少 result：%s", payload)
	}
	return frame.Result
}

func assertGatewayParamAbsent(t *testing.T, params map[string]any, keys ...string) {
	t.Helper()
	for _, key := range keys {
		if _, exists := params[key]; exists {
			t.Fatalf("gateway 不应透传参数 %s：%v", key, params)
		}
	}
}

func assertGatewayParamsOnly(t *testing.T, params map[string]any, allowedKeys ...string) {
	t.Helper()
	allowed := map[string]struct{}{}
	for _, key := range allowedKeys {
		allowed[key] = struct{}{}
	}
	for key := range params {
		if _, ok := allowed[key]; !ok {
			t.Fatalf("gateway method 参数白名单不应包含 %s：%v", key, params)
		}
	}
	for _, key := range allowedKeys {
		if _, ok := params[key]; !ok {
			t.Fatalf("gateway method 参数白名单应保留 %s：%v", key, params)
		}
	}
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
