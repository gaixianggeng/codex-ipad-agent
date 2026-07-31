package linearpollguard

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestHungToolUserFollowupAndLaterHeartbeatStayFailClosed(t *testing.T) {
	start := time.Date(2026, 7, 31, 2, 25, 0, 0, time.FixedZone("CST", 8*60*60))
	now := start
	store := NewStore(t.TempDir())
	store.Now = func() time.Time { return now }

	first, err := store.Begin("run-hung-list", start, DefaultHardLimit)
	if err != nil {
		t.Fatal(err)
	}
	if first.Status != "acquired" || !first.Acquired || first.Blocked {
		t.Fatalf("首轮应持有排他租约：%+v", first)
	}

	now = start.Add(10 * time.Second)
	if _, err := store.Phase("run-hung-list", "querying_task_state", "codex_app.list_threads"); err != nil {
		t.Fatal(err)
	}

	// 用户中途追问不会改写租约 owner；协调轮仍停在原阻塞工具。
	now = start.Add(2 * time.Minute)
	followup := store.Inspect(DefaultHardLimit)
	if followup.RunID != "run-hung-list" || followup.BlockingTool != "codex_app.list_threads" {
		t.Fatalf("用户追问后租约不应漂移：%+v", followup)
	}

	// 后续心跳只能得到 blocked，不能取得第二个租约或继续派发。
	next, err := store.Begin("run-later-heartbeat", now, DefaultHardLimit)
	if !errors.Is(err, ErrRunActive) {
		t.Fatalf("后续心跳必须被现有租约阻止，got=%v snapshot=%+v", err, next)
	}
	if next.RunID != "run-hung-list" || !next.Blocked {
		t.Fatalf("后续心跳必须返回原 owner：%+v", next)
	}

	now = start.Add(DefaultHardLimit + time.Second)
	stale := store.Inspect(DefaultHardLimit)
	if stale.Status != "stale" || !stale.HardLimitExceeded {
		t.Fatalf("超过 8 分钟必须明确标记 stale：%+v", stale)
	}
	if stale.BlockingTool != "codex_app.list_threads" || stale.ToolWaitSeconds != 471 {
		t.Fatalf("必须记录阻塞工具与等待时长：%+v", stale)
	}
	if stale.Conclusion != "manual_reconciliation_required_no_automatic_takeover" {
		t.Fatalf("stale 租约不能自动抢占：%+v", stale)
	}
}

func TestConcurrentHeartbeatsOnlyOneAcquiresLease(t *testing.T) {
	store := NewStore(t.TempDir())
	fixed := time.Date(2026, 7, 31, 2, 25, 0, 0, time.UTC)
	store.Now = func() time.Time { return fixed }

	var acquired atomic.Int32
	var wait sync.WaitGroup
	for index := 0; index < 32; index++ {
		wait.Add(1)
		go func(id int) {
			defer wait.Done()
			_, err := store.Begin("run-race-"+time.Unix(int64(id), 0).UTC().Format("150405"), fixed, DefaultHardLimit)
			switch {
			case err == nil:
				acquired.Add(1)
			case errors.Is(err, ErrRunActive):
			default:
				t.Errorf("并发抢租约出现异常：%v", err)
			}
		}(index)
	}
	wait.Wait()
	if acquired.Load() != 1 {
		t.Fatalf("O_EXCL 必须保证只有一个心跳成功，got=%d", acquired.Load())
	}
}

func TestCrashAfterBeginKeepsLeaseAndCorruptionFailsClosed(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	now := time.Date(2026, 7, 31, 2, 25, 0, 0, time.UTC)
	store.Now = func() time.Time { return now }
	if _, err := store.Begin("run-before-crash", now, DefaultHardLimit); err != nil {
		t.Fatal(err)
	}

	restarted := NewStore(dir)
	restarted.Now = func() time.Time { return now.Add(time.Minute) }
	snapshot := restarted.Inspect(DefaultHardLimit)
	if snapshot.RunID != "run-before-crash" || !snapshot.Blocked {
		t.Fatalf("进程重启后必须保留原租约：%+v", snapshot)
	}

	if err := os.WriteFile(filepath.Join(dir, "active.json"), []byte("{partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	corrupt := restarted.Inspect(DefaultHardLimit)
	if corrupt.Status != "corrupt" || !corrupt.Blocked {
		t.Fatalf("损坏租约必须 fail-closed：%+v", corrupt)
	}
	if corrupt.Conclusion != "manual_reconciliation_required_no_automatic_takeover" {
		t.Fatalf("损坏租约不能自动恢复：%+v", corrupt)
	}
}

func TestFinishAllowsNextHeartbeatAndKeepsAuditRecord(t *testing.T) {
	start := time.Date(2026, 7, 31, 2, 25, 0, 0, time.UTC)
	now := start
	store := NewStore(t.TempDir())
	store.Now = func() time.Time { return now }
	if _, err := store.Begin("run-one", start, DefaultHardLimit); err != nil {
		t.Fatal(err)
	}
	now = start.Add(time.Minute)
	finished, err := store.Finish("run-one", "no_dispatch_needed")
	if err != nil {
		t.Fatal(err)
	}
	if finished.Status != "finished" || finished.LastRun == nil {
		t.Fatalf("完成记录异常：%+v", finished)
	}

	now = start.Add(2 * time.Minute)
	next, err := store.Begin("run-two", now, DefaultHardLimit)
	if err != nil {
		t.Fatal(err)
	}
	if next.RunID != "run-two" || next.Status != "acquired" || !next.Acquired {
		t.Fatalf("正常释放后下一轮应可开始：%+v", next)
	}
}

func TestManualUnlockRequiresMatchingOwnerAndReason(t *testing.T) {
	now := time.Date(2026, 7, 31, 2, 25, 0, 0, time.UTC)
	store := NewStore(t.TempDir())
	store.Now = func() time.Time { return now }
	if _, err := store.Begin("run-owner", now, DefaultHardLimit); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ManualUnlock("wrong-owner", "已核对"); !errors.Is(err, ErrRunMismatch) {
		t.Fatalf("错误 owner 不能解锁，got=%v", err)
	}
	if _, err := store.ManualUnlock("run-owner", ""); err == nil {
		t.Fatal("人工解锁必须提供原因")
	}
	unlocked, err := store.ManualUnlock("run-owner", "已核对 Linear、Git 和 Worktree，无不确定副作用")
	if err != nil {
		t.Fatal(err)
	}
	if unlocked.Status != "manual_unlocked" || unlocked.LastRun == nil {
		t.Fatalf("人工解锁记录异常：%+v", unlocked)
	}
}

func TestLeasePermissionsArePrivate(t *testing.T) {
	now := time.Date(2026, 7, 31, 2, 25, 0, 0, time.UTC)
	dir := filepath.Join(t.TempDir(), "guard")
	store := NewStore(dir)
	store.Now = func() time.Time { return now }
	if _, err := store.Begin("run-private", now, DefaultHardLimit); err != nil {
		t.Fatal(err)
	}
	dirInfo, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := dirInfo.Mode().Perm(); got != 0o700 {
		t.Fatalf("状态目录权限应为 0700，got=%#o", got)
	}
	fileInfo, err := os.Stat(filepath.Join(dir, "active.json"))
	if err != nil {
		t.Fatal(err)
	}
	if got := fileInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("租约权限应为 0600，got=%#o", got)
	}
}
