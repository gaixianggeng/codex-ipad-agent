//! Session resilience: the producer-side state survives an iroh stream
//! detach, and a reattach replays buffered frames + outstanding server
//! requests so the client picks up mid-turn without loss.
//!
//! These tests drive [`Session`] + [`SessionRegistry`] directly rather than
//! spawning a real bridge binary; the same code paths are exercised by
//! `serve_stream_with_session` in production.

use std::sync::Arc;
use std::time::Duration;

use alleycat_bridge_core::session::{
    AttachKind, AttachOutcome, Session, SessionRegistry, SessionRegistryConfig,
};
use alleycat_bridge_core::state::ServerRequestError;
use serde_json::{Value, json};
use tokio::sync::oneshot;

fn notif(method: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": {},
    })
}

#[tokio::test]
async fn detach_then_reattach_replays_missed_frames() {
    let session = Arc::new(Session::new("pi", "node-A".into(), 64, 1 << 20));

    // First attach: drainer reads frames in real time.
    let mut a = session.install_attachment(None);
    session.enqueue(notif("turn/started"));
    session.enqueue(notif("item/started"));
    let f1 = a.live_rx.recv().await.unwrap();
    let f2 = a.live_rx.recv().await.unwrap();
    assert_eq!(f1.seq, 1);
    assert_eq!(f2.seq, 2);
    assert_eq!(f1.payload["method"], "turn/started");

    // Client disconnects.
    session.drop_attachment(session.attachment_generation());
    drop(a);

    // Producer keeps running while detached.
    session.enqueue(notif("item/completed"));
    session.enqueue(notif("turn/completed"));

    // Reattach with last_seen = 2 — must receive the frames missed during
    // the detach window.
    let b = session.install_attachment(Some(2));
    let backlog: Vec<u64> = b.backlog.iter().map(|f| f.seq).collect();
    assert_eq!(backlog, vec![3, 4]);
    let methods: Vec<&str> = b
        .backlog
        .iter()
        .filter_map(|f| f.payload["method"].as_str())
        .collect();
    assert_eq!(methods, vec!["item/completed", "turn/completed"]);
    assert!(
        b.replay_redelivery.is_none(),
        "no outstanding server requests"
    );
}

#[tokio::test]
async fn fresh_attach_after_drop_when_resume_cursor_omitted() {
    let session = Arc::new(Session::new("pi", "node-A".into(), 64, 1 << 20));
    session.enqueue(notif("event-1"));
    let _a = session.install_attachment(None);
    session.drop_attachment(session.attachment_generation());

    // Reattach without resume cursor — caller treats it as a fresh client,
    // backlog is empty even though the ring still has the frame.
    let b = session.install_attachment(None);
    assert!(b.backlog.is_empty());
}

#[tokio::test]
async fn drift_when_cursor_predates_ring_floor() {
    // Ring of 2 messages forces eviction past cursor 0.
    let session = Arc::new(Session::new("pi", "node-A".into(), 2, 1 << 20));
    let _a = session.install_attachment(None);
    session.enqueue(notif("a"));
    session.enqueue(notif("b"));
    session.enqueue(notif("c"));
    session.drop_attachment(session.attachment_generation());

    let b = session.install_attachment(Some(0));
    assert!(matches!(
        alleycat_bridge_core::session::AttachOutcome::DriftReload,
        _outcome if matches!(b.outcome, alleycat_bridge_core::session::AttachOutcome::DriftReload)
    ));
    assert!(b.backlog.is_empty());
}

#[tokio::test]
async fn outstanding_server_request_redelivered_on_reattach() {
    let session = Arc::new(Session::new("pi", "node-A".into(), 64, 1 << 20));
    let _a = session.install_attachment(None);

    // A handler issues a server→client request. The pending oneshot waits
    // for the client; the outstanding-requests table records params for
    // replay.
    let (tx, mut rx) = oneshot::channel::<Result<Value, ServerRequestError>>();
    let req_id = session.next_request_id();
    session.register_pending(
        req_id.clone(),
        "command/approve".into(),
        json!({"command": "rm -rf /", "thread_id": "t1"}),
        tx,
    );
    session.enqueue(json!({
        "jsonrpc": "2.0",
        "id": req_id,
        "method": "command/approve",
        "params": {"command": "rm -rf /", "thread_id": "t1"},
    }));
    session.enqueue(notif("turn/progress"));

    // Client disconnects mid-prompt, before answering.
    session.drop_attachment(session.attachment_generation());

    // Reattach within the grace window. After backlog replay, the drainer
    // emits a `serverRequest/replay` notification listing the still-
    // outstanding request so the new client can re-render the approval UI.
    let b = session.install_attachment(Some(0));
    let replay = b
        .replay_redelivery
        .as_ref()
        .expect("expected serverRequest/replay frame");
    assert_eq!(replay["method"], "serverRequest/replay");
    let outstanding = replay["params"]["outstanding"]
        .as_array()
        .expect("outstanding array");
    assert_eq!(outstanding.len(), 1);
    assert_eq!(outstanding[0]["id"].as_str().unwrap(), req_id);
    assert_eq!(outstanding[0]["method"], "command/approve");
    assert_eq!(outstanding[0]["params"]["command"], "rm -rf /");

    // The original pending oneshot is still alive — the new client answers
    // with the original id and the handler that was awaiting `rx` resumes.
    assert!(session.resolve_pending(&req_id, Ok(json!({"decision": "decline"}))));
    let resolved = rx.try_recv().expect("resolved");
    assert!(matches!(resolved, Ok(_)));
}

#[tokio::test]
async fn detached_session_awaiting_approval_is_never_reaped() {
    // The turn asked the user something and the phone went away. That is a
    // resting state, not a failure: the prompt waits, and the session that
    // owns it must still be there whenever they come back — however long
    // that takes.
    let cfg = SessionRegistryConfig {
        ring_max_msgs: 64,
        ring_max_bytes: 1 << 20,
        idle_ttl: Duration::from_millis(0),
        ..Default::default()
    };
    let registry = SessionRegistry::new(cfg.clone());
    let session = registry.get_or_create("node-A".into(), "pi");

    let _a = session.install_attachment(None);
    let (tx, mut rx) = oneshot::channel::<Result<Value, ServerRequestError>>();
    let req_id = session.next_request_id();
    session.register_pending(req_id, "command/approve".into(), json!({}), tx);
    session.drop_attachment(session.attachment_generation());

    // Well past idle_ttl, but the session is busy, so nothing happens to it.
    registry.tick(cfg.idle_ttl);

    assert!(registry.get("node-A", "pi").is_some());
    assert!(session.has_outstanding_requests());
    // The handler awaiting the decision was left alone.
    assert!(matches!(
        rx.try_recv(),
        Err(oneshot::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn detached_session_running_a_turn_is_never_reaped() {
    // Closing the app mid-task must not stop the task. The session lives as
    // long as the turn does, and only becomes reapable once the turn ends.
    let cfg = SessionRegistryConfig {
        idle_ttl: Duration::from_millis(0),
        ..Default::default()
    };
    let registry = SessionRegistry::new(cfg.clone());
    let session = registry.get_or_create("node-A".into(), "pi");
    let _a = session.install_attachment(None);
    session.drop_attachment(session.attachment_generation());

    let turn = session.begin_turn();
    registry.tick(cfg.idle_ttl);
    assert!(registry.get("node-A", "pi").is_some());

    // Events produced while nobody was attached are still in the ring, so a
    // client that comes back mid-turn resumes rather than starting blank.
    session.note_drainer_attempt(session.enqueue(notif("item/started")));
    session.enqueue(notif("item/completed"));
    let resolved = registry.resolve_attach("node-A".into(), "pi", Some(1));
    assert_eq!(resolved.kind, AttachKind::Resumed);
    // That client is gone again; its claim goes with it.
    drop(resolved);

    drop(turn);
    registry.tick(cfg.idle_ttl);
    assert!(registry.get("node-A", "pi").is_none());
}

#[tokio::test]
async fn registry_resolve_attach_marks_existing_resumed() {
    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    let s1 = registry.get_or_create("node-A".into(), "pi");
    s1.enqueue(notif("first"));

    let resolved = registry.resolve_attach("node-A".into(), "pi", Some(0));
    assert!(Arc::ptr_eq(&resolved.session, &s1));
    assert_eq!(resolved.kind, AttachKind::Resumed);
    assert!(resolved.current_seq >= 1);
}

#[tokio::test]
async fn registry_resolve_attach_minted_session_is_fresh_even_with_resume() {
    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    // Client claims to have a cursor but no prior session exists for this
    // (node, agent) — server treats it as Fresh; the cursor is meaningless
    // against an empty ring.
    let resolved = registry.resolve_attach("node-Z".into(), "claude", Some(42));
    assert_eq!(resolved.kind, AttachKind::Fresh);
}

#[tokio::test]
async fn auto_resume_uses_server_tracked_cursor_when_no_resume_field() {
    // The litter client today sends `Connect { v, token, agent }` with no
    // resume cursor. After an iroh disconnect + reconnect the server should
    // *still* replay anything its previous drainer didn't get to write,
    // by treating no-cursor + existing-session as auto-resume from
    // `last_attempted_seq`. Zero client-side work needed.
    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    let session = registry.get_or_create("node-A".into(), "pi");

    // Install a drainer (mimicking the real attachment). Manually mark
    // each frame as attempted, then drop the drainer — that's the
    // "previous stream died after writing seq 2" state.
    let mut a = session.install_attachment(None);
    session.enqueue(notif("turn/started"));
    session.enqueue(notif("item/started"));
    let f1 = a.live_rx.recv().await.unwrap();
    session.note_drainer_attempt(f1.seq);
    let f2 = a.live_rx.recv().await.unwrap();
    session.note_drainer_attempt(f2.seq);

    // Stream dies before the drainer gets to seq 3 / 4.
    session.drop_attachment(session.attachment_generation());
    drop(a);
    session.enqueue(notif("item/completed"));
    session.enqueue(notif("turn/completed"));

    // Client reconnects with the existing protocol — no `resume` field.
    let resolved = registry.resolve_attach("node-A".into(), "pi", None);
    assert_eq!(resolved.kind, AttachKind::Resumed);
    // Server-tracked cursor is `last_attempted - 1` = 1, so backlog
    // should include seqs 2..=4 (seq 2 is the conservative duplicate
    // for the uncertain frame, 3 and 4 are the missed ones).
    let backlog: Vec<u64> = resolved
        .session
        .install_attachment(resolved.effective_last_seen)
        .backlog
        .iter()
        .map(|f| f.seq)
        .collect();
    assert_eq!(backlog, vec![2, 3, 4]);
}

#[tokio::test]
async fn auto_resume_returns_fresh_for_brand_new_session() {
    // First-ever connect from this `(node_id, agent)`: no prior session,
    // so even if `last_seen=None` we report Fresh, not auto-resume.
    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    let resolved = registry.resolve_attach("node-NEW".into(), "pi", None);
    assert_eq!(resolved.kind, AttachKind::Fresh);
    assert!(resolved.effective_last_seen.is_none());
}

#[tokio::test]
async fn auto_resume_picks_drift_when_buffer_overflowed() {
    // Tiny ring forces the drainer's high-water mark out of the replay
    // window. Auto-resume must report DriftReload so the host's reply
    // tells the client to reload state.
    let cfg = SessionRegistryConfig {
        ring_max_msgs: 2,
        ..Default::default()
    };
    let registry = SessionRegistry::new(cfg);
    let session = registry.get_or_create("node-A".into(), "pi");
    let _a = session.install_attachment(None);
    session.note_drainer_attempt(session.enqueue(notif("a")));
    session.note_drainer_attempt(session.enqueue(notif("b")));
    session.drop_attachment(session.attachment_generation());
    // After detach, the gap continues to fill — pushes seqs that evict
    // the previously-attempted ones from the ring.
    session.enqueue(notif("c"));
    session.enqueue(notif("d"));
    session.enqueue(notif("e"));

    let resolved = registry.resolve_attach("node-A".into(), "pi", None);
    assert_eq!(resolved.kind, AttachKind::DriftReload);
}

#[tokio::test]
async fn enqueue_stamps_alleycat_seq_on_object_payloads() {
    let session = Arc::new(Session::new("pi", "node-A".into(), 16, 1 << 20));
    let mut handle = session.install_attachment(None);
    let seq = session.enqueue(notif("turn/started"));
    let received = handle.live_rx.recv().await.unwrap();
    assert_eq!(received.payload["_alleycat_seq"], seq);
    assert_eq!(received.payload["method"], "turn/started");
}

#[tokio::test]
async fn enqueue_does_not_stamp_non_object_payloads() {
    // Defensive: a stray non-object enqueue (e.g. a bare null) should not
    // panic and should pass through untouched.
    let session = Arc::new(Session::new("pi", "node-A".into(), 16, 1 << 20));
    let mut handle = session.install_attachment(None);
    let seq = session.enqueue(json!(null));
    let received = handle.live_rx.recv().await.unwrap();
    assert_eq!(received.payload, Value::Null);
    let _ = seq;
}

#[tokio::test]
async fn second_attach_preempts_first() {
    let session = Arc::new(Session::new("pi", "node-A".into(), 64, 1 << 20));
    let mut first = session.install_attachment(None);
    let mut second = session.install_attachment(None);
    session.enqueue(notif("post-preempt"));

    // First's live_rx closes — its tx was dropped on replace.
    assert!(first.live_rx.recv().await.is_none());
    // Second sees the new frame.
    let frame = second.live_rx.recv().await.unwrap();
    assert_eq!(frame.payload["method"], "post-preempt");
}

#[tokio::test]
async fn busy_session_nobody_can_reach_is_eventually_reclaimed() {
    // Waiting forever is right for a user who will come back. It is not right
    // for a session that has become unreachable — the client reinstalled, or
    // lost the key that names it — because that one pins its ring and its
    // agent process for the life of the daemon.
    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    let weak = {
        let session = registry.get_or_create("node-gone".into(), "pi");
        let handle = session.install_attachment(None);
        let (tx, mut rx) = oneshot::channel::<Result<Value, ServerRequestError>>();
        let req_id = session.next_request_id();
        session.register_pending(req_id, "command/approve".into(), json!({}), tx);
        let turn = session.begin_turn();
        session.drop_attachment(handle.generation);

        // Under the backstop, a waiting approval keeps it indefinitely.
        registry.tick_with(Duration::from_millis(0), Duration::from_secs(24 * 60 * 60));
        assert!(registry.get("node-gone", "pi").is_some());
        assert!(matches!(
            rx.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));

        // Past it, the abandoned session is reclaimed even though it reads
        // busy. Dropping the registry's Arc frees nothing on its own — the
        // waiting handler still holds the session — so the reclaim has to
        // actually unwind what is attached to it.
        registry.tick_with(Duration::from_millis(0), Duration::from_millis(0));
        assert!(registry.get("node-gone", "pi").is_none());

        // The handler awaiting the approval is released, not left hanging.
        assert!(matches!(
            rx.try_recv(),
            Ok(Err(ServerRequestError::ConnectionClosed))
        ));
        assert!(!session.has_outstanding_requests());
        // And a turn still running is told to wind down.
        assert!(session.is_cancelled());
        session.cancelled().await;

        drop(turn);
        Arc::downgrade(&session)
    };

    // Nothing is holding the session any more: it is genuinely reclaimed, not
    // merely unreachable.
    assert!(
        weak.upgrade().is_none(),
        "被回收的会话仍被持有，ring 和进程槽位不会释放"
    );
}

#[tokio::test]
async fn reaper_cannot_drop_a_session_being_picked_up() {
    // The reaper fires in the gap between a client claiming the session and
    // installing its attachment — the ack is still going out, so the session
    // reads as detached and idle. Dropping it there leaves the connection
    // serving from an Arc that is no longer registered, and the next
    // reconnect mints a blank session instead of resuming.
    let cfg = SessionRegistryConfig {
        idle_ttl: Duration::from_millis(0),
        ..Default::default()
    };
    let registry = SessionRegistry::new(cfg.clone());
    let seeded = registry.get_or_create("node-A".into(), "pi");
    let first = seeded.install_attachment(None);
    seeded.note_drainer_attempt(seeded.enqueue(notif("turn/started")));
    seeded.drop_attachment(first.generation);

    // Claimed but not yet attached — exactly the ack window.
    let resolved = registry.resolve_attach("node-A".into(), "pi", Some(0));
    assert_eq!(resolved.kind, AttachKind::Resumed);
    registry.tick(cfg.idle_ttl);

    let still_there = registry
        .get("node-A", "pi")
        .expect("正在被接管的会话不能被回收");
    assert!(
        Arc::ptr_eq(&still_there, &resolved.session),
        "注册表里必须还是同一个会话，否则重连拿到的是空白会话"
    );

    // Once the connection is done, it becomes reapable again.
    drop(resolved);
    registry.tick(cfg.idle_ttl);
    assert!(registry.get("node-A", "pi").is_none());
}

#[tokio::test]
async fn approval_publishing_cannot_interleave_with_a_reattach() {
    // Registering the request and putting it on the wire must look atomic to
    // a reattach. Landing between them, the client would get the replay
    // snapshot (already outstanding) and then the live original (enqueued
    // after) — the same prompt twice, the second by the ordinary request
    // path a client may answer on its own.
    let session = Arc::new(Session::new("pi", "node-A".into(), 64, 1 << 20));
    let first = session.install_attachment(None);
    session.note_drainer_attempt(session.enqueue(notif("turn/started")));
    session.drop_attachment(first.generation);

    let req_id = session.next_request_id();
    let (tx, _rx) = oneshot::channel::<Result<Value, ServerRequestError>>();
    session.publish_server_request(
        req_id.clone(),
        "item/commandExecution/requestApproval".into(),
        json!({"command": "cargo install"}),
        tx,
        json!({
            "jsonrpc": "2.0",
            "id": req_id.clone(),
            "method": "item/commandExecution/requestApproval",
            "params": {"command": "cargo install"},
        }),
    );

    let handle = session.install_attachment(Some(1));
    let from_backlog = handle
        .backlog
        .iter()
        .filter(|frame| frame.payload.get("id").and_then(Value::as_str) == Some(req_id.as_str()))
        .count();
    assert_eq!(from_backlog, 0, "审批不应同时从 backlog 再来一份");
    let replay = handle.replay_redelivery.expect("审批应通过 replay 恢复");
    assert_eq!(replay["params"]["outstanding"][0]["id"], json!(req_id));
}

#[tokio::test]
async fn approval_raised_while_detached_is_restored_exactly_once() {
    // The turn asked for approval after the phone dropped off. The prompt is
    // now in two places — the ring, because it was enqueued like any frame,
    // and the outstanding table. The reattaching client must see it once: a
    // second copy arrives as an ordinary server request, and a client that
    // has not rehydrated yet may answer it upstream on its own, leaving the
    // replay card pointing at a request that is already resolved.
    let session = Arc::new(Session::new("pi", "node-A".into(), 64, 1 << 20));
    let first = session.install_attachment(None);
    session.note_drainer_attempt(session.enqueue(notif("turn/started")));
    session.drop_attachment(first.generation);

    // Disconnected: the turn runs on and raises an approval.
    session.enqueue(notif("item/started"));
    let (tx, _rx) = oneshot::channel::<Result<Value, ServerRequestError>>();
    let req_id = session.next_request_id();
    let approval = json!({
        "jsonrpc": "2.0",
        "id": req_id.clone(),
        "method": "item/commandExecution/requestApproval",
        "params": {"threadId": "thr_1", "command": "cargo install"},
    });
    session.register_pending(
        req_id.clone(),
        "item/commandExecution/requestApproval".into(),
        json!({"threadId": "thr_1", "command": "cargo install"}),
        tx,
    );
    session.enqueue(approval);

    let handle = session.install_attachment(Some(1));
    assert_eq!(handle.outcome, AttachOutcome::Resumed);

    let replayed_requests = handle
        .backlog
        .iter()
        .filter(|frame| frame.payload.get("id").and_then(Value::as_str) == Some(req_id.as_str()))
        .count();
    assert_eq!(
        replayed_requests, 0,
        "未应答的审批不应再从 backlog 走一遍：{:?}",
        handle.backlog
    );
    // 其余事件照常补播。
    assert!(
        handle
            .backlog
            .iter()
            .any(|frame| frame.payload["method"] == "item/started"),
        "普通事件仍须补播：{:?}",
        handle.backlog
    );

    let replay = handle
        .replay_redelivery
        .expect("待应答审批应通过 replay 恢复");
    let entries = replay["params"]["outstanding"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["id"], json!(req_id));
    assert_eq!(
        entries[0]["method"],
        "item/commandExecution/requestApproval"
    );
}

#[tokio::test]
async fn preempted_connection_cannot_detach_its_successor() {
    // The phone reconnects over a dead-but-not-yet-noticed socket. When the
    // old reader finally unblocks and tears itself down, it must not take the
    // new client's stream with it — nor mark the session detached, which
    // would offer a session someone is actively using to the reaper.
    let session = Arc::new(Session::new("pi", "node-A".into(), 64, 1 << 20));
    let stale = session.install_attachment(None);
    let mut live = session.install_attachment(None);

    assert!(!session.drop_attachment(stale.generation));
    assert!(session.is_attached());
    assert!(!session.detached_for(Duration::from_millis(0)));

    session.enqueue(notif("still-flowing"));
    let frame = live.live_rx.recv().await.unwrap();
    assert_eq!(frame.payload["method"], "still-flowing");

    // The current owner still detaches normally.
    assert!(session.drop_attachment(live.generation));
    assert!(!session.is_attached());
}
