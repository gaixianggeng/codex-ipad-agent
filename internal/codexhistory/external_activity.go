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
	// Gateway 登记只需要覆盖 turn/start 到 rollout 写入 user_message 的短窗口。
	// 有界 TTL 可以避免断线或 upstream 写失败后留下永久“本机发起”证据。
	gatewayTurnRegistrationTTL   = 2 * time.Minute
	gatewayTurnRegistrationLimit = 512
	gatewayTurnRegistrationIDMax = 256
	gatewayTurnEventClockSkew    = 2 * time.Second
	// task_started 与 user_message 是同一次 turn/start 的相邻生命周期事件。
	// 除了都要落在 registration TTL 内，两者还必须足够接近，避免失败请求的
	// user_message 证据错误归属给稍后真正由 Mac 发起的 turn。
	gatewayTurnLifecycleWindow = 10 * time.Second
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
	// gatewayTurnPending 表示在 task_started 之前到达的 user_message 已与 gateway 登记匹配；
	// gatewayOwned 绑定当前 active turn。真实 rollout 可能先写 task_started，也可能先写
	// user_message，因此两个方向都要支持；新的 task_started 仍必须重新取证。
	gatewayTurnPending             bool
	gatewayTurnPendingAt           time.Time
	gatewayTurnPendingRegisteredAt time.Time
	gatewayOwned                   bool
	turnStartedAt                  time.Time
}

type gatewayTurnRegistration struct {
	registeredAt time.Time
}

type gatewayTurnEvidence struct {
	registeredAt time.Time
	eventAt      time.Time
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
		ClientID     string `json:"client_id"`
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

	dbSignature  dbSignature
	dbCached     bool
	candidates   []externalActivityCandidate
	files        map[string]externalRolloutCacheEntry
	gatewayTurns map[string]gatewayTurnRegistration
	diagnostics  ExternalActivityDiagnostics
}

func NewExternalActivityTracker(db string, registry *projects.Registry) *ExternalActivityTracker {
	return &ExternalActivityTracker{
		store:        NewThreadStore(db),
		registry:     registry,
		staleAfter:   defaultExternalActivityStaleAfter,
		now:          time.Now,
		stat:         os.Stat,
		open:         os.Open,
		query:        sqliteQueryFunc,
		files:        map[string]externalRolloutCacheEntry{},
		gatewayTurns: map[string]gatewayTurnRegistration{},
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

// RegisterGatewayTurnStart 登记一个已经通过 agentd gateway 校验的 Codex turn/start。
// 登记本身不会改变外部活动判断；只有同线程 rollout 随后写出时间相符且 client_id
// 完全一致的 user_message，才能把紧随其后的 task_started 认定为 iPad 发起。
func (t *ExternalActivityTracker) RegisterGatewayTurnStart(threadID string, clientUserMessageID string) {
	threadID = strings.TrimSpace(threadID)
	clientUserMessageID = strings.TrimSpace(clientUserMessageID)
	if threadID == "" ||
		clientUserMessageID == "" ||
		len(threadID) > gatewayTurnRegistrationIDMax ||
		len(clientUserMessageID) > gatewayTurnRegistrationIDMax {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	now := t.now().UTC()
	t.pruneGatewayTurnRegistrations(now)
	if t.gatewayTurns == nil {
		t.gatewayTurns = map[string]gatewayTurnRegistration{}
	}
	key := gatewayTurnRegistrationKey(threadID, clientUserMessageID)
	t.gatewayTurns[key] = gatewayTurnRegistration{registeredAt: now}
	t.trimGatewayTurnRegistrations()
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
	t.pruneGatewayTurnRegistrations(now.UTC())
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
		if expireGatewayTurnPending(&entry, now.UTC()) {
			t.files[path] = entry
		}
		if !isCodexDesktopOriginator(entry.originator) ||
			entry.metaThreadID != candidate.ThreadID ||
			!isTopLevelExternalThreadSource(entry.threadSource) ||
			!entry.active ||
			entry.gatewayOwned ||
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
		case "user_message":
			// rollout 的落盘顺序并不固定：当前版本通常先写 task_started，再写
			// user_message；旧版本或边界窗口也可能相反。精确证据到达时，已有 active
			// turn 就直接归属本机，否则留给紧随其后的 task_started 消费。
			evidence, matched := t.consumeGatewayTurnRegistration(
				entry.metaThreadID,
				record.Payload.ClientID,
				record.Timestamp,
			)
			clearGatewayTurnPending(entry)
			if matched &&
				entry.active &&
				gatewayTurnEvidenceMatchesTaskStart(evidence, entry.turnStartedAt) {
				entry.gatewayOwned = true
			} else if matched && !entry.active {
				entry.gatewayTurnPending = true
				entry.gatewayTurnPendingAt = evidence.eventAt
				entry.gatewayTurnPendingRegisteredAt = evidence.registeredAt
			}
		case "task_started":
			turnStartedAt, _ := parseExternalRolloutTimestamp(record.Timestamp)
			entry.active = true
			entry.turnID = turnID
			entry.turnStartedAt = turnStartedAt
			entry.gatewayOwned = entry.gatewayTurnPending &&
				gatewayTurnEvidenceMatchesTaskStart(
					gatewayTurnEvidence{
						registeredAt: entry.gatewayTurnPendingRegisteredAt,
						eventAt:      entry.gatewayTurnPendingAt,
					},
					turnStartedAt,
				)
			clearGatewayTurnPending(entry)
		case "task_complete", "turn_aborted":
			// 旧 turn 的迟到 terminal 不能终止已经开始的新 turn。
			if turnID == "" || entry.turnID == "" || turnID == entry.turnID {
				entry.active = false
				entry.turnID = ""
				entry.turnStartedAt = time.Time{}
				entry.gatewayOwned = false
				clearGatewayTurnPending(entry)
			}
		}
	}
}

func clearGatewayTurnPending(entry *externalRolloutCacheEntry) {
	entry.gatewayTurnPending = false
	entry.gatewayTurnPendingAt = time.Time{}
	entry.gatewayTurnPendingRegisteredAt = time.Time{}
}

func expireGatewayTurnPending(entry *externalRolloutCacheEntry, now time.Time) bool {
	if !entry.gatewayTurnPending {
		return false
	}
	if !entry.gatewayTurnPendingAt.IsZero() &&
		!now.After(entry.gatewayTurnPendingAt.Add(gatewayTurnLifecycleWindow)) {
		return false
	}
	clearGatewayTurnPending(entry)
	return true
}

func (t *ExternalActivityTracker) consumeGatewayTurnRegistration(
	threadID string,
	clientUserMessageID string,
	rawTimestamp string,
) (gatewayTurnEvidence, bool) {
	threadID = strings.TrimSpace(threadID)
	clientUserMessageID = strings.TrimSpace(clientUserMessageID)
	rawTimestamp = strings.TrimSpace(rawTimestamp)
	if threadID == "" || clientUserMessageID == "" || rawTimestamp == "" {
		return gatewayTurnEvidence{}, false
	}
	eventAt, ok := parseExternalRolloutTimestamp(rawTimestamp)
	if !ok {
		return gatewayTurnEvidence{}, false
	}
	key := gatewayTurnRegistrationKey(threadID, clientUserMessageID)
	registration, ok := t.gatewayTurns[key]
	if !ok {
		return gatewayTurnEvidence{}, false
	}
	// 同一个 client id 只能消费一次。即使时间校验失败也删除，避免恶意或损坏
	// rollout 在稍后的重复行中重新尝试命中。
	delete(t.gatewayTurns, key)
	if eventAt.Before(registration.registeredAt.Add(-gatewayTurnEventClockSkew)) {
		return gatewayTurnEvidence{}, false
	}
	if eventAt.After(registration.registeredAt.Add(gatewayTurnRegistrationTTL)) {
		return gatewayTurnEvidence{}, false
	}
	return gatewayTurnEvidence{
		registeredAt: registration.registeredAt,
		eventAt:      eventAt,
	}, true
}

func parseExternalRolloutTimestamp(rawTimestamp string) (time.Time, bool) {
	eventAt, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(rawTimestamp))
	if err != nil {
		return time.Time{}, false
	}
	return eventAt.UTC(), true
}

func gatewayTurnEvidenceMatchesTaskStart(evidence gatewayTurnEvidence, turnStartedAt time.Time) bool {
	if evidence.registeredAt.IsZero() || evidence.eventAt.IsZero() || turnStartedAt.IsZero() {
		return false
	}
	if turnStartedAt.Before(evidence.registeredAt.Add(-gatewayTurnEventClockSkew)) ||
		turnStartedAt.After(evidence.registeredAt.Add(gatewayTurnRegistrationTTL)) {
		return false
	}
	delta := turnStartedAt.Sub(evidence.eventAt)
	if delta < 0 {
		delta = -delta
	}
	return delta <= gatewayTurnLifecycleWindow
}

func (t *ExternalActivityTracker) pruneGatewayTurnRegistrations(now time.Time) {
	for key, registration := range t.gatewayTurns {
		if now.After(registration.registeredAt.Add(gatewayTurnRegistrationTTL)) {
			delete(t.gatewayTurns, key)
		}
	}
}

func (t *ExternalActivityTracker) trimGatewayTurnRegistrations() {
	for len(t.gatewayTurns) > gatewayTurnRegistrationLimit {
		var oldestKey string
		var oldestAt time.Time
		for key, registration := range t.gatewayTurns {
			if oldestKey == "" ||
				registration.registeredAt.Before(oldestAt) ||
				(registration.registeredAt.Equal(oldestAt) && key < oldestKey) {
				oldestKey = key
				oldestAt = registration.registeredAt
			}
		}
		if oldestKey == "" {
			return
		}
		delete(t.gatewayTurns, oldestKey)
	}
}

func gatewayTurnRegistrationKey(threadID string, clientUserMessageID string) string {
	return strings.TrimSpace(threadID) + "\x00" + strings.TrimSpace(clientUserMessageID)
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
