//! `SessionRegistry` — the daemon-lifetime owner of all live sessions, keyed
//! by `(node_id, agent)`. Concurrent map operations use a coarse `Mutex`; the
//! contention is fine for our scale (handful of clients × four agents).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use crate::session::{AgentId, AttachOutcome, AttachReservation, NodeId, Session};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachKind {
    /// No prior session existed for `(node_id, agent)`; one was minted.
    Fresh,
    /// A live session existed and the cursor was within the replay window.
    Resumed,
    /// A live session existed but the cursor was below the floor — the
    /// caller should treat this as Fresh and the client must reload state.
    DriftReload,
}

impl From<AttachOutcome> for AttachKind {
    fn from(value: AttachOutcome) -> Self {
        match value {
            AttachOutcome::Fresh => Self::Fresh,
            AttachOutcome::Resumed => Self::Resumed,
            AttachOutcome::DriftReload => Self::DriftReload,
        }
    }
}

#[derive(Debug)]
pub struct ResolvedAttach {
    pub session: Arc<Session>,
    pub kind: AttachKind,
    pub current_seq: u64,
    pub floor_seq: u64,
    /// Holds the session against the reaper until the caller drops it. Keep
    /// it alive for at least as long as it takes to install the attachment —
    /// the ack goes out in between, and until then the session still looks
    /// detached and idle.
    pub reservation: AttachReservation,
    /// Cursor that should be threaded into `Session::install_attachment`.
    ///
    /// Differs from the client's supplied `last_seen` in one case: when the
    /// client sends no resume cursor but a prior session exists for
    /// `(node_id, agent)`, the registry auto-supplies
    /// `last_attempted_seq.saturating_sub(1)` as the cursor — so a litter
    /// client that calls plain `Connect { v, token, agent }` after an iroh
    /// drop still gets mid-turn replay without knowing about resume.
    pub effective_last_seen: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct SessionRegistryConfig {
    pub ring_max_msgs: usize,
    pub ring_max_bytes: usize,
    /// How long a session with **no work in flight** may sit unattached
    /// before it is dropped. It is not a cap on how long a task may run: a
    /// session running a turn, or holding an approval prompt, is never idle
    /// no matter how long its client has been gone.
    pub idle_ttl: Duration,
    /// Backstop for a busy session whose client never comes back at all.
    ///
    /// Waiting indefinitely is the intended behaviour for someone who closed
    /// the app and will return — but a session can also become permanently
    /// unreachable, because the client reinstalled, lost the stored key, or
    /// changed it. Such a session would otherwise hold its ring and its agent
    /// process forever. Set far beyond any real "I'll deal with it later", so
    /// it only ever catches the abandoned case.
    pub busy_hard_ttl: Duration,
}

impl Default for SessionRegistryConfig {
    fn default() -> Self {
        Self {
            ring_max_msgs: 2048,
            ring_max_bytes: 16 << 20,
            idle_ttl: Duration::from_secs(600),
            busy_hard_ttl: Duration::from_secs(24 * 60 * 60),
        }
    }
}

#[derive(Debug)]
pub struct SessionRegistry {
    inner: Mutex<HashMap<(NodeId, AgentId), Arc<Session>>>,
    config: SessionRegistryConfig,
}

impl SessionRegistry {
    pub fn new(config: SessionRegistryConfig) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(HashMap::new()),
            config,
        })
    }

    pub fn config(&self) -> &SessionRegistryConfig {
        &self.config
    }

    /// Lookup an existing session keyed by `(node_id, agent)`. The session
    /// stays in the registry; the caller gets a fresh `Arc`.
    pub fn get(&self, node_id: &str, agent: AgentId) -> Option<Arc<Session>> {
        let inner = self.inner.lock().unwrap();
        inner.get(&(node_id.to_string(), agent)).cloned()
    }

    /// Get-or-create the session for `(node_id, agent)`. Does not install an
    /// attachment — caller does that via `Session::install_attachment` after
    /// resolving the resume cursor.
    pub fn get_or_create(&self, node_id: NodeId, agent: AgentId) -> Arc<Session> {
        let mut inner = self.inner.lock().unwrap();
        inner
            .entry((node_id.clone(), agent))
            .or_insert_with(|| {
                Arc::new(Session::new(
                    agent,
                    node_id,
                    self.config.ring_max_msgs,
                    self.config.ring_max_bytes,
                ))
            })
            .clone()
    }

    /// Resolve a `Connect` attach: get-or-create the session, decide
    /// `Fresh` / `Resumed` / `DriftReload`, and snapshot `(current_seq,
    /// floor_seq)` for the response. Does **not** install the attachment;
    /// the caller threads the same `last_seen` into
    /// `Session::install_attachment` later (the bridge dispatcher does this
    /// inside `serve_stream_with_session`).
    pub fn resolve_attach(
        &self,
        node_id: NodeId,
        agent: AgentId,
        last_seen: Option<u64>,
    ) -> ResolvedAttach {
        let (session, was_existing, reservation) = {
            let mut inner = self.inner.lock().unwrap();
            let key = (node_id.clone(), agent);
            let (session, was_existing) = if let Some(existing) = inner.get(&key) {
                (existing.clone(), true)
            } else {
                let fresh = Arc::new(Session::new(
                    agent,
                    node_id,
                    self.config.ring_max_msgs,
                    self.config.ring_max_bytes,
                ));
                inner.insert(key, fresh.clone());
                (fresh, false)
            };
            // Claim it before releasing the registry lock, so a reaper tick
            // cannot slip in and drop a session this caller has already been
            // handed.
            let reservation = session.reserve_attach();
            (session, was_existing, reservation)
        };
        let (current_seq, floor_seq) = session.peek_seq();

        // Effective cursor used to pick the replay slice. For an existing
        // session where the client didn't carry a resume hint, the server
        // auto-resumes from what its previous drainer last attempted —
        // letting an unmodified litter client get mid-turn replay for free.
        let effective_last_seen: Option<u64> = match (was_existing, last_seen) {
            (false, _) => None,
            (true, Some(cursor)) => Some(cursor),
            (true, None) => Some(session.last_attempted_seq().saturating_sub(1)),
        };

        let kind = match (was_existing, effective_last_seen) {
            (false, _) => AttachKind::Fresh,
            (true, None) => AttachKind::Fresh,
            (true, Some(cursor)) => match session.peek_replay(cursor) {
                Ok(()) => AttachKind::Resumed,
                Err(_) => AttachKind::DriftReload,
            },
        };

        ResolvedAttach {
            session,
            kind,
            current_seq,
            floor_seq,
            effective_last_seen,
            reservation,
        }
    }

    /// Drop the session for `(node_id, agent)` if present.
    pub fn release(&self, node_id: &str, agent: AgentId) -> Option<Arc<Session>> {
        let mut inner = self.inner.lock().unwrap();
        inner.remove(&(node_id.to_string(), agent))
    }

    /// Snapshot live sessions — used by the reaper to scan for idle/grace
    /// expiry without holding the registry lock across awaits.
    pub fn snapshot(&self) -> Vec<Arc<Session>> {
        self.inner.lock().unwrap().values().cloned().collect()
    }

    /// Spawn a background task that periodically drops sessions detached
    /// longer than `idle_ttl` that have no work in flight.
    ///
    /// Returns the task handle so the daemon can join on shutdown. Holds a
    /// `Weak` to the registry so dropping the registry stops the reaper.
    pub fn spawn_reaper(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let weak = Arc::downgrade(self);
        let idle_ttl = self.config.idle_ttl;
        let busy_hard_ttl = self.config.busy_hard_ttl;
        // Sweep on a coarse interval — the work is cheap and timing precision
        // matters less than not waking up needlessly.
        let interval =
            std::cmp::min(idle_ttl / 4, Duration::from_secs(30)).max(Duration::from_secs(1));
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(interval).await;
                let Some(registry) = weak.upgrade() else {
                    break;
                };
                registry.tick_with(idle_ttl, busy_hard_ttl);
            }
        })
    }

    /// One reaper tick at the configured hard TTL. Public for tests so we can
    /// drive deterministic expiry without sleeping.
    ///
    /// Losing the client is not a reason to tear anything down. A session is
    /// dropped only once it is both unattached past `idle_ttl` and idle in
    /// the real sense — no turn running, no approval waiting on a human.
    /// Closing the app mid-task, or leaving an approval unanswered overnight,
    /// leaves the work exactly where it was; the session is reachable again
    /// by attaching with the same key.
    pub fn tick(&self, idle_ttl: Duration) {
        self.tick_with(idle_ttl, self.config.busy_hard_ttl);
    }

    /// As [`Self::tick`], with an explicit backstop for sessions that stay
    /// busy. A session nobody can reach any more — the client reinstalled,
    /// or lost the key naming it — would otherwise pin its ring and its agent
    /// process for the life of the daemon.
    pub fn tick_with(&self, idle_ttl: Duration, busy_hard_ttl: Duration) {
        // Decide and remove inside one critical section. Collecting keys,
        // releasing the lock and then deleting unconditionally would drop
        // sessions that became live in between — the phone reconnecting is
        // exactly the moment a long-idle session stops being idle.
        let mut abandoned: Vec<Arc<Session>> = Vec::new();
        {
            let mut inner = self.inner.lock().unwrap();
            inner.retain(|_, session| {
                if session.detached_for(busy_hard_ttl) && !session.has_pending_attach() {
                    // Only the hard backstop reclaims a session that still has
                    // work attached to it, so only it has anything to unwind.
                    if session.is_busy() {
                        abandoned.push(Arc::clone(session));
                    }
                    return false;
                }
                !session.detached_for(idle_ttl) || session.is_busy()
            });
        }
        // Outside the registry lock: cancelling wakes handlers that may reach
        // back into the session, and there is no reason to hold up other
        // attaches while they unwind.
        for session in abandoned {
            session.cancel();
        }
    }
}

/// Weak handle, used by callers that want to participate in registry
/// lifecycle without keeping it alive (e.g. logging tasks).
#[allow(dead_code)]
pub type SessionRegistryWeak = Weak<SessionRegistry>;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use tokio::sync::oneshot;

    fn notif(method: &str) -> Value {
        serde_json::json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": {},
        })
    }

    #[test]
    fn get_or_create_is_idempotent() {
        let reg = SessionRegistry::new(SessionRegistryConfig::default());
        let a = reg.get_or_create("node-abc".into(), "pi");
        let b = reg.get_or_create("node-abc".into(), "pi");
        assert!(Arc::ptr_eq(&a, &b));
    }

    #[test]
    fn separate_keys_distinct_sessions() {
        let reg = SessionRegistry::new(SessionRegistryConfig::default());
        let a = reg.get_or_create("node-abc".into(), "pi");
        let b = reg.get_or_create("node-abc".into(), "claude");
        let c = reg.get_or_create("node-xyz".into(), "pi");
        assert!(!Arc::ptr_eq(&a, &b));
        assert!(!Arc::ptr_eq(&a, &c));
    }

    #[test]
    fn tick_drops_idle_unattached_sessions() {
        let reg = SessionRegistry::new(SessionRegistryConfig::default());
        let session = reg.get_or_create("node-abc".into(), "pi");
        // Attach + immediately detach so detached_at is set.
        let _h = session.install_attachment(None);
        session.drop_attachment(session.attachment_generation());
        // Zero ttl so the session expires immediately.
        reg.tick(Duration::from_millis(0));
        assert!(reg.get("node-abc", "pi").is_none());
    }

    #[test]
    fn tick_does_not_drop_attached_session() {
        let reg = SessionRegistry::new(SessionRegistryConfig::default());
        let session = reg.get_or_create("node-abc".into(), "pi");
        let _handle = session.install_attachment(None);
        session.enqueue(notif("a"));
        reg.tick(Duration::from_millis(0));
        assert!(reg.get("node-abc", "pi").is_some());
    }

    #[test]
    fn tick_keeps_detached_session_with_a_turn_running() {
        // The app was closed mid-task. Nothing about that means the task
        // should stop, so the session stays until the turn releases it.
        let reg = SessionRegistry::new(SessionRegistryConfig::default());
        let session = reg.get_or_create("node-abc".into(), "pi");
        let _h = session.install_attachment(None);
        session.drop_attachment(session.attachment_generation());
        let turn = session.begin_turn();

        reg.tick(Duration::from_millis(0));
        assert!(reg.get("node-abc", "pi").is_some());

        drop(turn);
        reg.tick(Duration::from_millis(0));
        assert!(reg.get("node-abc", "pi").is_none());
    }

    #[test]
    fn tick_keeps_pending_approval_alive_indefinitely() {
        // "Needs the user" is a resting state, not a failure: the prompt has
        // to still be there whenever they get back to their phone, and it is
        // replayed to them on reattach.
        let reg = SessionRegistry::new(SessionRegistryConfig::default());
        let session = reg.get_or_create("node-abc".into(), "pi");
        let (tx, mut rx) = oneshot::channel();
        session.register_pending(
            "r-1".into(),
            "command/approve".into(),
            serde_json::json!({}),
            tx,
        );
        let _h = session.install_attachment(None);
        session.drop_attachment(session.attachment_generation());

        reg.tick(Duration::from_millis(0));
        assert!(reg.get("node-abc", "pi").is_some());
        assert!(session.has_outstanding_requests());
        // The waiting handler is still waiting — nothing cancelled it.
        assert!(matches!(
            rx.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
    }
}
