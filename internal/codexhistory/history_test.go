package codexhistory

import (
	"os"
	"strings"
	"testing"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
)

func TestMessagesFromReaderHandlesHugeJSONLLine(t *testing.T) {
	var builder strings.Builder
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":"`)
	builder.WriteString(strings.Repeat("x", 9*1024*1024))
	builder.WriteString(`"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"hello from history"}}` + "\n")

	// 大型 Codex rollout 常见于工具输出或图片上下文；解析器应跳过这些非消息行，而不是让整段历史为空。
	messages, err := messagesFromReader(strings.NewReader(builder.String()), 0)
	if err != nil {
		t.Fatalf("大行 JSONL 不应导致历史读取失败：%v", err)
	}
	if len(messages) != 2 {
		t.Fatalf("期望解析出 2 条消息，实际 %d：%+v", len(messages), messages)
	}
	if messages[0].Role != "user" || messages[0].Content != "hi" {
		t.Fatalf("第一条消息异常：%+v", messages[0])
	}
	if messages[1].Role != "assistant" || messages[1].Content != "hello from history" {
		t.Fatalf("第二条消息异常：%+v", messages[1])
	}
}

func TestMessagesFromReaderReturnsLatestLimitedMessages(t *testing.T) {
	input := strings.Join([]string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}`,
		`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"three"}}`,
		"",
	}, "\n")

	messages, err := messagesFromReader(strings.NewReader(input), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("期望只保留最近 2 条消息，实际 %d：%+v", len(messages), messages)
	}
	if messages[0].Content != "two" || messages[1].Content != "three" {
		t.Fatalf("limit 应返回最新消息窗口：%+v", messages)
	}
}

func TestMessagesFromTailSkipsHugeTrailingRecords(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "rollout-*.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	var builder strings.Builder
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":"`)
	builder.WriteString(strings.Repeat("x", tailReadChunkSize+1024))
	builder.WriteString(`"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"three"}}`)
	if _, err := file.WriteString(builder.String()); err != nil {
		t.Fatal(err)
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}

	// limit 模式从文件尾部倒读，遇到跨 chunk 的大行也应跳过并继续向前找最近消息。
	messages, err := messagesFromTail(file, info.Size(), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("期望倒读出最近 2 条消息，实际 %d：%+v", len(messages), messages)
	}
	if messages[0].Content != "two" || messages[1].Content != "three" {
		t.Fatalf("倒读 limit 应返回最新消息窗口：%+v", messages)
	}
}

func TestRowsToSessionsFiltersSubagentThreads(t *testing.T) {
	dir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}})
	if err != nil {
		t.Fatal(err)
	}

	rows := []row{
		{ID: "main", Title: "主会话", CWD: dir, Source: "vscode", ThreadSource: "user"},
		{ID: "child_thread_source", Title: "子会话", CWD: dir, Source: "vscode", ThreadSource: "subagent"},
		{ID: "child_json_source", Title: "旧格式子会话", CWD: dir, Source: `{"subagent":{"thread_spawn":{"parent_thread_id":"main"}}}`},
	}

	// 子 Agent 仍会写入 Codex threads 表；iPad 侧栏应只展示和 Codex 主界面一致的顶层会话。
	childThreadIDs := map[string]bool{"child_edge": true}
	rows = append(rows, row{ID: "child_edge", Title: "edge 子会话", CWD: dir, Source: "vscode"})
	sessions, diagnostics := rowsToSessions(rows, registry, nil, "demo", childThreadIDs)
	if len(sessions) != 1 {
		t.Fatalf("期望只保留 1 条顶层会话，实际 %d：%+v", len(sessions), sessions)
	}
	if sessions[0].ID != "codex_main" {
		t.Fatalf("顶层会话 ID 异常：%+v", sessions[0])
	}

	reasons := map[string]string{}
	for _, item := range diagnostics {
		reasons[item.ThreadID] = item.Reason
	}
	if reasons["child_thread_source"] != "subagent" || reasons["child_json_source"] != "subagent" || reasons["child_edge"] != "subagent" {
		t.Fatalf("子会话诊断原因异常：%+v", reasons)
	}
}

func TestRowsToSessionsFiltersNonInteractiveSources(t *testing.T) {
	dir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}})
	if err != nil {
		t.Fatal(err)
	}

	rows := []row{
		{ID: "cli", Title: "CLI 会话", CWD: dir, Source: "cli"},
		{ID: "vscode", Title: "VS Code 会话", CWD: dir, Source: "vscode"},
		{ID: "atlas", Title: "Atlas 会话", CWD: dir, Source: `{"custom":"atlas"}`},
		{ID: "exec", Title: "Exec 后台任务", CWD: dir, Source: "exec"},
	}
	sessions, diagnostics := rowsToSessions(rows, registry, nil, "demo", nil)
	if len(sessions) != 3 {
		t.Fatalf("期望只保留交互来源会话，实际 %d：%+v", len(sessions), sessions)
	}

	reasons := map[string]string{}
	for _, item := range diagnostics {
		reasons[item.ThreadID] = item.Reason
	}
	if reasons["exec"] != "unsupported_source" {
		t.Fatalf("exec 来源应被排除，诊断原因异常：%+v", reasons)
	}
}
