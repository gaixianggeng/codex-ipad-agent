package httpapi

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
)

type stubExternalActivitySource struct {
	activities []codexhistory.ExternalActivity
	err        error
}

func (s stubExternalActivitySource) Snapshot() ([]codexhistory.ExternalActivity, error) {
	return s.activities, s.err
}

func TestExternalActivityRequiresAuthAndReturnsSanitizedSnapshot(t *testing.T) {
	handler, router := appServerGatewayRouterFixtureWithRouter(t, "", nil)
	router.externalActivity = stubExternalActivitySource{activities: []codexhistory.ExternalActivity{{
		ThreadID:     "thread-1",
		ProjectID:    "demo",
		Source:       "codex_desktop",
		State:        "running",
		TurnID:       "turn-1",
		Revision:     "revision-1",
		LastActivity: time.Date(2026, 7, 28, 14, 0, 0, 0, time.UTC),
	}}}

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/app-server/external-activity", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("external activity 必须要求 Bearer Token，got=%d", unauthorized.Code)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/external-activity", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("external activity 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	activities, ok := body["activities"].([]any)
	if !ok || len(activities) != 1 {
		t.Fatalf("活动响应异常：%v", body)
	}
	activity := activities[0].(map[string]any)
	allowed := map[string]bool{
		"thread_id": true, "project_id": true, "source": true, "state": true,
		"turn_id": true, "revision": true, "last_activity_at": true,
	}
	for key := range activity {
		if !allowed[key] {
			t.Fatalf("活动响应包含非白名单字段 %q：%v", key, activity)
		}
	}
	text := rec.Body.String()
	if strings.Contains(text, "rollout") || strings.Contains(text, "\"cwd\"") || strings.Contains(text, "\"path\"") {
		t.Fatalf("活动响应不应泄漏本机路径：%s", text)
	}
}

func TestExternalActivityFailureIsRedacted(t *testing.T) {
	handler, router := appServerGatewayRouterFixtureWithRouter(t, "", nil)
	router.externalActivity = stubExternalActivitySource{err: errors.New("/Users/private/.codex/state_5.sqlite: locked")}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/external-activity", nil))
	if rec.Code != http.StatusServiceUnavailable || strings.Contains(rec.Body.String(), "/Users/private") {
		t.Fatalf("错误响应应脱敏：code=%d body=%s", rec.Code, rec.Body.String())
	}
}
