package codexhistory

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

type row struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	CWD          string `json:"cwd"`
	Source       string `json:"source"`
	ThreadSource string `json:"thread_source"`
	Preview      string `json:"preview"`
	CreatedAtMS  int64  `json:"created_at_ms"`
	UpdatedAtMS  int64  `json:"updated_at_ms"`
}

type Message struct {
	Role      string    `json:"role"`
	Content   string    `json:"content"`
	CreatedAt time.Time `json:"created_at"`
}

type Diagnostics struct {
	Home           string          `json:"home"`
	DatabasePath   string          `json:"database_path"`
	DatabaseExists bool            `json:"database_exists"`
	QueryMode      string          `json:"query_mode"`
	QueryLimit     int             `json:"query_limit"`
	Project        *ProjectDebug   `json:"project,omitempty"`
	Counts         map[string]int  `json:"counts"`
	Rows           []DiagnosticRow `json:"rows"`
	Error          string          `json:"error,omitempty"`
}

type ProjectDebug struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Path     string `json:"path"`
	RealPath string `json:"real_path"`
}

type DiagnosticRow struct {
	ThreadID         string    `json:"thread_id"`
	Title            string    `json:"title"`
	CWD              string    `json:"cwd"`
	MatchedProjectID string    `json:"matched_project_id,omitempty"`
	Included         bool      `json:"included"`
	Reason           string    `json:"reason"`
	UpdatedAt        time.Time `json:"updated_at"`
}

var homeDirFunc = os.UserHomeDir

const (
	defaultQueryLimit = 300
	maxQueryLimit     = 2000
	maxMessageCaches  = 32
	tailReadChunkSize = 512 * 1024
)

type messageCacheEntry struct {
	size     int64
	modTime  time.Time
	limit    int
	complete bool
	messages []Message
}

var messageCache = struct {
	sync.Mutex
	items map[string]messageCacheEntry
}{items: map[string]messageCacheEntry{}}

func Load(registry *projects.Registry, active []*session.Session) []session.Session {
	sessions, _ := load(registry, active, "", defaultQueryLimit)
	return sessions
}

func LoadForProject(registry *projects.Registry, active []*session.Session, projectID string, limit int) []session.Session {
	sessions, _ := load(registry, active, projectID, limit)
	return sessions
}

func Diagnose(registry *projects.Registry, active []*session.Session, projectID string, limit int) Diagnostics {
	limit = normalizeQueryLimit(limit)
	home := homeDir()
	db := filepath.Join(home, ".codex", "state_5.sqlite")
	result := Diagnostics{
		Home:         home,
		DatabasePath: db,
		QueryMode:    "global",
		QueryLimit:   limit,
		Counts:       map[string]int{},
	}
	if _, err := os.Stat(db); err != nil {
		result.Error = err.Error()
		return result
	}
	result.DatabaseExists = true

	var projectFilter *projects.Project
	if projectID != "" {
		project, ok := registry.Get(projectID)
		if !ok {
			result.Error = "项目不存在"
			return result
		}
		projectFilter = &project
		result.QueryMode = "project_path"
		result.Project = &ProjectDebug{ID: project.ID, Name: project.Name, Path: project.Path, RealPath: project.RealPath}
	}

	rows, err := queryRows(db, projectFilter, limit, true)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	seen := activeThreadIDs(active)
	childThreadIDs, err := childThreadIDs(db)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	_, diagnostics := rowsToSessions(rows, registry, seen, projectID, childThreadIDs)
	result.Rows = diagnostics
	for _, item := range diagnostics {
		result.Counts["scanned"]++
		if item.Included {
			result.Counts["included"]++
		} else {
			result.Counts[item.Reason]++
		}
	}
	return result
}

func load(registry *projects.Registry, active []*session.Session, projectID string, limit int) ([]session.Session, error) {
	db := filepath.Join(homeDir(), ".codex", "state_5.sqlite")
	if _, err := os.Stat(db); err != nil {
		return nil, err
	}

	var projectFilter *projects.Project
	if projectID != "" {
		project, ok := registry.Get(projectID)
		if !ok {
			return nil, os.ErrNotExist
		}
		projectFilter = &project
	}

	rows, err := queryRows(db, projectFilter, normalizeQueryLimit(limit), false)
	if err != nil {
		return nil, err
	}
	childThreadIDs, err := childThreadIDs(db)
	if err != nil {
		return nil, err
	}
	sessions, _ := rowsToSessions(rows, registry, activeThreadIDs(active), projectID, childThreadIDs)
	return sessions, nil
}

func activeThreadIDs(active []*session.Session) map[string]bool {
	seen := map[string]bool{}
	for _, s := range active {
		if s.ResumeID != "" {
			seen[s.ResumeID] = true
		}
		if strings.HasPrefix(s.ID, "codex_") {
			seen[strings.TrimPrefix(s.ID, "codex_")] = true
		}
	}
	return seen
}

func rowsToSessions(rows []row, registry *projects.Registry, seen map[string]bool, projectID string, childThreadIDs map[string]bool) ([]session.Session, []DiagnosticRow) {
	var sessions []session.Session
	var diagnostics []DiagnosticRow
	for _, item := range rows {
		diagnostic := DiagnosticRow{
			ThreadID:  item.ID,
			Title:     item.Title,
			CWD:       item.CWD,
			Reason:    "included",
			UpdatedAt: msTime(item.UpdatedAtMS),
		}
		if item.ID == "" || seen[item.ID] {
			diagnostic.Reason = "active_session"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		if isSubagentThread(item, childThreadIDs) {
			diagnostic.Reason = "subagent"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		if !isInteractiveSource(item.Source) {
			diagnostic.Reason = "unsupported_source"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		project, ok := registry.FindByPath(item.CWD)
		if !ok {
			diagnostic.Reason = "no_matching_project"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		diagnostic.MatchedProjectID = project.ID
		if projectID != "" && project.ID != projectID {
			diagnostic.Reason = "other_project"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		title := strings.TrimSpace(item.Title)
		if title == "" {
			title = strings.TrimSpace(item.Preview)
		}
		if title == "" {
			title = "Codex 历史会话"
		}
		sessions = append(sessions, session.Session{
			ID:        "codex_" + item.ID,
			ProjectID: project.ID,
			Project:   project.Name,
			Dir:       project.Path,
			Title:     trimRunes(title, 48),
			Status:    "history",
			Source:    "codex",
			ResumeID:  item.ID,
			CreatedAt: msTime(item.CreatedAtMS),
			UpdatedAt: msTime(item.UpdatedAtMS),
		})
		diagnostic.Included = true
		diagnostics = append(diagnostics, diagnostic)
	}
	return sessions, diagnostics
}

func queryRows(db string, project *projects.Project, limit int, includeSubagents bool) ([]row, error) {
	columns, err := tableColumns(db, "threads")
	if err != nil {
		return nil, err
	}
	edgeColumns, err := tableColumns(db, "thread_spawn_edges")
	if err != nil {
		return nil, err
	}
	where := "archived=0"
	if !includeSubagents {
		where += " and " + topLevelHistoryPredicate(columns, edgeColumns)
	}
	if project != nil {
		where += " and (" + pathPredicate(project.Path)
		if project.RealPath != "" && project.RealPath != project.Path {
			where += " or " + pathPredicate(project.RealPath)
		}
		where += ")"
	}
	sourceExpr := optionalColumnExpr(columns, "source")
	threadSourceExpr := optionalColumnExpr(columns, "thread_source")
	previewExpr := optionalColumnExpr(columns, "preview")
	sql := "select id,title,cwd," + sourceExpr + "," + threadSourceExpr + "," + previewExpr + ",created_at_ms,updated_at_ms from threads where " + where + " order by updated_at_ms desc limit " + strconv.Itoa(limit)
	out, err := exec.Command("sqlite3", "-json", db, sql).Output()
	if err != nil {
		return nil, err
	}
	var rows []row
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

func childThreadIDs(db string) (map[string]bool, error) {
	columns, err := tableColumns(db, "thread_spawn_edges")
	if err != nil {
		return nil, err
	}
	ids := map[string]bool{}
	if !columns["child_thread_id"] {
		return ids, nil
	}
	out, err := exec.Command("sqlite3", "-json", db, "select child_thread_id from thread_spawn_edges").Output()
	if err != nil {
		return nil, err
	}
	var rows []struct {
		ChildThreadID string `json:"child_thread_id"`
	}
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, err
	}
	for _, item := range rows {
		if item.ChildThreadID != "" {
			ids[item.ChildThreadID] = true
		}
	}
	return ids, nil
}

func tableColumns(db string, table string) (map[string]bool, error) {
	out, err := exec.Command("sqlite3", "-json", db, "pragma table_info("+sqlQuoteIdentifier(table)+")").Output()
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(out)) == 0 {
		return map[string]bool{}, nil
	}
	var rows []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, err
	}
	columns := make(map[string]bool, len(rows))
	for _, item := range rows {
		columns[item.Name] = true
	}
	return columns, nil
}

func optionalColumnExpr(columns map[string]bool, name string) string {
	if columns[name] {
		return name
	}
	return "'' as " + name
}

func topLevelHistoryPredicate(columns map[string]bool, edgeColumns map[string]bool) string {
	return "(" + strings.Join([]string{
		displayableThreadPredicate(columns),
		interactiveSourcePredicate(columns),
		nonSubagentPredicate(columns, edgeColumns),
	}, " and ") + ")"
}

func displayableThreadPredicate(columns map[string]bool) string {
	if columns["preview"] {
		return "coalesce(preview, '') != ''"
	}
	if columns["title"] {
		return "coalesce(title, '') != ''"
	}
	return "1=1"
}

func interactiveSourcePredicate(columns map[string]bool) string {
	if !columns["source"] {
		return "1=1"
	}
	// Codex 的 thread/list 默认只展示交互入口：cli、vscode、atlas、chatgpt。
	return "(source in ('cli', 'vscode', '{\"custom\":\"atlas\"}', '{\"custom\":\"chatgpt\"}'))"
}

func nonSubagentPredicate(columns map[string]bool, edgeColumns map[string]bool) string {
	// Codex 的子 Agent 会话会进入同一个 threads 表，但 Codex 主界面默认不把它们当成顶层会话展示。
	var parts []string
	if edgeColumns["child_thread_id"] {
		parts = append(parts, "not exists (select 1 from thread_spawn_edges e where e.child_thread_id = threads.id)")
	}
	if columns["thread_source"] {
		parts = append(parts, "coalesce(thread_source, '') != 'subagent'")
	}
	if columns["source"] {
		parts = append(parts, "coalesce(source, '') != 'subagent'", "instr(coalesce(source, ''), '\"subagent\"') = 0")
	}
	if len(parts) == 0 {
		return "1=1"
	}
	return "(" + strings.Join(parts, " and ") + ")"
}

func isSubagentThread(item row, childThreadIDs map[string]bool) bool {
	if childThreadIDs[item.ID] {
		return true
	}
	if strings.EqualFold(strings.TrimSpace(item.ThreadSource), "subagent") {
		return true
	}
	source := strings.TrimSpace(item.Source)
	return strings.EqualFold(source, "subagent") || strings.Contains(source, `"subagent"`)
}

func isInteractiveSource(source string) bool {
	source = strings.TrimSpace(source)
	if source == "" {
		return true
	}
	switch strings.ToLower(source) {
	case "cli", "vscode":
		return true
	}
	var custom map[string]string
	if err := json.Unmarshal([]byte(source), &custom); err != nil {
		return false
	}
	value, ok := custom["custom"]
	return ok && (value == "atlas" || value == "chatgpt")
}

func pathPredicate(path string) string {
	clean := strings.TrimRight(filepath.Clean(path), string(os.PathSeparator))
	return "cwd = " + sqlQuote(clean) + " or cwd like " + sqlQuote(clean+string(os.PathSeparator)+"%")
}

func sqlQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func sqlQuoteIdentifier(value string) string {
	return "\"" + strings.ReplaceAll(value, "\"", "\"\"") + "\""
}

func normalizeQueryLimit(limit int) int {
	if limit <= 0 {
		return defaultQueryLimit
	}
	if limit > maxQueryLimit {
		return maxQueryLimit
	}
	return limit
}

func Messages(threadID string) ([]Message, error) {
	return MessagesWithLimit(threadID, 0)
}

func MessagesWithLimit(threadID string, limit int) ([]Message, error) {
	path, err := rolloutPath(threadID)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if messages, ok := cachedMessages(path, info, limit); ok {
		return messages, nil
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	messages, err := messagesFromFile(file, info, limit)
	if err != nil {
		return nil, err
	}
	storeCachedMessages(path, info, limit, messages)
	return cloneMessages(messages), nil
}

func messagesFromFile(file *os.File, info os.FileInfo, limit int) ([]Message, error) {
	if limit > 0 {
		return messagesFromTail(file, info.Size(), limit)
	}
	return messagesFromReader(file, limit)
}

func messagesFromTail(file *os.File, size int64, limit int) ([]Message, error) {
	if limit <= 0 {
		return messagesFromReader(file, limit)
	}
	var newestFirst []Message
	var pending []byte
	offset := size
	for offset > 0 && len(newestFirst) < limit {
		readSize := int64(tailReadChunkSize)
		if offset < readSize {
			readSize = offset
		}
		offset -= readSize

		chunk := make([]byte, readSize)
		n, err := file.ReadAt(chunk, offset)
		if err != nil && !errors.Is(err, io.EOF) {
			return nil, err
		}
		data := append(chunk[:n], pending...)
		start := len(data)
		for start > 0 && len(newestFirst) < limit {
			idx := bytes.LastIndexByte(data[:start], '\n')
			if idx < 0 {
				break
			}
			if message, ok := parseMessageLine(data[idx+1 : start]); ok {
				newestFirst = append(newestFirst, message)
			}
			start = idx
		}
		// 从文件尾部倒读时，data[:start] 是跨 chunk 的半行；保留下来等前一个 chunk 补齐。
		pending = append(pending[:0], data[:start]...)
	}
	if len(newestFirst) < limit && len(bytes.TrimSpace(pending)) > 0 {
		if message, ok := parseMessageLine(pending); ok {
			newestFirst = append(newestFirst, message)
		}
	}
	reverseMessages(newestFirst)
	return newestFirst, nil
}

func messagesFromReader(reader io.Reader, limit int) ([]Message, error) {
	var messages []Message
	buffered := bufio.NewReaderSize(reader, 256*1024)
	for {
		// Codex rollout 里可能包含很大的 tool/result 行，Scanner 有单行上限；
		// 用 ReadBytes 按行读取可以保留 JSONL 语义，同时避免大历史会话被整页吞空。
		line, err := buffered.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			if message, ok := parseMessageLine(line); ok {
				messages = appendLimitedMessage(messages, message, limit)
			}
		}
		if err == nil {
			continue
		}
		if errors.Is(err, io.EOF) {
			return messages, nil
		}
		return messages, err
	}
}

func parseMessageLine(line []byte) (Message, bool) {
	var message Message
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return message, false
	}
	if !bytes.Contains(line, []byte(`"type":"event_msg"`)) {
		return message, false
	}
	if !bytes.Contains(line, []byte(`"type":"user_message"`)) && !bytes.Contains(line, []byte(`"type":"agent_message"`)) {
		return message, false
	}

	var item struct {
		Timestamp string          `json:"timestamp"`
		Type      string          `json:"type"`
		Payload   json.RawMessage `json:"payload"`
	}
	if err := json.Unmarshal(line, &item); err != nil || item.Type != "event_msg" {
		return message, false
	}
	var event struct {
		Type    string `json:"type"`
		Message string `json:"message"`
		Phase   string `json:"phase"`
	}
	if err := json.Unmarshal(item.Payload, &event); err != nil {
		return message, false
	}
	role := ""
	switch event.Type {
	case "user_message":
		role = "user"
	case "agent_message":
		role = "assistant"
	default:
		return message, false
	}
	text := strings.TrimSpace(event.Message)
	if text == "" {
		return message, false
	}
	return Message{Role: role, Content: text, CreatedAt: parseTime(item.Timestamp)}, true
}

func appendLimitedMessage(messages []Message, message Message, limit int) []Message {
	if limit <= 0 || len(messages) < limit {
		return append(messages, message)
	}
	// 只保留最近 N 条历史，避免大历史会话一次性撑满网络响应和 SwiftUI 渲染。
	copy(messages, messages[1:])
	messages[len(messages)-1] = message
	return messages
}

func cachedMessages(path string, info os.FileInfo, limit int) ([]Message, bool) {
	messageCache.Lock()
	defer messageCache.Unlock()

	entry, ok := messageCache.items[path]
	if !ok || entry.size != info.Size() || !entry.modTime.Equal(info.ModTime()) {
		return nil, false
	}
	if !entry.complete && (limit <= 0 || entry.limit < limit) {
		return nil, false
	}
	return applyMessageLimit(cloneMessages(entry.messages), limit), true
}

func storeCachedMessages(path string, info os.FileInfo, limit int, messages []Message) {
	messageCache.Lock()
	defer messageCache.Unlock()

	// rollout 会随会话追加而变更；用 size+mtime 做缓存版本，命中时避免反复扫描大 JSONL。
	messageCache.items[path] = messageCacheEntry{
		size:     info.Size(),
		modTime:  info.ModTime(),
		limit:    limit,
		complete: limit <= 0,
		messages: cloneMessages(messages),
	}
	if len(messageCache.items) <= maxMessageCaches {
		return
	}
	for key := range messageCache.items {
		if key != path {
			delete(messageCache.items, key)
			return
		}
	}
}

func applyMessageLimit(messages []Message, limit int) []Message {
	if limit <= 0 || len(messages) <= limit {
		return messages
	}
	return messages[len(messages)-limit:]
}

func cloneMessages(messages []Message) []Message {
	return append([]Message(nil), messages...)
}

func reverseMessages(messages []Message) {
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}
}

func MessagesForSession(sessionID string, resumeID string) ([]Message, error) {
	threadID := ThreadIDForSession(sessionID, resumeID)
	if threadID == "" {
		return nil, os.ErrNotExist
	}
	return MessagesWithLimit(threadID, 0)
}

func ThreadIDForSession(sessionID string, resumeID string) string {
	if trimmed := strings.TrimSpace(resumeID); trimmed != "" {
		return trimmed
	}
	sessionID = strings.TrimSpace(sessionID)
	if strings.HasPrefix(sessionID, "codex_") {
		return strings.TrimPrefix(sessionID, "codex_")
	}
	return sessionID
}

func rolloutPath(threadID string) (string, error) {
	if strings.TrimSpace(threadID) == "" {
		return "", os.ErrNotExist
	}
	db := filepath.Join(homeDir(), ".codex", "state_5.sqlite")
	out, err := exec.Command("sqlite3", "-json", db, "select rollout_path from threads where id = '"+strings.ReplaceAll(threadID, "'", "''")+"' limit 1").Output()
	if err != nil {
		return "", err
	}
	var rows []struct {
		RolloutPath string `json:"rollout_path"`
	}
	if err := json.Unmarshal(out, &rows); err != nil {
		return "", err
	}
	if len(rows) == 0 || rows[0].RolloutPath == "" {
		return "", os.ErrNotExist
	}
	if _, err := os.Stat(rows[0].RolloutPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", os.ErrNotExist
		}
		return "", err
	}
	return rows[0].RolloutPath, nil
}

func homeDir() string {
	if home, err := homeDirFunc(); err == nil {
		return home
	}
	return ""
}

func msTime(v int64) time.Time {
	if v <= 0 {
		return time.Now()
	}
	return time.UnixMilli(v)
}

func parseTime(raw string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return time.Now()
	}
	return t
}

func trimRunes(s string, n int) string {
	runes := []rune(strings.Join(strings.Fields(s), " "))
	if len(runes) <= n {
		return string(runes)
	}
	return string(runes[:n]) + "..."
}
