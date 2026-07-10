package httpapi

import (
	"testing"
	"time"
)

func TestRelayMonitorTracksHistoryTrafficByMethod(t *testing.T) {
	monitor := newRelayMonitor()
	if !monitor.reserveHistoryInflight("list-fingerprint", "owner-1", "thread/list", time.Minute) {
		t.Fatal("首个 thread/list 指纹应登记成功")
	}
	if monitor.reserveHistoryInflight("list-fingerprint", "owner-2", "thread/list", time.Minute) {
		t.Fatal("重复 thread/list 指纹应被拒绝")
	}

	monitor.recordHistoryResponseMetrics("thread/list", 1200, true)
	monitor.recordHistoryRateLimited("thread/list")
	monitor.releaseHistoryInflight("list-fingerprint", "owner-1")

	stats := monitor.snapshot().AppServerGateway.Methods["thread/list"]
	if stats.Requested != 2 || stats.Inflight != 0 {
		t.Fatalf("requested/inflight 统计异常：%+v", stats)
	}
	if stats.DuplicateRejected != 1 || stats.Rejected != 2 {
		t.Fatalf("duplicate/rejected 统计异常：%+v", stats)
	}
	if stats.Blocked != 1 || stats.RateLimited != 1 || stats.ResponseBytes != 1200 {
		t.Fatalf("blocked/rate-limited/response bytes 统计异常：%+v", stats)
	}
}

func TestRelayMonitorHistoryInflightOwnerPreventsLateRelease(t *testing.T) {
	monitor := newRelayMonitor()
	if !monitor.reserveHistoryInflight("history-fingerprint", "new-owner", "thread/turns/list", time.Minute) {
		t.Fatal("首个指纹应登记成功")
	}
	monitor.releaseHistoryInflight("history-fingerprint", "stale-owner")

	stats := monitor.snapshot().AppServerGateway.Methods["thread/turns/list"]
	if stats.Inflight != 1 {
		t.Fatalf("旧 owner 不应释放新请求：%+v", stats)
	}
	monitor.releaseHistoryInflight("history-fingerprint", "new-owner")
	stats = monitor.snapshot().AppServerGateway.Methods["thread/turns/list"]
	if stats.Inflight != 0 {
		t.Fatalf("正确 owner 应释放请求：%+v", stats)
	}
}
