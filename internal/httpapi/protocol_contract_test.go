package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/protocolcontract"
)

type clientCompatibilityFixture struct {
	Name                          string `json:"name"`
	ProtocolRevision              *int   `json:"protocol_revision"`
	MinimumServerProtocolRevision *int   `json:"minimum_server_protocol_revision"`
	ExpectedStatus                int    `json:"expected_status"`
	ExpectedCode                  string `json:"expected_code"`
}

func TestVersionResponseMatchesSharedCurrentGoldenFixture(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodGet, "/api/version", nil)
	req.Header.Set(protocolcontract.ClientRevisionHeader, "2")
	req.Header.Set(protocolcontract.MinimumServerRevisionHeader, "1")

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("当前客户端请求 /api/version 失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	var actual any
	if err := json.Unmarshal(rec.Body.Bytes(), &actual); err != nil {
		t.Fatalf("当前 /api/version 响应不是合法 JSON：%v", err)
	}
	var expected any
	if err := json.Unmarshal(readProtocolFixture(t, "version-current.json"), &expected); err != nil {
		t.Fatalf("当前 golden fixture 不是合法 JSON：%v", err)
	}
	actualJSON, _ := json.Marshal(actual)
	expectedJSON, _ := json.Marshal(expected)
	if string(actualJSON) != string(expectedJSON) {
		t.Fatalf("/api/version 与共享 golden fixture 漂移：\nactual=%s\nexpected=%s", actualJSON, expectedJSON)
	}
}

func TestCurrentAgentDRemainsDecodableByPreviousClient(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	// 上一版客户端没有协议 header；服务端必须按 revision 1 兼容窗口继续处理。
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/version", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("上一版客户端应继续可用：status=%d body=%s", rec.Code, rec.Body.String())
	}

	var legacy struct {
		Name           string   `json:"name"`
		Version        string   `json:"version"`
		InstallationID string   `json:"installation_id"`
		Capabilities   []string `json:"capabilities"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &legacy); err != nil {
		t.Fatalf("上一版客户端模型应忽略新增字段并成功解码：%v", err)
	}
	if legacy.Name != "agentd" || legacy.Version != "test" || legacy.InstallationID != testInstallationID {
		t.Fatalf("上一版客户端需要的字段发生漂移：%+v", legacy)
	}
}

func TestClientCompatibilityMatrixAgainstCurrentAgentD(t *testing.T) {
	var fixtures []clientCompatibilityFixture
	if err := json.Unmarshal(readProtocolFixture(t, "client-matrix.json"), &fixtures); err != nil {
		t.Fatalf("客户端兼容矩阵不是合法 JSON：%v", err)
	}

	for _, fixture := range fixtures {
		t.Run(fixture.Name, func(t *testing.T) {
			server := newTestServer(t)
			rec := httptest.NewRecorder()
			req := authedRequest(t, http.MethodGet, "/api/version", nil)
			if fixture.ProtocolRevision != nil {
				req.Header.Set(protocolcontract.ClientRevisionHeader, revisionString(*fixture.ProtocolRevision))
			}
			if fixture.MinimumServerProtocolRevision != nil {
				req.Header.Set(protocolcontract.MinimumServerRevisionHeader, revisionString(*fixture.MinimumServerProtocolRevision))
			}

			server.handler.ServeHTTP(rec, req)

			if rec.Code != fixture.ExpectedStatus {
				t.Fatalf("兼容矩阵状态不符：got=%d want=%d body=%s", rec.Code, fixture.ExpectedStatus, rec.Body.String())
			}
			if fixture.ExpectedCode == "" {
				return
			}
			var body protocolErrorResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("协议错误不是结构化 JSON：%v", err)
			}
			if body.Code != fixture.ExpectedCode || body.Error == "" {
				t.Fatalf("协议错误不可诊断：%+v", body)
			}
			if body.ServerProtocolRevision != protocolcontract.CurrentRevision ||
				body.MinimumClientProtocolRevision != protocolcontract.MinimumSupportedClientRevision {
				t.Fatalf("协议错误缺少服务端兼容窗口：%+v", body)
			}
		})
	}
}

func TestWebSocketHandshakeRejectsIncompatibleClientBeforeUpgrade(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodGet, "/api/app-server/ws", nil)
	req.Header.Set("Connection", "upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set(protocolcontract.ClientRevisionHeader, "3")
	req.Header.Set(protocolcontract.MinimumServerRevisionHeader, "3")

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUpgradeRequired {
		t.Fatalf("不兼容 WS 握手必须在 upgrade 前失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	var body protocolErrorResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("WS 协议错误不是结构化 JSON：%v", err)
	}
	if body.Code != "protocol_incompatible" || body.Error == "" {
		t.Fatalf("WS 协议错误不可诊断：%+v", body)
	}
}

func TestProtocolMetadataDoesNotBypassAuthentication(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/version", nil)
	req.Header.Set(protocolcontract.ClientRevisionHeader, "3")
	req.Header.Set(protocolcontract.MinimumServerRevisionHeader, "3")

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("未认证请求必须先被鉴权拒绝，实际 status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func readProtocolFixture(t *testing.T, name string) []byte {
	t.Helper()
	path := filepath.Join("..", "..", "contracts", "mimi-protocol", "fixtures", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取共享协议 fixture %s 失败：%v", name, err)
	}
	return data
}

func revisionString(value int) string {
	return fmt.Sprintf("%d", value)
}
