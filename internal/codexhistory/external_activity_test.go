package codexhistory

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestExternalActivityFiltersSourceAndProject(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	valid := fixture.writeRollout("valid", "Codex Desktop", fixture.projectDir,
		externalEventLine("task_started", "turn-valid"))
	legacyOrigin := fixture.writeRollout("cli", "codex_cli_rs", fixture.projectDir,
		externalEventLine("task_started", "turn-cli"))
	alternateOrigin := fixture.writeRollout("work-desktop", "codex_work_desktop", fixture.projectDir,
		externalEventLine("task_started", "turn-work"))
	outsideDir := t.TempDir()
	outside := fixture.writeRollout("outside", "Codex Desktop", outsideDir,
		externalEventLine("task_started", "turn-outside"))

	fixture.rows = []externalActivityTestRow{
		{ID: "valid", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: valid},
		{ID: "cli", CWD: fixture.projectDir, Source: "cli", ThreadSource: "user", RolloutPath: legacyOrigin},
		{ID: "work-desktop", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: alternateOrigin},
		{ID: "outside", CWD: outsideDir, Source: "vscode", ThreadSource: "user", RolloutPath: outside},
		{ID: "subagent", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "subagent", RolloutPath: valid},
		{ID: "unsupported", CWD: fixture.projectDir, Source: "exec", ThreadSource: "user", RolloutPath: valid},
	}

	activities, err := fixture.tracker.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(activities) != 2 || activities[0].ProjectID != "demo" || activities[1].ProjectID != "demo" {
		t.Fatalf("只应返回白名单项目的 Codex Desktop 顶层线程：%+v", activities)
	}
	ids := map[string]bool{}
	for _, activity := range activities {
		ids[activity.ThreadID] = true
		if activity.Source != "codex_desktop" || activity.State != "running" || activity.Revision == "" {
			t.Fatalf("外部活动字段异常：%+v", activity)
		}
	}
	if !ids["valid"] || !ids["work-desktop"] {
		t.Fatalf("缺少合法 Desktop 来源：%+v", activities)
	}
}

func TestExternalActivityTracksStartCompleteAndAbortIncrementally(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
		externalEventLine("task_started", "turn-1"))
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	first := fixture.snapshot(t)
	if len(first) != 1 || first[0].TurnID != "turn-1" {
		t.Fatalf("task_started 应进入活动态：%+v", first)
	}
	firstRevision := first[0].Revision

	fixture.appendLine(path, externalEventLine("task_complete", "turn-1"))
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("task_complete 应退出活动态：%+v", got)
	}

	fixture.appendLine(path, externalEventLine("task_started", "turn-2"))
	second := fixture.snapshot(t)
	if len(second) != 1 || second[0].TurnID != "turn-2" || second[0].Revision == firstRevision {
		t.Fatalf("追加的新 turn 应增量解析并更新 revision：%+v", second)
	}
	// 旧 turn 的迟到 terminal 不能终止新 turn。
	fixture.appendLine(path, externalEventLine("task_complete", "turn-1"))
	if got := fixture.snapshot(t); len(got) != 1 || got[0].TurnID != "turn-2" {
		t.Fatalf("迟到 terminal 不应终止当前 turn：%+v", got)
	}
	fixture.appendLine(path, externalEventLine("turn_aborted", "turn-2"))
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("turn_aborted 应退出活动态：%+v", got)
	}
}

func TestExternalActivitySkipsMalformedJSONLAndReusesCache(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
		"{broken-json",
		externalEventLine("task_started", "turn-1"))
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 1 {
		t.Fatalf("损坏行不应阻断后续 lifecycle：%+v", got)
	}
	before := fixture.tracker.Diagnostics()
	if got := fixture.snapshot(t); len(got) != 1 {
		t.Fatalf("缓存复用后活动态不应变化：%+v", got)
	}
	after := fixture.tracker.Diagnostics()
	if after.CandidateQueries != before.CandidateQueries ||
		after.FileScans != before.FileScans ||
		after.CacheHits <= before.CacheHits ||
		after.MalformedLines != 1 {
		t.Fatalf("未变化的 DB/rollout 应复用缓存：before=%+v after=%+v", before, after)
	}
}

func TestExternalActivityExpiresAndLaterWritesReactivate(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 28, 15, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
		externalEventLine("task_started", "turn-1"))
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}
	old := now.Add(-31 * time.Minute)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("30 分钟无更新应降为非活动：%+v", got)
	}

	fixture.appendLine(path, `{"timestamp":"2026-07-28T14:30:01Z","type":"event_msg","payload":{"type":"agent_message"}}`)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	if got := fixture.snapshot(t); len(got) != 1 || got[0].TurnID != "turn-1" {
		t.Fatalf("仍在运行的旧 turn 后续写入应重新激活：%+v", got)
	}
}

func TestExternalActivityWithoutStateDatabaseReturnsEmpty(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	if err := os.Remove(fixture.db); err != nil {
		t.Fatal(err)
	}

	activities, err := fixture.tracker.Snapshot()
	if err != nil {
		t.Fatalf("尚未创建 Codex 状态库时不应让活动接口失败：%v", err)
	}
	if len(activities) != 0 {
		t.Fatalf("没有状态库时应返回空活动：%+v", activities)
	}
}

func TestExternalActivityExcludesExactGatewayOwnedTurn(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-ipad", "client-ipad")
	path := fixture.writeRollout("thread-ipad", "Codex Desktop", fixture.projectDir,
		externalEventLineAt(now.Add(100*time.Millisecond), "task_started", "turn-ipad"),
		externalUserMessageLine(now.Add(500*time.Millisecond), "client-ipad"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-ipad", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("同线程、同 client_id 且时间相符的 gateway turn 不应被识别为 Desktop 外部活动：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if !entry.active || !entry.gatewayOwned || entry.turnID != "turn-ipad" {
		t.Fatalf("rollout 应保留运行态并标记 gateway 归属：%+v", entry)
	}
}

func TestExternalActivityAlsoSupportsUserMessageBeforeTaskStarted(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-ipad", "client-ipad")
	path := fixture.writeRollout("thread-ipad", "Codex Desktop", fixture.projectDir,
		externalUserMessageLine(now.Add(100*time.Millisecond), "client-ipad"),
		externalEventLineAt(now.Add(500*time.Millisecond), "task_started", "turn-ipad"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-ipad", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("user_message 先落盘时也应把紧随其后的 task_started 识别为 gateway turn：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if !entry.active || !entry.gatewayOwned || entry.turnID != "turn-ipad" {
		t.Fatalf("反向落盘顺序也应保留 gateway 归属：%+v", entry)
	}
}

func TestExternalActivityExpiredPendingEvidenceCannotHideLaterDesktopTurn(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-1", "client-ipad")
	path := fixture.writeRollout(
		"thread-1",
		"Codex Desktop",
		fixture.projectDir,
		externalUserMessageLine(now.Add(100*time.Millisecond), "client-ipad"),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("只有 user_message、尚未开始 turn 时不应产生外部活动：%+v", got)
	}
	if !fixture.tracker.files[path].gatewayTurnPending {
		t.Fatal("反向落盘顺序应暂存带时间界限的 gateway 证据")
	}

	now = now.Add(gatewayTurnLifecycleWindow + time.Second)
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("pending 过期时仍没有 active turn，不应产生外部活动：%+v", got)
	}
	if fixture.tracker.files[path].gatewayTurnPending {
		t.Fatal("超过生命周期关联窗口后，pending gateway 证据必须主动失效")
	}

	now = now.Add(gatewayTurnRegistrationTTL + time.Second)
	fixture.appendLine(path, externalEventLineAt(now, "task_started", "turn-desktop"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-desktop" {
		t.Fatalf("过期 pending 证据不能隐藏稍后的 Desktop turn：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if entry.gatewayOwned || entry.gatewayTurnPending {
		t.Fatalf("Desktop turn 不应继承过期 gateway 证据：%+v", entry)
	}
}

func TestExternalActivityMatchingUserMessageCannotClaimOlderActiveDesktopTurn(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-1", "client-ipad")
	path := fixture.writeRollout(
		"thread-1",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(now.Add(-time.Minute), "task_started", "turn-desktop"),
		externalUserMessageLine(now.Add(100*time.Millisecond), "client-ipad"),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-desktop" {
		t.Fatalf("匹配消息不能把 registration 之前已运行的 Desktop turn 改写为 gateway 所有：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if entry.gatewayOwned || entry.gatewayTurnPending {
		t.Fatalf("旧 Desktop turn 不应吸收新 gateway 消息证据：%+v", entry)
	}
}

func TestExternalActivityGatewayOwnershipRequiresExactEvidence(t *testing.T) {
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	tests := []struct {
		name             string
		registeredThread string
		registeredClient string
		eventClient      string
		eventAt          time.Time
	}{
		{
			name:             "wrong client id",
			registeredThread: "thread-1",
			registeredClient: "client-ipad",
			eventClient:      "client-desktop",
			eventAt:          now.Add(time.Second),
		},
		{
			name:             "wrong thread",
			registeredThread: "thread-other",
			registeredClient: "client-ipad",
			eventClient:      "client-ipad",
			eventAt:          now.Add(time.Second),
		},
		{
			name:             "old rollout timestamp",
			registeredThread: "thread-1",
			registeredClient: "client-ipad",
			eventClient:      "client-ipad",
			eventAt:          now.Add(-gatewayTurnRegistrationTTL),
		},
		{
			name:             "missing client id",
			registeredThread: "thread-1",
			registeredClient: "client-ipad",
			eventClient:      "",
			eventAt:          now.Add(time.Second),
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fixture := newExternalActivityTrackerFixture(t)
			fixture.tracker.now = func() time.Time { return now }
			fixture.tracker.RegisterGatewayTurnStart(tc.registeredThread, tc.registeredClient)
			path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
				externalUserMessageLine(tc.eventAt, tc.eventClient),
				externalEventLine("task_started", "turn-desktop"))
			if err := os.Chtimes(path, now, now); err != nil {
				t.Fatal(err)
			}
			fixture.rows = []externalActivityTestRow{{
				ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
			}}

			got := fixture.snapshot(t)
			if len(got) != 1 || got[0].ThreadID != "thread-1" || got[0].TurnID != "turn-desktop" {
				t.Fatalf("证据不完整时必须 fail-safe 保留 Desktop 外部活动：%+v", got)
			}
		})
	}
}

func TestExternalActivityNewDesktopTurnResetsGatewayOwnership(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-1", "client-ipad")
	path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
		externalUserMessageLine(now.Add(100*time.Millisecond), "client-ipad"),
		externalEventLineAt(now.Add(500*time.Millisecond), "task_started", "turn-ipad"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("第一轮 iPad turn 不应显示为外部活动：%+v", got)
	}

	// 后续没有匹配 user_message 的新 task_started 是真正的 Desktop turn，
	// 必须覆盖上一轮 gateway 归属，重新进入“仅观察”保护。
	fixture.appendLine(path, externalEventLineAt(now.Add(time.Second), "task_started", "turn-desktop"))
	if err := os.Chtimes(path, now.Add(time.Second), now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-desktop" {
		t.Fatalf("新的 Desktop task_started 应恢复外部活动：%+v", got)
	}

	fixture.appendLine(path, externalEventLineAt(now.Add(2*time.Second), "task_complete", "turn-desktop"))
	if err := os.Chtimes(path, now.Add(2*time.Second), now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("terminal 应清除活动与归属状态：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if entry.active || entry.gatewayOwned || entry.gatewayTurnPending {
		t.Fatalf("terminal 后不应残留 gateway 状态：%+v", entry)
	}
}

func TestGatewayTurnRegistrationsAreBoundedAndExpire(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	for index := 0; index < gatewayTurnRegistrationLimit+7; index++ {
		fixture.tracker.RegisterGatewayTurnStart("thread-1", fmt.Sprintf("client-%d", index))
		now = now.Add(time.Microsecond)
	}
	if got := len(fixture.tracker.gatewayTurns); got != gatewayTurnRegistrationLimit {
		t.Fatalf("gateway 登记表必须有容量上限：got=%d want=%d", got, gatewayTurnRegistrationLimit)
	}

	now = now.Add(gatewayTurnRegistrationTTL + time.Second)
	fixture.tracker.RegisterGatewayTurnStart("thread-fresh", "client-fresh")
	if got := len(fixture.tracker.gatewayTurns); got != 1 {
		t.Fatalf("过期 gateway 登记应在新写入时被裁剪：got=%d entries=%+v", got, fixture.tracker.gatewayTurns)
	}
	if _, ok := fixture.tracker.gatewayTurns[gatewayTurnRegistrationKey("thread-fresh", "client-fresh")]; !ok {
		t.Fatal("最新 gateway 登记不应被裁剪")
	}
}

type externalActivityTestRow struct {
	ID           string `json:"id"`
	CWD          string `json:"cwd"`
	Source       string `json:"source"`
	ThreadSource string `json:"thread_source"`
	RolloutPath  string `json:"rollout_path"`
}

type externalActivityTrackerFixture struct {
	t          *testing.T
	projectDir string
	db         string
	tracker    *ExternalActivityTracker
	rows       []externalActivityTestRow
}

func newExternalActivityTrackerFixture(t *testing.T) *externalActivityTrackerFixture {
	t.Helper()
	projectDir := filepath.Join(t.TempDir(), "project")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{{
		ID: "demo", Name: "Demo", Path: projectDir,
	}})
	if err != nil {
		t.Fatal(err)
	}
	db := filepath.Join(t.TempDir(), "state_5.sqlite")
	if err := os.WriteFile(db, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	fixture := &externalActivityTrackerFixture{
		t:          t,
		projectDir: projectDir,
		db:         db,
		tracker:    NewExternalActivityTracker(db, registry),
	}
	fixture.tracker.query = func(_ string, query string) ([]byte, error) {
		if strings.Contains(query, "pragma_table_info") {
			return []byte(`[
				{"table_name":"threads","name":"id"},
				{"table_name":"threads","name":"cwd"},
				{"table_name":"threads","name":"source"},
				{"table_name":"threads","name":"thread_source"},
				{"table_name":"threads","name":"rollout_path"},
				{"table_name":"threads","name":"updated_at_ms"},
				{"table_name":"threads","name":"archived"},
				{"table_name":"thread_spawn_edges","name":"child_thread_id"}
			]`), nil
		}
		return json.Marshal(fixture.rows)
	}
	return fixture
}

func (f *externalActivityTrackerFixture) writeRollout(threadID, originator, cwd string, lines ...string) string {
	f.t.Helper()
	path := filepath.Join(f.t.TempDir(), threadID+".jsonl")
	meta := `{"timestamp":"2026-07-28T14:00:00Z","type":"session_meta","payload":{"id":` +
		mustJSONQuote(f.t, threadID) + `,"cwd":` + mustJSONQuote(f.t, cwd) +
		`,"originator":` + mustJSONQuote(f.t, originator) + `,"thread_source":"user"}}`
	all := append([]string{meta}, lines...)
	if err := os.WriteFile(path, []byte(strings.Join(all, "\n")+"\n"), 0o600); err != nil {
		f.t.Fatal(err)
	}
	return path
}

func (f *externalActivityTrackerFixture) appendLine(path, line string) {
	f.t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		f.t.Fatal(err)
	}
	if _, err := file.WriteString(line + "\n"); err != nil {
		file.Close()
		f.t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		f.t.Fatal(err)
	}
}

func (f *externalActivityTrackerFixture) snapshot(t *testing.T) []ExternalActivity {
	t.Helper()
	activities, err := f.tracker.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	return activities
}

func externalEventLine(eventType, turnID string) string {
	return externalEventLineAt(
		time.Date(2026, 7, 28, 14, 0, 1, 0, time.UTC),
		eventType,
		turnID,
	)
}

func externalEventLineAt(timestamp time.Time, eventType, turnID string) string {
	return `{"timestamp":` + strconvQuote(timestamp.UTC().Format(time.RFC3339Nano)) +
		`,"type":"event_msg","payload":{"type":` +
		strconvQuote(eventType) + `,"turn_id":` + strconvQuote(turnID) + `}}`
}

func externalUserMessageLine(timestamp time.Time, clientID string) string {
	payload := map[string]any{"type": "user_message"}
	if strings.TrimSpace(clientID) != "" {
		payload["client_id"] = clientID
	}
	record := map[string]any{
		"timestamp": timestamp.UTC().Format(time.RFC3339Nano),
		"type":      "event_msg",
		"payload":   payload,
	}
	data, _ := json.Marshal(record)
	return string(data)
}

func mustJSONQuote(t *testing.T, value string) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func strconvQuote(value string) string {
	data, _ := json.Marshal(value)
	return string(data)
}
