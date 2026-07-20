//! Per-connection state for `claude-bridge`.
//!
//! One `ConnectionState` exists per connected codex client (keyed by session
//! id on the bridge). Handlers borrow it through `Arc<ConnectionState>`;
//! mutable bits live behind their own locks rather than wrapping the whole
//! struct in a `Mutex`, so a long-running turn does not block unrelated
//! requests.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;

use alleycat_bridge_core::ProcessLauncher;
use alleycat_bridge_core::session::Session;
use serde_json::Value;
use tokio::sync::oneshot;

use alleycat_codex_proto::{
    ApprovalsReviewer, AskForApproval, InitializeCapabilities, JsonRpcMessage, RateLimitSnapshot,
    ReasoningEffort, RequestId, SandboxMode, ThreadItem, Turn, TurnError, TurnStatus,
};

use crate::index::ClaudeSessionRef;
use crate::pool::ClaudePool;
use crate::pool::claude_protocol::{McpServerInit, RateLimitInfo, SystemInit};

/// Compat re-export so the daemon's
/// `Arc<dyn alleycat_claude_bridge::state::ThreadIndexHandle>` keeps spelling
/// the right trait. Goes away in A5 once the daemon adopts the builder API.
///
/// Implementors specialize on [`ClaudeSessionRef`]; the supertrait constraint
/// pins the metadata so the daemon doesn't need to spell it.
pub trait ThreadIndexHandle: alleycat_bridge_core::ThreadIndexHandle<ClaudeSessionRef> {}

impl<T> ThreadIndexHandle for T where
    T: alleycat_bridge_core::ThreadIndexHandle<ClaudeSessionRef> + ?Sized
{
}

pub use crate::index::{IndexEntry, ListFilter, ListPage, ListSort};

/// Per-connection bridge state. Cheap to clone via `Arc`.
pub struct ConnectionState {
    defaults: Mutex<ThreadDefaults>,
    session: Arc<Session>,
    claude_pool: Arc<ClaudePool>,
    thread_index: Arc<dyn ThreadIndexHandle>,
    /// Launcher used for `command/exec` shell tools. `None` falls back to a
    /// bridge-default [`alleycat_bridge_core::LocalLauncher`] (preserves the
    /// pre-refactor behavior of the legacy `for_test` helper).
    launcher: Option<Arc<dyn ProcessLauncher>>,
    /// Trust indexed thread cwd values without checking local filesystem
    /// existence. Embedders that run the agent somewhere else, like Litter's
    /// SSH launcher, need the cwd to be validated by that remote process.
    trust_persisted_cwd: bool,
    caches: Mutex<ClaudeCaches>,
    oauth_rate_limit_refresh: tokio::sync::Mutex<()>,
    thread_logs: Mutex<HashMap<String, Vec<RecordedTurn>>>,
}

/// One turn's worth of items captured live from the event pump.
#[derive(Debug, Clone)]
pub struct RecordedTurn {
    pub turn_id: String,
    pub started_at: i64,
    pub completed_at: Option<i64>,
    pub status: TurnStatus,
    pub error: Option<TurnError>,
    pub items: Vec<ThreadItem>,
}

pub use alleycat_bridge_core::state::Capabilities;

/// Bridge defaults for a new thread. Seeded on construction and overrideable
/// per-`thread/start` request via `ThreadStartParams`.
#[derive(Debug, Clone, Default)]
pub struct ThreadDefaults {
    pub model: Option<String>,
    pub model_provider: Option<String>,
    pub reasoning_effort: Option<ReasoningEffort>,
    pub approval_policy: Option<AskForApproval>,
    pub approvals_reviewer: Option<ApprovalsReviewer>,
    pub sandbox: Option<SandboxMode>,
    pub service_name: Option<String>,
    pub system_prompt: Option<String>,
}

/// Bridge-wide caches refreshed from claude wire events.
#[derive(Debug, Clone, Default)]
pub struct ClaudeCaches {
    pub last_init: Option<SystemInit>,
    pub mcp_servers: Vec<McpServerInit>,
    pub skills: Vec<String>,
    pub slash_commands: Vec<String>,
    pub agents: Vec<String>,
    /// Claude 每次事件只携带一个窗口；按类型缓存，避免 5h/7d 连续到达时
    /// 后一个把前一个覆盖掉。
    pub rate_limit_infos: HashMap<String, RateLimitInfo>,
    /// OAuth usage 主动查询的短缓存。只保存百分比与重置时间，不保存凭据。
    pub oauth_rate_limit: Option<CachedOAuthRateLimit>,
    /// 失败也短暂退避，避免设置页并发刷新连续访问 Keychain/OAuth endpoint。
    pub oauth_last_attempt_at: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct CachedOAuthRateLimit {
    pub snapshot: RateLimitSnapshot,
    pub fetched_at: i64,
}

impl ClaudeCaches {
    pub fn refresh_rate_limit(&mut self, info: RateLimitInfo) -> Vec<RateLimitInfo> {
        let key = info
            .rate_limit_type
            .clone()
            .unwrap_or_else(|| "unknown".into());
        self.rate_limit_infos.insert(key, info);
        self.rate_limit_infos.values().cloned().collect()
    }

    pub fn cached_oauth_rate_limit(
        &self,
        now: i64,
        max_age_secs: i64,
    ) -> Option<RateLimitSnapshot> {
        self.oauth_rate_limit.as_ref().and_then(|cached| {
            (now.saturating_sub(cached.fetched_at) <= max_age_secs).then(|| cached.snapshot.clone())
        })
    }

    pub fn begin_oauth_rate_limit_refresh(&mut self, now: i64, min_interval_secs: i64) -> bool {
        if self
            .oauth_last_attempt_at
            .is_some_and(|last| now.saturating_sub(last) < min_interval_secs)
        {
            return false;
        }
        self.oauth_last_attempt_at = Some(now);
        true
    }

    pub fn store_oauth_rate_limit(&mut self, snapshot: RateLimitSnapshot, fetched_at: i64) {
        self.oauth_rate_limit = Some(CachedOAuthRateLimit {
            snapshot,
            fetched_at,
        });
    }
}

#[derive(Debug, Clone)]
pub enum ServerRequestError {
    Rpc { code: i64, message: String },
    ConnectionClosed,
    TimedOut,
}

impl From<alleycat_bridge_core::state::ServerRequestError> for ServerRequestError {
    fn from(value: alleycat_bridge_core::state::ServerRequestError) -> Self {
        match value {
            alleycat_bridge_core::state::ServerRequestError::Rpc(err) => Self::Rpc {
                code: err.code,
                message: err.message,
            },
            alleycat_bridge_core::state::ServerRequestError::ConnectionClosed => {
                Self::ConnectionClosed
            }
            alleycat_bridge_core::state::ServerRequestError::TimedOut => Self::TimedOut,
        }
    }
}

impl ConnectionState {
    pub fn new(
        session: Arc<Session>,
        claude_pool: Arc<ClaudePool>,
        thread_index: Arc<dyn ThreadIndexHandle>,
        defaults: ThreadDefaults,
    ) -> Self {
        Self::with_launcher(session, claude_pool, thread_index, defaults, None, false)
    }

    pub fn with_launcher(
        session: Arc<Session>,
        claude_pool: Arc<ClaudePool>,
        thread_index: Arc<dyn ThreadIndexHandle>,
        defaults: ThreadDefaults,
        launcher: Option<Arc<dyn ProcessLauncher>>,
        trust_persisted_cwd: bool,
    ) -> Self {
        Self {
            defaults: Mutex::new(defaults),
            session,
            claude_pool,
            thread_index,
            launcher,
            trust_persisted_cwd,
            caches: Mutex::new(ClaudeCaches::default()),
            oauth_rate_limit_refresh: tokio::sync::Mutex::new(()),
            thread_logs: Mutex::new(HashMap::new()),
        }
    }

    pub fn launcher(&self) -> Option<&Arc<dyn ProcessLauncher>> {
        self.launcher.as_ref()
    }

    pub fn trust_persisted_cwd(&self) -> bool {
        self.trust_persisted_cwd
    }

    pub fn session(&self) -> &Arc<Session> {
        &self.session
    }

    pub fn set_capabilities(
        &self,
        client_name: Option<String>,
        client_title: Option<String>,
        client_version: Option<String>,
        caps: Option<&InitializeCapabilities>,
    ) {
        let opt_out = caps
            .and_then(|c| c.opt_out_notification_methods.as_ref())
            .map(|v| v.iter().cloned().collect())
            .unwrap_or_default();
        self.session.set_capabilities(Capabilities {
            experimental_api: caps.is_some_and(|c| c.experimental_api),
            opt_out_notification_methods: opt_out,
            client_name,
            client_title,
            client_version,
        });
    }

    pub fn capabilities(&self) -> Capabilities {
        self.session.capabilities()
    }

    pub fn should_emit(&self, method: &str) -> bool {
        self.session.should_emit(method)
    }

    pub fn defaults(&self) -> ThreadDefaults {
        self.defaults.lock().unwrap().clone()
    }

    pub fn update_defaults(&self, f: impl FnOnce(&mut ThreadDefaults)) {
        let mut slot = self.defaults.lock().unwrap();
        f(&mut slot);
    }

    pub fn send(&self, msg: JsonRpcMessage) -> Result<(), SendError> {
        match serde_json::to_value(&msg) {
            Ok(value) => {
                self.session.enqueue(value);
                Ok(())
            }
            Err(_) => Err(SendError::ConnectionClosed),
        }
    }

    pub async fn register_pending_request(
        &self,
        request_id: RequestId,
        method: String,
        params: Value,
    ) -> oneshot::Receiver<Result<Value, ServerRequestError>> {
        let (tx, rx) = oneshot::channel();
        let key = request_id.to_string();
        let (core_tx, core_rx) =
            oneshot::channel::<Result<Value, alleycat_bridge_core::state::ServerRequestError>>();
        self.session.register_pending(key, method, params, core_tx);
        tokio::spawn(async move {
            let mapped = match core_rx.await {
                Ok(Ok(v)) => Ok(v),
                Ok(Err(e)) => Err(e.into()),
                Err(_) => Err(ServerRequestError::ConnectionClosed),
            };
            let _ = tx.send(mapped);
        });
        rx
    }

    pub async fn resolve_pending_request(
        &self,
        request_id: &RequestId,
        result: Result<Value, ServerRequestError>,
    ) -> bool {
        let mapped: Result<Value, alleycat_bridge_core::state::ServerRequestError> = match result {
            Ok(v) => Ok(v),
            Err(ServerRequestError::Rpc { code, message }) => {
                Err(alleycat_bridge_core::state::ServerRequestError::Rpc(
                    alleycat_bridge_core::JsonRpcError {
                        code,
                        message,
                        data: None,
                    },
                ))
            }
            Err(ServerRequestError::ConnectionClosed) => {
                Err(alleycat_bridge_core::state::ServerRequestError::ConnectionClosed)
            }
            Err(ServerRequestError::TimedOut) => {
                Err(alleycat_bridge_core::state::ServerRequestError::TimedOut)
            }
        };
        self.session
            .resolve_pending(&request_id.to_string(), mapped)
    }

    pub async fn cancel_all_pending_requests(&self) {
        self.session.cancel_all_pending();
    }

    pub fn claude_pool(&self) -> &Arc<ClaudePool> {
        &self.claude_pool
    }

    pub fn thread_index(&self) -> &Arc<dyn ThreadIndexHandle> {
        &self.thread_index
    }

    pub fn caches(&self) -> ClaudeCaches {
        self.caches.lock().unwrap().clone()
    }

    pub fn refresh_init_cache(&self, init: SystemInit) {
        let mut slot = self.caches.lock().unwrap();
        slot.mcp_servers = init.mcp_servers.clone();
        slot.skills = init.skills.clone();
        slot.slash_commands = init.slash_commands.clone();
        slot.agents = init.agents.clone();
        slot.last_init = Some(init);
    }

    pub fn refresh_rate_limit_cache(&self, info: RateLimitInfo) -> Vec<RateLimitInfo> {
        let mut slot = self.caches.lock().unwrap();
        slot.refresh_rate_limit(info)
    }

    pub fn cached_oauth_rate_limit(
        &self,
        now: i64,
        max_age_secs: i64,
    ) -> Option<RateLimitSnapshot> {
        self.caches
            .lock()
            .unwrap()
            .cached_oauth_rate_limit(now, max_age_secs)
    }

    pub async fn lock_oauth_rate_limit_refresh(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.oauth_rate_limit_refresh.lock().await
    }

    pub fn begin_oauth_rate_limit_refresh(&self, now: i64, min_interval_secs: i64) -> bool {
        self.caches
            .lock()
            .unwrap()
            .begin_oauth_rate_limit_refresh(now, min_interval_secs)
    }

    pub fn store_oauth_rate_limit(&self, snapshot: RateLimitSnapshot, fetched_at: i64) {
        self.caches
            .lock()
            .unwrap()
            .store_oauth_rate_limit(snapshot, fetched_at);
    }

    pub fn record_turn_started(&self, thread_id: &str, turn_id: String, started_at: i64) {
        let mut logs = self.thread_logs.lock().unwrap();
        let list = logs.entry(thread_id.to_string()).or_default();
        list.push(RecordedTurn {
            turn_id,
            started_at,
            completed_at: None,
            status: TurnStatus::InProgress,
            error: None,
            items: Vec::new(),
        });
    }

    pub fn record_item(&self, thread_id: &str, turn_id: &str, item: ThreadItem) {
        let mut logs = self.thread_logs.lock().unwrap();
        let Some(list) = logs.get_mut(thread_id) else {
            return;
        };
        let Some(turn) = list.iter_mut().rev().find(|t| t.turn_id == turn_id) else {
            return;
        };
        let new_id = item.id().to_string();
        if let Some(idx) = turn
            .items
            .iter()
            .position(|existing| existing.id() == new_id)
        {
            turn.items[idx] = item;
        } else {
            turn.items.push(item);
        }
    }

    pub fn record_turn_completed(
        &self,
        thread_id: &str,
        turn_id: &str,
        completed_at: i64,
        status: TurnStatus,
        error: Option<TurnError>,
    ) {
        let mut logs = self.thread_logs.lock().unwrap();
        let Some(list) = logs.get_mut(thread_id) else {
            return;
        };
        if let Some(turn) = list.iter_mut().rev().find(|t| t.turn_id == turn_id) {
            turn.completed_at = Some(completed_at);
            turn.status = status;
            turn.error = error;
        }
    }

    pub fn thread_log(&self, thread_id: &str) -> Vec<Turn> {
        let logs = self.thread_logs.lock().unwrap();
        let Some(list) = logs.get(thread_id) else {
            return Vec::new();
        };
        list.iter()
            .map(|t| {
                let started_at = t.started_at;
                let completed_at = t.completed_at;
                let duration_ms = completed_at.map(|end| ((end - started_at) * 1000).max(0));
                Turn {
                    id: t.turn_id.clone(),
                    items: t.items.clone(),
                    items_view: alleycat_codex_proto::default_items_view(),
                    status: t.status,
                    error: t.error.clone(),
                    started_at: Some(started_at),
                    completed_at,
                    duration_ms,
                }
            })
            .collect()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SendError {
    #[error("connection writer is closed")]
    ConnectionClosed,
}

impl ConnectionState {
    /// Build a `ConnectionState` for tests, backed by an in-memory session.
    pub fn for_test(
        claude_pool: Arc<ClaudePool>,
        thread_index: Arc<dyn ThreadIndexHandle>,
        defaults: ThreadDefaults,
    ) -> (
        Arc<Self>,
        tokio::sync::mpsc::UnboundedReceiver<alleycat_bridge_core::session::Sequenced>,
    ) {
        let session = Arc::new(Session::new("claude", "test".into(), 64, 1 << 20));
        let attach = session.install_attachment(None);
        let state = Arc::new(Self::new(session, claude_pool, thread_index, defaults));
        (state, attach.live_rx)
    }
}
