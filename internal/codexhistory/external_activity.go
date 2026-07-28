package codexhistory

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

const (
	defaultExternalActivityStaleAfter = 30 * time.Minute
	externalActivityCandidateLimit    = 500
	maxExternalActivityLineBytes      = 1 << 20
)

// ExternalActivity 是允许返回给移动端的最小只读快照。
// 不包含 cwd、rollout 路径、prompt 或消息内容，避免把本机 Codex 状态库变成文件枚举接口。
type ExternalActivity struct {
	ThreadID     string    `json:"thread_id"`
	ProjectID    string    `json:"project_id"`
	Source       string    `json:"source"`
	State        string    `json:"state"`
	TurnID       string    `json:"turn_id,omitempty"`
	Revision     string    `json:"revision"`
	LastActivity time.Time `json:"last_activity_at"`
}

type ExternalActivityDiagnostics struct {
	CandidateQueries int `json:"candidate_queries"`
	FileScans        int `json:"file_scans"`
	CacheHits        int `json:"cache_hits"`
	MalformedLines   int `json:"malformed_lines"`
	OversizedLines   int `json:"oversized_lines"`
}

type externalActivityCandidate struct {
	ThreadID     string
	CWD          string
	Source       string
	ThreadSource string
	RolloutPath  string
}

type externalRolloutCacheEntry struct {
	offset       int64
	size         int64
	modTime      time.Time
	originator   string
	metaThreadID string
	metaCWD      string
	threadSource string
	active       bool
	turnID       string
}

type externalRolloutRecord struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Payload   struct {
		ID           string `json:"id"`
		CWD          string `json:"cwd"`
		Originator   string `json:"originator"`
		ThreadSource string `json:"thread_source"`
		Type         string `json:"type"`
		TurnID       string `json:"turn_id"`
	} `json:"payload"`
}

// ExternalActivityTracker 按请求增量读取 rollout 尾部。它没有后台 goroutine，
// agentd 空闲时不会持续扫盘；同一个文件未变化时只做一次 stat 并复用解析状态。
type ExternalActivityTracker struct {
	mu         sync.Mutex
	store      ThreadStore
	registry   *projects.Registry
	staleAfter time.Duration
	now        func() time.Time
	stat       func(string) (os.FileInfo, error)
	open       func(string) (*os.File, error)
	query      func(string, string) ([]byte, error)

	dbSignature dbSignature
	dbCached    bool
	candidates  []externalActivityCandidate
	files       map[string]externalRolloutCacheEntry
	diagnostics ExternalActivityDiagnostics
}

func NewExternalActivityTracker(db string, registry *projects.Registry) *ExternalActivityTracker {
	return &ExternalActivityTracker{
		store:      NewThreadStore(db),
		registry:   registry,
		staleAfter: defaultExternalActivityStaleAfter,
		now:        time.Now,
		stat:       os.Stat,
		open:       os.Open,
		query:      sqliteQueryFunc,
		files:      map[string]externalRolloutCacheEntry{},
	}
}

func NewDefaultExternalActivityTracker(registry *projects.Registry) *ExternalActivityTracker {
	return NewExternalActivityTracker("", registry)
}

func (t *ExternalActivityTracker) Diagnostics() ExternalActivityDiagnostics {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.diagnostics
}

// Snapshot 只返回仍有外部 turn 运行证据的白名单项目线程。
// terminal lifecycle 到达或文件超过 staleAfter 未更新后，该线程会从结果中消失。
func (t *ExternalActivityTracker) Snapshot() ([]ExternalActivity, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.registry == nil {
		return []ExternalActivity{}, nil
	}
	candidates, err := t.loadCandidates()
	if err != nil {
		return nil, err
	}

	now := t.now()
	activities := make([]ExternalActivity, 0, len(candidates))
	knownPaths := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		project, ok := t.registry.FindByPath(candidate.CWD)
		if !ok {
			continue
		}
		path := strings.TrimSpace(candidate.RolloutPath)
		if path == "" {
			continue
		}
		knownPaths[path] = struct{}{}
		info, err := t.stat(path)
		if err != nil || info.IsDir() {
			continue
		}
		entry, err := t.scanRollout(path, info)
		if err != nil {
			continue
		}
		if !isCodexDesktopOriginator(entry.originator) ||
			entry.metaThreadID != candidate.ThreadID ||
			!isTopLevelExternalThreadSource(entry.threadSource) ||
			!entry.active ||
			now.Sub(info.ModTime()) > t.staleAfter {
			continue
		}
		// SQLite cwd 和 session_meta cwd 都必须落在同一个白名单项目中。
		// 这样即使状态库里出现不一致路径，也不会跨项目泄露线程身份。
		metaProject, ok := t.registry.FindByPath(entry.metaCWD)
		if !ok || metaProject.ID != project.ID {
			continue
		}
		activities = append(activities, ExternalActivity{
			ThreadID:     candidate.ThreadID,
			ProjectID:    project.ID,
			Source:       "codex_desktop",
			State:        "running",
			TurnID:       entry.turnID,
			Revision:     externalActivityRevision(info),
			LastActivity: info.ModTime().UTC(),
		})
	}
	for path := range t.files {
		if _, ok := knownPaths[path]; !ok {
			delete(t.files, path)
		}
	}
	sort.Slice(activities, func(i, j int) bool {
		if activities[i].LastActivity.Equal(activities[j].LastActivity) {
			return activities[i].ThreadID < activities[j].ThreadID
		}
		return activities[i].LastActivity.After(activities[j].LastActivity)
	})
	return activities, nil
}

func (t *ExternalActivityTracker) loadCandidates() ([]externalActivityCandidate, error) {
	db := t.store.databasePath()
	signature, err := t.readDBSignature(db)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			// 没有使用过 Codex 的旧主机可能尚未创建状态库。能力仍可安全声明，
			// 此时返回空活动而不是让 iPad 每轮轮询都收到 503。
			t.dbCached = false
			t.candidates = nil
			t.files = map[string]externalRolloutCacheEntry{}
			return []externalActivityCandidate{}, nil
		}
		return nil, err
	}
	if t.dbCached && signature == t.dbSignature {
		out := make([]externalActivityCandidate, len(t.candidates))
		copy(out, t.candidates)
		return out, nil
	}

	columns, edgeColumns, err := t.externalHistoryColumns(db)
	if err != nil {
		return nil, err
	}
	where := "1=1"
	if columns["archived"] {
		where = "archived=0"
	}
	where += " and " + interactiveSourcePredicate(columns)
	where += " and " + nonSubagentPredicate(columns, edgeColumns)
	if columns["thread_source"] {
		where += " and coalesce(thread_source, 'user') = 'user'"
	}
	sourceExpr := optionalColumnExpr(columns, "source")
	threadSourceExpr := optionalColumnExpr(columns, "thread_source")
	rolloutPathExpr := optionalColumnExpr(columns, "rollout_path")
	sql := "select id,cwd," + sourceExpr + "," + threadSourceExpr + "," + rolloutPathExpr +
		" from threads where " + where + " order by updated_at_ms desc, id desc limit " +
		strconv.Itoa(externalActivityCandidateLimit)
	out, err := t.query(db, sql)
	if err != nil {
		return nil, err
	}
	t.diagnostics.CandidateQueries++
	var rows []struct {
		ID           string `json:"id"`
		CWD          string `json:"cwd"`
		Source       string `json:"source"`
		ThreadSource string `json:"thread_source"`
		RolloutPath  string `json:"rollout_path"`
	}
	if len(bytes.TrimSpace(out)) != 0 {
		if err := json.Unmarshal(out, &rows); err != nil {
			return nil, err
		}
	}
	candidates := make([]externalActivityCandidate, 0, len(rows))
	for _, row := range rows {
		if strings.TrimSpace(row.ID) == "" ||
			strings.TrimSpace(row.CWD) == "" ||
			strings.TrimSpace(row.RolloutPath) == "" ||
			!isInteractiveSource(row.Source) ||
			!isTopLevelExternalThreadSource(row.ThreadSource) {
			continue
		}
		candidates = append(candidates, externalActivityCandidate{
			ThreadID:     row.ID,
			CWD:          row.CWD,
			Source:       row.Source,
			ThreadSource: row.ThreadSource,
			RolloutPath:  row.RolloutPath,
		})
	}
	t.dbSignature = signature
	t.dbCached = true
	t.candidates = candidates
	result := make([]externalActivityCandidate, len(candidates))
	copy(result, candidates)
	return result, nil
}

func (t *ExternalActivityTracker) externalHistoryColumns(db string) (map[string]bool, map[string]bool, error) {
	query := "select 'threads' as table_name, name from pragma_table_info('threads') " +
		"union all select 'thread_spawn_edges' as table_name, name from pragma_table_info('thread_spawn_edges')"
	out, err := t.query(db, query)
	if err != nil {
		return nil, nil, err
	}
	var rows []struct {
		TableName string `json:"table_name"`
		Name      string `json:"name"`
	}
	if len(bytes.TrimSpace(out)) != 0 {
		if err := json.Unmarshal(out, &rows); err != nil {
			return nil, nil, err
		}
	}
	columns := map[string]bool{}
	edgeColumns := map[string]bool{}
	for _, row := range rows {
		switch row.TableName {
		case "threads":
			columns[row.Name] = true
		case "thread_spawn_edges":
			edgeColumns[row.Name] = true
		}
	}
	if !columns["id"] || !columns["cwd"] || !columns["rollout_path"] || !columns["updated_at_ms"] {
		return nil, nil, fmt.Errorf("Codex 状态库缺少外部活动跟踪所需字段")
	}
	return columns, edgeColumns, nil
}

func (t *ExternalActivityTracker) readDBSignature(db string) (dbSignature, error) {
	info, err := t.stat(db)
	if err != nil {
		return dbSignature{}, err
	}
	signature := dbSignature{size: info.Size(), modTime: info.ModTime()}
	if wal, err := t.stat(db + "-wal"); err == nil {
		signature.walSize = wal.Size()
		signature.walModTime = wal.ModTime()
	}
	return signature, nil
}

func (t *ExternalActivityTracker) scanRollout(path string, info os.FileInfo) (externalRolloutCacheEntry, error) {
	entry, cached := t.files[path]
	if cached && entry.size == info.Size() && entry.modTime.Equal(info.ModTime()) {
		t.diagnostics.CacheHits++
		return entry, nil
	}
	if !cached || info.Size() < entry.offset || info.ModTime().Before(entry.modTime) {
		entry = externalRolloutCacheEntry{}
	}

	file, err := t.open(path)
	if err != nil {
		return entry, err
	}
	defer file.Close()
	if _, err := file.Seek(entry.offset, io.SeekStart); err != nil {
		return entry, err
	}

	t.diagnostics.FileScans++
	reader := bufio.NewReaderSize(file, 64*1024)
	committedOffset := entry.offset
	var line []byte
	lineBytes := int64(0)
	oversized := false
	for {
		fragment, readErr := reader.ReadSlice('\n')
		lineBytes += int64(len(fragment))
		if !oversized {
			if len(line)+len(fragment) <= maxExternalActivityLineBytes {
				line = append(line, fragment...)
			} else {
				oversized = true
				line = nil
			}
		}
		switch {
		case errors.Is(readErr, bufio.ErrBufferFull):
			continue
		case readErr == nil:
			if oversized {
				t.diagnostics.OversizedLines++
			} else {
				t.applyExternalRolloutLine(&entry, line)
			}
			committedOffset += lineBytes
			line = nil
			lineBytes = 0
			oversized = false
		case errors.Is(readErr, io.EOF):
			// rollout 是 append-only JSONL。尾部半行留到下次追加后再解析，
			// 不能提前提交 offset，否则会永久漏掉 lifecycle。
			entry.offset = committedOffset
			entry.size = info.Size()
			entry.modTime = info.ModTime()
			t.files[path] = entry
			return entry, nil
		default:
			return entry, readErr
		}
	}
}

func (t *ExternalActivityTracker) applyExternalRolloutLine(entry *externalRolloutCacheEntry, line []byte) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return
	}
	var record externalRolloutRecord
	if err := json.Unmarshal(line, &record); err != nil {
		t.diagnostics.MalformedLines++
		return
	}
	switch record.Type {
	case "session_meta":
		entry.originator = strings.TrimSpace(record.Payload.Originator)
		entry.metaThreadID = strings.TrimSpace(record.Payload.ID)
		entry.metaCWD = strings.TrimSpace(record.Payload.CWD)
		entry.threadSource = strings.TrimSpace(record.Payload.ThreadSource)
	case "event_msg":
		turnID := strings.TrimSpace(record.Payload.TurnID)
		switch strings.TrimSpace(record.Payload.Type) {
		case "task_started":
			entry.active = true
			entry.turnID = turnID
		case "task_complete", "turn_aborted":
			// 旧 turn 的迟到 terminal 不能终止已经开始的新 turn。
			if turnID == "" || entry.turnID == "" || turnID == entry.turnID {
				entry.active = false
				entry.turnID = ""
			}
		}
	}
}

func externalActivityRevision(info os.FileInfo) string {
	return strconv.FormatInt(info.Size(), 36) + "-" + strconv.FormatInt(info.ModTime().UnixNano(), 36)
}

func isCodexDesktopOriginator(originator string) bool {
	switch strings.ToLower(strings.TrimSpace(originator)) {
	case "codex desktop", "codex_work_desktop":
		return true
	default:
		return false
	}
}

func isTopLevelExternalThreadSource(source string) bool {
	source = strings.ToLower(strings.TrimSpace(source))
	return source == "" || source == "user"
}
