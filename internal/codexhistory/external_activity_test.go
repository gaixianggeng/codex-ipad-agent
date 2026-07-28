package codexhistory

import (
	"encoding/json"
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
	return `{"timestamp":"2026-07-28T14:00:01Z","type":"event_msg","payload":{"type":` +
		strconvQuote(eventType) + `,"turn_id":` + strconvQuote(turnID) + `}}`
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
