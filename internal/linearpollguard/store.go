package linearpollguard

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
)

const (
	SchemaVersion    = 1
	DefaultHardLimit = 8 * time.Minute
)

var (
	ErrRunActive   = errors.New("linear polling run is already active")
	ErrRunMismatch = errors.New("linear polling run id does not own the lease")
)

type Lease struct {
	Version       int        `json:"version"`
	RunID         string     `json:"run_id"`
	StartedAt     time.Time  `json:"started_at"`
	Phase         string     `json:"phase"`
	BlockingTool  string     `json:"blocking_tool,omitempty"`
	ToolStartedAt *time.Time `json:"tool_started_at,omitempty"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

type CompletedRun struct {
	Lease
	State      string    `json:"state"`
	Conclusion string    `json:"conclusion"`
	FinishedAt time.Time `json:"finished_at"`
}

type Snapshot struct {
	Status            string        `json:"status"`
	Acquired          bool          `json:"acquired,omitempty"`
	Blocked           bool          `json:"blocked"`
	RunID             string        `json:"run_id,omitempty"`
	StartedAt         *time.Time    `json:"started_at,omitempty"`
	Phase             string        `json:"phase,omitempty"`
	BlockingTool      string        `json:"blocking_tool,omitempty"`
	ToolStartedAt     *time.Time    `json:"tool_started_at,omitempty"`
	ElapsedSeconds    int64         `json:"elapsed_seconds,omitempty"`
	ToolWaitSeconds   int64         `json:"tool_wait_seconds,omitempty"`
	HardLimitSeconds  int64         `json:"hard_limit_seconds,omitempty"`
	HardLimitExceeded bool          `json:"hard_limit_exceeded,omitempty"`
	Conclusion        string        `json:"conclusion,omitempty"`
	Detail            string        `json:"detail,omitempty"`
	LastRun           *CompletedRun `json:"last_run,omitempty"`
}

type Store struct {
	Dir string
	Now func() time.Time
}

func DefaultStateDir() (string, error) {
	root := strings.TrimSpace(os.Getenv("CODEX_HOME"))
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("解析 Codex 数据目录失败：%w", err)
		}
		root = filepath.Join(home, ".codex")
	}
	return filepath.Join(root, "automations", "mimi-linear-issue", "guard"), nil
}

func NewStore(dir string) *Store {
	return &Store{Dir: filepath.Clean(dir), Now: time.Now}
}

func (s *Store) Begin(runID string, startedAt time.Time, hardLimit time.Duration) (Snapshot, error) {
	runID, err := validateMetadata("run_id", runID, 160)
	if err != nil {
		return Snapshot{}, err
	}
	if startedAt.IsZero() {
		startedAt = s.now()
	}
	if err := s.ensurePrivateDir(); err != nil {
		return Snapshot{}, err
	}

	now := s.now()
	lease := Lease{
		Version:   SchemaVersion,
		RunID:     runID,
		StartedAt: startedAt.UTC(),
		Phase:     "started",
		UpdatedAt: now,
	}
	raw, err := json.MarshalIndent(lease, "", "  ")
	if err != nil {
		return Snapshot{}, fmt.Errorf("编码巡检租约失败：%w", err)
	}
	raw = append(raw, '\n')

	handle, err := os.OpenFile(s.activePath(), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			snapshot := s.Inspect(hardLimit)
			if snapshot.Conclusion == "" {
				snapshot.Conclusion = "skip_current_heartbeat_no_side_effects"
			}
			return snapshot, ErrRunActive
		}
		return Snapshot{}, fmt.Errorf("原子创建巡检租约失败：%w", err)
	}
	if _, err := handle.Write(raw); err != nil {
		_ = handle.Close()
		// 写入失败时保留文件，后续一律按损坏租约 fail-closed，避免第二轮越过不确定状态。
		return Snapshot{}, fmt.Errorf("写入巡检租约失败：%w", err)
	}
	if err := handle.Sync(); err != nil {
		_ = handle.Close()
		return Snapshot{}, fmt.Errorf("持久化巡检租约失败：%w", err)
	}
	if err := handle.Close(); err != nil {
		return Snapshot{}, fmt.Errorf("关闭巡检租约失败：%w", err)
	}
	if err := os.Chmod(s.activePath(), 0o600); err != nil {
		return Snapshot{}, fmt.Errorf("收紧巡检租约权限失败：%w", err)
	}
	snapshot := snapshotFromLease(lease, now, hardLimit)
	snapshot.Status = "acquired"
	snapshot.Acquired = true
	snapshot.Blocked = false
	return snapshot, nil
}

func (s *Store) Phase(runID, phase, blockingTool string) (Snapshot, error) {
	runID, err := validateMetadata("run_id", runID, 160)
	if err != nil {
		return Snapshot{}, err
	}
	phase, err = validateMetadata("phase", phase, 96)
	if err != nil {
		return Snapshot{}, err
	}
	if blockingTool != "" {
		blockingTool, err = validateMetadata("blocking_tool", blockingTool, 192)
		if err != nil {
			return Snapshot{}, err
		}
	}

	lease, err := s.readLease()
	if err != nil {
		return Snapshot{}, err
	}
	if lease.RunID != runID {
		return Snapshot{}, ErrRunMismatch
	}
	now := s.now()
	lease.Phase = phase
	lease.BlockingTool = blockingTool
	lease.UpdatedAt = now
	if blockingTool == "" {
		lease.ToolStartedAt = nil
	} else {
		startedAt := now
		lease.ToolStartedAt = &startedAt
	}
	if err := s.writeJSONAtomically(s.activePath(), lease); err != nil {
		return Snapshot{}, err
	}
	return snapshotFromLease(lease, now, DefaultHardLimit), nil
}

func (s *Store) Finish(runID, conclusion string) (Snapshot, error) {
	return s.complete(runID, "finished", conclusion)
}

func (s *Store) ManualUnlock(runID, reason string) (Snapshot, error) {
	reason, err := validateMetadata("reason", reason, 512)
	if err != nil {
		return Snapshot{}, err
	}
	return s.complete(runID, "manual_unlocked", reason)
}

func (s *Store) Inspect(hardLimit time.Duration) Snapshot {
	hardLimit = normalizedHardLimit(hardLimit)
	raw, err := os.ReadFile(s.activePath())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			snapshot := Snapshot{
				Status:           "idle",
				Blocked:          false,
				HardLimitSeconds: int64(hardLimit / time.Second),
			}
			if last, lastErr := s.readLastRun(); lastErr == nil {
				snapshot.LastRun = &last
			} else if !errors.Is(lastErr, os.ErrNotExist) {
				snapshot.Detail = "last run record is unreadable"
			}
			return snapshot
		}
		return corruptSnapshot(hardLimit, "active lease is unreadable")
	}
	var lease Lease
	if err := json.Unmarshal(raw, &lease); err != nil {
		return corruptSnapshot(hardLimit, "active lease is corrupt")
	}
	if err := validateLease(lease); err != nil {
		return corruptSnapshot(hardLimit, "active lease metadata is invalid")
	}
	return snapshotFromLease(lease, s.now(), hardLimit)
}

func (s *Store) complete(runID, state, conclusion string) (Snapshot, error) {
	runID, err := validateMetadata("run_id", runID, 160)
	if err != nil {
		return Snapshot{}, err
	}
	conclusion, err = validateMetadata("conclusion", conclusion, 512)
	if err != nil {
		return Snapshot{}, err
	}
	lease, err := s.readLease()
	if err != nil {
		return Snapshot{}, err
	}
	if lease.RunID != runID {
		return Snapshot{}, ErrRunMismatch
	}
	now := s.now()
	completed := CompletedRun{
		Lease:      lease,
		State:      state,
		Conclusion: conclusion,
		FinishedAt: now,
	}
	if err := s.writeJSONAtomically(s.lastRunPath(), completed); err != nil {
		return Snapshot{}, err
	}
	if err := os.Remove(s.activePath()); err != nil {
		return Snapshot{}, fmt.Errorf("释放巡检租约失败：%w", err)
	}
	return Snapshot{
		Status:     state,
		Blocked:    false,
		RunID:      lease.RunID,
		StartedAt:  &lease.StartedAt,
		Phase:      lease.Phase,
		Conclusion: conclusion,
		LastRun:    &completed,
	}, nil
}

func (s *Store) readLease() (Lease, error) {
	raw, err := os.ReadFile(s.activePath())
	if err != nil {
		return Lease{}, fmt.Errorf("读取巡检租约失败：%w", err)
	}
	var lease Lease
	if err := json.Unmarshal(raw, &lease); err != nil {
		return Lease{}, fmt.Errorf("巡检租约损坏，必须人工核对后解锁")
	}
	if err := validateLease(lease); err != nil {
		return Lease{}, fmt.Errorf("巡检租约字段无效，必须人工核对后解锁：%w", err)
	}
	return lease, nil
}

func (s *Store) readLastRun() (CompletedRun, error) {
	raw, err := os.ReadFile(s.lastRunPath())
	if err != nil {
		return CompletedRun{}, err
	}
	var completed CompletedRun
	if err := json.Unmarshal(raw, &completed); err != nil {
		return CompletedRun{}, err
	}
	return completed, nil
}

func (s *Store) ensurePrivateDir() error {
	if strings.TrimSpace(s.Dir) == "" || s.Dir == "." {
		return fmt.Errorf("巡检状态目录不能为空")
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return fmt.Errorf("创建巡检状态目录失败：%w", err)
	}
	if err := os.Chmod(s.Dir, 0o700); err != nil {
		return fmt.Errorf("收紧巡检状态目录权限失败：%w", err)
	}
	return nil
}

func (s *Store) writeJSONAtomically(path string, value any) error {
	if err := s.ensurePrivateDir(); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("编码巡检状态失败：%w", err)
	}
	raw = append(raw, '\n')
	temp, err := os.CreateTemp(s.Dir, ".linear-poll-guard-*")
	if err != nil {
		return fmt.Errorf("创建巡检状态临时文件失败：%w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(0o600); err != nil {
		_ = temp.Close()
		return fmt.Errorf("收紧巡检状态临时文件权限失败：%w", err)
	}
	if _, err := temp.Write(raw); err != nil {
		_ = temp.Close()
		return fmt.Errorf("写入巡检状态临时文件失败：%w", err)
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return fmt.Errorf("持久化巡检状态临时文件失败：%w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("关闭巡检状态临时文件失败：%w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("原子替换巡检状态失败：%w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("收紧巡检状态权限失败：%w", err)
	}
	return nil
}

func (s *Store) activePath() string {
	return filepath.Join(s.Dir, "active.json")
}

func (s *Store) lastRunPath() string {
	return filepath.Join(s.Dir, "last-run.json")
}

func (s *Store) now() time.Time {
	if s.Now == nil {
		return time.Now().UTC()
	}
	return s.Now().UTC()
}

func snapshotFromLease(lease Lease, now time.Time, hardLimit time.Duration) Snapshot {
	hardLimit = normalizedHardLimit(hardLimit)
	elapsed := nonNegativeDuration(now.Sub(lease.StartedAt))
	toolWait := time.Duration(0)
	if lease.ToolStartedAt != nil {
		toolWait = nonNegativeDuration(now.Sub(*lease.ToolStartedAt))
	}
	exceeded := elapsed >= hardLimit
	status := "active"
	conclusion := ""
	if exceeded {
		status = "stale"
		conclusion = "manual_reconciliation_required_no_automatic_takeover"
	}
	return Snapshot{
		Status:            status,
		Blocked:           true,
		RunID:             lease.RunID,
		StartedAt:         &lease.StartedAt,
		Phase:             lease.Phase,
		BlockingTool:      lease.BlockingTool,
		ToolStartedAt:     lease.ToolStartedAt,
		ElapsedSeconds:    int64(elapsed / time.Second),
		ToolWaitSeconds:   int64(toolWait / time.Second),
		HardLimitSeconds:  int64(hardLimit / time.Second),
		HardLimitExceeded: exceeded,
		Conclusion:        conclusion,
	}
}

func corruptSnapshot(hardLimit time.Duration, detail string) Snapshot {
	hardLimit = normalizedHardLimit(hardLimit)
	return Snapshot{
		Status:           "corrupt",
		Blocked:          true,
		HardLimitSeconds: int64(hardLimit / time.Second),
		Conclusion:       "manual_reconciliation_required_no_automatic_takeover",
		Detail:           detail,
	}
}

func normalizedHardLimit(limit time.Duration) time.Duration {
	if limit <= 0 {
		return DefaultHardLimit
	}
	return limit
}

func nonNegativeDuration(value time.Duration) time.Duration {
	if value < 0 {
		return 0
	}
	return value
}

func validateLease(lease Lease) error {
	if lease.Version != SchemaVersion {
		return fmt.Errorf("version=%d", lease.Version)
	}
	if _, err := validateMetadata("run_id", lease.RunID, 160); err != nil {
		return err
	}
	if lease.StartedAt.IsZero() || lease.UpdatedAt.IsZero() {
		return fmt.Errorf("租约时间不能为空")
	}
	if _, err := validateMetadata("phase", lease.Phase, 96); err != nil {
		return err
	}
	if lease.BlockingTool != "" {
		if _, err := validateMetadata("blocking_tool", lease.BlockingTool, 192); err != nil {
			return err
		}
		if lease.ToolStartedAt == nil || lease.ToolStartedAt.IsZero() {
			return fmt.Errorf("阻塞工具必须记录开始时间")
		}
	}
	return nil
}

func validateMetadata(name, value string, maxRunes int) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("%s 不能为空", name)
	}
	if len([]rune(value)) > maxRunes {
		return "", fmt.Errorf("%s 过长", name)
	}
	for _, char := range value {
		if unicode.IsControl(char) {
			return "", fmt.Errorf("%s 不能包含控制字符", name)
		}
	}
	return value, nil
}
