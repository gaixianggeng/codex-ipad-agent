//! Generic process-pool bookkeeping for bridges that follow the
//! one-process-per-thread + LRU-evict + idle-reap pattern.
//!
//! Used by `crates/claude-bridge/src/pool/` and `crates/pi-bridge/src/pool/`,
//! which were previously near-identical copies. The vendor-specific spawn
//! step (binary path, command-line arguments, init handshake) stays in the
//! bridge crate; this module only owns the table of live handles, the
//! cwd→threads index, and the capacity/eviction policy.
//!
//! Usage shape:
//! ```text
//! 1. Bridge wraps `ProcessPool<MyHandle>` plus its own spawn config.
//! 2. acquire_for_new_thread:
//!      let thread_id = uuid::Uuid::now_v7().to_string();
//!      pool.ensure_capacity_for(&thread_id).await?;
//!      let handle = MyHandle::spawn(...).await?;
//!      pool.track_new(thread_id.clone(), cwd, Arc::new(handle)).await?;
//! 3. get/mark_active/mark_idle/release delegate straight through.
//! ```

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use thiserror::Error;
use tokio::sync::Mutex;

/// Codex thread identifier as it appears on the wire (UUID-shaped string).
/// Matches the type alias each bridge already exports — kept alphabetic-cheap
/// rather than newtyped so callers thread the raw string through to handlers
/// without an extra wrapper.
pub type ThreadId = String;

/// Bounded pool default — 16 concurrent processes per bridge. Generous enough
/// for typical workflows, low enough that a runaway client can't exhaust
/// system resources.
pub const DEFAULT_MAX_PROCESSES: usize = 16;

/// Idle reap interval default — 10 minutes.
pub const DEFAULT_IDLE_TTL: Duration = Duration::from_secs(10 * 60);

/// Trait that every pool member implements. The pool needs to be able to
/// shut a handle down cleanly when the entry is reaped or evicted; the rest
/// (stdin/stdout, control requests, etc.) is owned by the bridge.
pub trait PoolMember: Send + Sync {
    /// Send EOF / signal the underlying child process and wait for it to
    /// exit. The pool calls this on reap and eviction.
    fn shutdown(&self) -> impl std::future::Future<Output = ()> + Send;
}

#[derive(Debug, Error)]
pub enum PoolError {
    #[error("pool is at capacity ({0} processes); no idle thread to evict")]
    Capacity(usize),

    #[error("thread {0} already exists in the pool")]
    DuplicateThread(ThreadId),

    #[error(transparent)]
    Spawn(#[from] anyhow::Error),
}

/// Per-thread bookkeeping the pool keeps alongside each handle.
struct PoolEntry<H> {
    handle: Arc<H>,
    cwd: PathBuf,
    last_active: Instant,
    /// True while a turn is being driven through this thread. The reaper
    /// never evicts threads with `active=true` regardless of TTL.
    active: bool,
}

struct PoolInner<H> {
    processes: HashMap<ThreadId, PoolEntry<H>>,
    by_cwd: HashMap<PathBuf, HashSet<ThreadId>>,
    max_processes: usize,
    idle_ttl: Duration,
}

impl<H> PoolInner<H> {
    fn insert(&mut self, thread_id: ThreadId, entry: PoolEntry<H>) {
        self.by_cwd
            .entry(entry.cwd.clone())
            .or_default()
            .insert(thread_id.clone());
        self.processes.insert(thread_id, entry);
    }

    fn remove(&mut self, thread_id: &str) -> Option<PoolEntry<H>> {
        let entry = self.processes.remove(thread_id)?;
        if let Some(set) = self.by_cwd.get_mut(&entry.cwd) {
            set.remove(thread_id);
            if set.is_empty() {
                self.by_cwd.remove(&entry.cwd);
            }
        }
        Some(entry)
    }

    /// Pick the least-recently-active *idle* thread for eviction. Returns
    /// `None` when every thread currently has a turn in flight.
    fn pick_lru_idle(&self) -> Option<ThreadId> {
        self.processes
            .iter()
            .filter(|(_, e)| !e.active)
            .min_by_key(|(_, e)| e.last_active)
            .map(|(id, _)| id.clone())
    }

    fn collect_expired(&self, now: Instant) -> Vec<ThreadId> {
        self.processes
            .iter()
            .filter(|(_, e)| !e.active && now.duration_since(e.last_active) >= self.idle_ttl)
            .map(|(id, _)| id.clone())
            .collect()
    }
}

/// Generic process pool. Each `H` instance is the bridge's per-thread handle
/// type (e.g. `ClaudeProcessHandle`, `PiProcessHandle`).
pub struct ProcessPool<H: PoolMember> {
    inner: Arc<Mutex<PoolInner<H>>>,
}

impl<H: PoolMember> Clone for ProcessPool<H> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

impl<H: PoolMember + 'static> ProcessPool<H> {
    pub fn new(max_processes: usize, idle_ttl: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(PoolInner {
                processes: HashMap::new(),
                by_cwd: HashMap::new(),
                max_processes: max_processes.max(1),
                idle_ttl,
            })),
        }
    }

    /// Look up a tracked process by thread id, refreshing its `last_active`
    /// so the reaper won't pick it up immediately.
    pub async fn get(&self, thread_id: &str) -> Option<Arc<H>> {
        let mut inner = self.inner.lock().await;
        let entry = inner.processes.get_mut(thread_id)?;
        entry.last_active = Instant::now();
        Some(entry.handle.clone())
    }

    /// Mark a thread as currently driving a turn. Active threads are not
    /// eligible for LRU eviction or idle reaping until [`Self::mark_idle`].
    pub async fn mark_active(&self, thread_id: &str) {
        let mut inner = self.inner.lock().await;
        if let Some(entry) = inner.processes.get_mut(thread_id) {
            entry.active = true;
            entry.last_active = Instant::now();
        }
    }

    /// Inverse of [`Self::mark_active`]; refreshes `last_active`.
    pub async fn mark_idle(&self, thread_id: &str) {
        let mut inner = self.inner.lock().await;
        if let Some(entry) = inner.processes.get_mut(thread_id) {
            entry.active = false;
            entry.last_active = Instant::now();
        }
    }

    /// Explicitly release a thread's handle. Sends shutdown and reaps.
    pub async fn release(&self, thread_id: &str) {
        let entry = {
            let mut inner = self.inner.lock().await;
            inner.remove(thread_id)
        };
        if let Some(entry) = entry {
            entry.handle.shutdown().await;
        }
    }

    /// Release only when `thread_id` still points at `expected`.
    ///
    /// 异常退出的旧 driver 可能晚于新进程结束清理。按 `Arc` 实例比较后再删除，
    /// 避免旧 driver 把同一 thread 刚冷恢复出来的新进程误删。
    pub async fn release_if_same(&self, thread_id: &str, expected: &Arc<H>) -> bool {
        let entry = {
            let mut inner = self.inner.lock().await;
            let matches = inner
                .processes
                .get(thread_id)
                .is_some_and(|entry| Arc::ptr_eq(&entry.handle, expected));
            matches.then(|| inner.remove(thread_id)).flatten()
        };
        if let Some(entry) = entry {
            entry.handle.shutdown().await;
            true
        } else {
            false
        }
    }

    pub async fn loaded_thread_ids(&self) -> Vec<ThreadId> {
        self.inner.lock().await.processes.keys().cloned().collect()
    }

    pub async fn threads_for_cwd(&self, cwd: &Path) -> Vec<ThreadId> {
        self.inner
            .lock()
            .await
            .by_cwd
            .get(cwd)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default()
    }

    pub async fn len(&self) -> usize {
        self.inner.lock().await.processes.len()
    }

    pub async fn is_empty(&self) -> bool {
        self.inner.lock().await.processes.is_empty()
    }

    /// Sweep idle threads whose `last_active` is older than `idle_ttl`.
    /// Returns the thread ids that were reaped.
    pub async fn reap_idle(&self) -> Vec<ThreadId> {
        let now = Instant::now();
        let expired: Vec<ThreadId> = {
            let inner = self.inner.lock().await;
            inner.collect_expired(now)
        };
        let mut reaped = Vec::with_capacity(expired.len());
        for id in expired {
            let entry = self.inner.lock().await.remove(&id);
            if let Some(entry) = entry {
                entry.handle.shutdown().await;
                reaped.push(id);
            }
        }
        reaped
    }

    /// Try to find an existing handle the caller can reuse for a one-shot
    /// utility query. Strategy:
    /// 1. cwd-scoped reuse (any tracked thread bound to `cwd`),
    /// 2. cwd-agnostic reuse (LRU thread-bound process),
    /// 3. None — caller should spawn a fresh handle.
    pub async fn try_reuse_for_utility(&self, cwd: Option<&Path>) -> Option<Arc<H>> {
        let inner = self.inner.lock().await;
        let cwd_handle = cwd.and_then(|target| {
            inner
                .by_cwd
                .get(target)
                .and_then(|set| set.iter().next())
                .and_then(|id| inner.processes.get(id))
                .map(|e| e.handle.clone())
        });
        if let Some(handle) = cwd_handle {
            return Some(handle);
        }
        inner
            .processes
            .iter()
            .min_by_key(|(_, e)| e.last_active)
            .map(|(_, e)| e.handle.clone())
    }

    /// Reap idle entries and, if needed, evict the LRU idle thread to make
    /// room for one new spawn. Returns `Capacity` if every tracked thread
    /// is currently active. The pool is unchanged on success — callers must
    /// follow up with [`Self::track_new`] once the spawn completes.
    pub async fn ensure_capacity_for(&self, thread_id: &str) -> Result<(), PoolError> {
        {
            let inner = self.inner.lock().await;
            if inner.processes.contains_key(thread_id) {
                return Err(PoolError::DuplicateThread(thread_id.to_string()));
            }
        }
        self.reap_idle().await;
        loop {
            let evict = {
                let inner = self.inner.lock().await;
                if inner.processes.len() < inner.max_processes {
                    None
                } else {
                    inner.pick_lru_idle()
                }
            };
            match evict {
                Some(victim) => {
                    let entry = self.inner.lock().await.remove(&victim);
                    if let Some(entry) = entry {
                        entry.handle.shutdown().await;
                    }
                }
                None => {
                    let inner = self.inner.lock().await;
                    if inner.processes.len() >= inner.max_processes {
                        return Err(PoolError::Capacity(inner.max_processes));
                    }
                    return Ok(());
                }
            }
        }
    }

    /// Register a freshly-spawned handle in the pool. Returns
    /// `DuplicateThread` if a race added a handle for `thread_id` first; the
    /// caller is responsible for shutting the new handle down in that case.
    pub async fn track_new(
        &self,
        thread_id: ThreadId,
        cwd: PathBuf,
        handle: Arc<H>,
    ) -> Result<(), PoolError> {
        let mut inner = self.inner.lock().await;
        if inner.processes.contains_key(&thread_id) {
            return Err(PoolError::DuplicateThread(thread_id));
        }
        inner.insert(
            thread_id,
            PoolEntry {
                handle,
                cwd,
                last_active: Instant::now(),
                active: false,
            },
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Fake handle that just tracks how many times shutdown has been called.
    struct FakeHandle {
        shutdowns: Arc<AtomicUsize>,
    }

    impl FakeHandle {
        fn new() -> (Arc<Self>, Arc<AtomicUsize>) {
            let shutdowns = Arc::new(AtomicUsize::new(0));
            (
                Arc::new(Self {
                    shutdowns: shutdowns.clone(),
                }),
                shutdowns,
            )
        }
    }

    impl PoolMember for FakeHandle {
        async fn shutdown(&self) {
            self.shutdowns.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn pool(max: usize, ttl: Duration) -> ProcessPool<FakeHandle> {
        ProcessPool::new(max, ttl)
    }

    async fn track(
        pool: &ProcessPool<FakeHandle>,
        id: &str,
        cwd: &str,
    ) -> (Arc<FakeHandle>, Arc<AtomicUsize>) {
        let (handle, counter) = FakeHandle::new();
        pool.track_new(id.into(), PathBuf::from(cwd), handle.clone())
            .await
            .expect("track_new");
        (handle, counter)
    }

    #[tokio::test]
    async fn track_get_release_roundtrip() {
        let p = pool(4, Duration::from_secs(60));
        let (h, counter) = track(&p, "t1", "/a").await;
        let fetched = p.get("t1").await.expect("get");
        assert!(Arc::ptr_eq(&fetched, &h));
        assert_eq!(p.len().await, 1);
        p.release("t1").await;
        assert_eq!(counter.load(Ordering::SeqCst), 1);
        assert!(p.is_empty().await);
    }

    #[tokio::test]
    async fn duplicate_track_errors() {
        let p = pool(4, Duration::from_secs(60));
        track(&p, "t1", "/a").await;
        let (handle2, _) = FakeHandle::new();
        let err = p
            .track_new("t1".into(), PathBuf::from("/a"), handle2)
            .await
            .unwrap_err();
        assert!(matches!(err, PoolError::DuplicateThread(_)));
    }

    #[tokio::test]
    async fn release_if_same_never_removes_replacement() {
        let p = pool(4, Duration::from_secs(60));
        let (old, old_shutdowns) = track(&p, "t1", "/a").await;
        let (unrelated, _) = FakeHandle::new();

        assert!(!p.release_if_same("t1", &unrelated).await);
        assert!(Arc::ptr_eq(&p.get("t1").await.expect("old remains"), &old));
        assert_eq!(old_shutdowns.load(Ordering::SeqCst), 0);

        assert!(p.release_if_same("t1", &old).await);
        assert!(p.get("t1").await.is_none());
        assert_eq!(old_shutdowns.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn reap_idle_drops_old_inactive_only() {
        let p = pool(8, Duration::from_millis(50));
        track(&p, "young".into(), "/a").await;
        track(&p, "old_active".into(), "/b").await;
        p.mark_active("old_active").await;
        // Backdate "old_active" and "old_inactive" by hand via insert-with-age.
        let (h, _) = FakeHandle::new();
        {
            let mut inner = p.inner.lock().await;
            inner.insert(
                "old_inactive".into(),
                PoolEntry {
                    handle: h,
                    cwd: PathBuf::from("/c"),
                    last_active: Instant::now() - Duration::from_secs(60),
                    active: false,
                },
            );
        }
        // active threads aren't reaped; young threads aren't reaped.
        let reaped = p.reap_idle().await;
        assert_eq!(reaped, vec!["old_inactive".to_string()]);
        assert!(p.get("young").await.is_some());
        assert!(p.get("old_active").await.is_some());
    }

    #[tokio::test]
    async fn ensure_capacity_evicts_lru_idle() {
        let p = pool(2, Duration::from_secs(60));
        track(&p, "lru", "/a").await;
        // Backdate lru by manually rewriting last_active.
        {
            let mut inner = p.inner.lock().await;
            if let Some(e) = inner.processes.get_mut("lru") {
                e.last_active = Instant::now() - Duration::from_secs(120);
            }
        }
        track(&p, "fresh", "/b").await;
        assert_eq!(p.len().await, 2);
        // Pool is at cap; ensure_capacity_for("new") should evict "lru".
        p.ensure_capacity_for("new").await.expect("space");
        assert_eq!(p.len().await, 1);
        assert!(p.get("lru").await.is_none());
        assert!(p.get("fresh").await.is_some());
    }

    #[tokio::test]
    async fn ensure_capacity_errors_when_all_active() {
        let p = pool(2, Duration::from_secs(60));
        track(&p, "a", "/a").await;
        track(&p, "b", "/b").await;
        p.mark_active("a").await;
        p.mark_active("b").await;
        let err = p.ensure_capacity_for("c").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(2)));
    }

    #[tokio::test]
    async fn ensure_capacity_errors_on_existing_id() {
        let p = pool(2, Duration::from_secs(60));
        track(&p, "x", "/a").await;
        let err = p.ensure_capacity_for("x").await.unwrap_err();
        assert!(matches!(err, PoolError::DuplicateThread(_)));
    }

    #[tokio::test]
    async fn try_reuse_for_utility_prefers_cwd_match() {
        let p = pool(8, Duration::from_secs(60));
        let (a_handle, _) = track(&p, "a", "/repo").await;
        track(&p, "b", "/other").await;
        let h = p
            .try_reuse_for_utility(Some(Path::new("/repo")))
            .await
            .expect("reuse");
        assert!(Arc::ptr_eq(&h, &a_handle));
    }

    #[tokio::test]
    async fn try_reuse_for_utility_falls_back_to_lru() {
        let p = pool(8, Duration::from_secs(60));
        let (older_handle, _) = track(&p, "older", "/x").await;
        // Backdate the first entry so it becomes the LRU pick.
        {
            let mut inner = p.inner.lock().await;
            if let Some(e) = inner.processes.get_mut("older") {
                e.last_active = Instant::now() - Duration::from_secs(60);
            }
        }
        track(&p, "newer", "/y").await;
        let h = p.try_reuse_for_utility(None).await.expect("reuse");
        assert!(Arc::ptr_eq(&h, &older_handle));
    }

    #[tokio::test]
    async fn try_reuse_for_utility_returns_none_when_empty() {
        let p = pool(2, Duration::from_secs(60));
        assert!(p.try_reuse_for_utility(None).await.is_none());
    }

    #[tokio::test]
    async fn mark_active_blocks_lru_eviction() {
        let p = pool(1, Duration::from_secs(60));
        track(&p, "only", "/a").await;
        p.mark_active("only").await;
        let err = p.ensure_capacity_for("new").await.unwrap_err();
        assert!(matches!(err, PoolError::Capacity(1)));
        p.mark_idle("only").await;
        // Now the LRU pick is allowed.
        p.ensure_capacity_for("new").await.expect("ok");
    }

    #[tokio::test]
    async fn threads_for_cwd_indexes_correctly() {
        let p = pool(8, Duration::from_secs(60));
        track(&p, "t1", "/x").await;
        track(&p, "t2", "/x").await;
        track(&p, "t3", "/y").await;
        let mut x = p.threads_for_cwd(Path::new("/x")).await;
        x.sort();
        assert_eq!(x, vec!["t1".to_string(), "t2".to_string()]);
        assert_eq!(
            p.threads_for_cwd(Path::new("/y")).await,
            vec!["t3".to_string()]
        );
        p.release("t1").await;
        assert_eq!(
            p.threads_for_cwd(Path::new("/x")).await,
            vec!["t2".to_string()]
        );
    }
}
