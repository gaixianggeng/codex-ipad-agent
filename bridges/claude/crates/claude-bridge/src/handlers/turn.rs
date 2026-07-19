//! `turn/*` and `review/*` request handlers + the per-turn event pump.
//!
//! Flow on `turn/start`:
//! 1. Look up the claude process for `thread_id`; a locally-created empty
//!    thread starts its process lazily on the first valid user input.
//! 2. Translate `UserInput[]` → claude stream-json user envelope and write
//!    it to stdin.
//! 3. Mint a fresh codex `turn_id`, register it in [`ACTIVE_TURNS`], and
//!    mark the pool entry active so the LRU reaper leaves it alone.
//! 4. Subscribe to the broadcast event channel BEFORE writing the prompt
//!    so we don't miss the first event.
//! 5. Spawn a background pump task that runs every event through
//!    [`EventTranslatorState::translate`] and forwards the resulting
//!    notifications to the codex client. The pump exits on the terminal
//!    `result` envelope and emits `turn/completed`.
//!
//! `turn/steer` writes another user envelope on stdin while a turn is in
//! flight; the existing pump folds the new events into the same `turn_id`.
//!
//! `turn/interrupt` sends SIGINT to the claude child (Unix) or
//! `child.start_kill()` (Windows) and waits for the pump to emit a Failed
//! `turn/completed`.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::Mutex as SyncMutex;
use std::time::{Duration, SystemTime};

use thiserror::Error;
use tokio::sync::Mutex as AsyncMutex;
use tokio::sync::broadcast;
use uuid::Uuid;

use alleycat_codex_proto as p;

use crate::approval;
use crate::handlers::model::{normalize_claude_model, normalize_claude_model_id};
use crate::handlers::thread::resume_cwd_or_fallback;
use crate::pool::ClaudeProcessHandle;
use crate::pool::claude_protocol::{ClaudeEvent, ClaudeOutbound, ControlRequestBody};
use crate::pool::process::ClaudeProcessError;
use crate::state::ConnectionState;
use crate::translate::events::{EventTranslatorState, turn_status_from_result};
use crate::translate::input::translate_user_input;

/// Time the bridge gives claude to acknowledge a `control_request{interrupt}`.
/// Empirically the SDK uses no timeout (it `await`s indefinitely), but we cap
/// at 5s so a stuck claude doesn't pin the connection. After timeout we fall
/// back to SIGINT/shutdown so the codex client gets `turn/completed{Failed}`.
const CONTROL_INTERRUPT_TIMEOUT: Duration = Duration::from_secs(5);

/// Time the bridge gives claude to acknowledge a runtime config setter
/// (`set_model`, `set_max_thinking_tokens`, `set_permission_mode`). Setters
/// are usually fast (~tens of ms) — keep this tight so a wedged claude
/// surfaces as an error rather than hanging the turn handler.
const CONTROL_SET_TIMEOUT: Duration = Duration::from_secs(5);

/// Map codex `ReasoningEffort` onto a `--max-thinking-tokens` budget. Values
/// match the conventions the Anthropic SDK ships with (extended-thinking docs)
/// — tweak in lockstep with `pi-bridge`'s `ThinkingLevel` if those drift.
fn effort_to_thinking_tokens(effort: p::ReasoningEffort) -> u32 {
    match effort {
        p::ReasoningEffort::None => 0,
        p::ReasoningEffort::Minimal => 1024,
        p::ReasoningEffort::Low => 4096,
        p::ReasoningEffort::Medium => 16_384,
        p::ReasoningEffort::High => 32_768,
        // codex uses XHigh only on a few gpt-5.x models; claude has no
        // direct equivalent so we cap at the High budget.
        p::ReasoningEffort::XHigh => 32_768,
        p::ReasoningEffort::Max => 32_768,
    }
}

/// 将移动端三档权限映射为 Claude Code 的运行时权限模式。
/// 沙箱只读优先级最高；只有明确的自动审批组合才启用 `auto`。
fn claude_permission_mode(params: &p::TurnStartParams) -> &'static str {
    if params.sandbox_policy.as_ref().is_some_and(is_read_only) {
        return "plan";
    }
    if matches!(params.approval_policy, Some(p::AskForApproval::OnFailure))
        && matches!(
            params.approvals_reviewer,
            Some(p::ApprovalsReviewer::AutoReview)
        )
    {
        return "auto";
    }
    "default"
}

fn is_read_only(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::String(mode) => matches!(mode.as_str(), "read-only" | "readOnly"),
        serde_json::Value::Object(map) => map
            .get("type")
            .or_else(|| map.get("mode"))
            .is_some_and(is_read_only),
        _ => false,
    }
}

/// Per-thread active-turn registry. Claude only allows one active turn per
/// process. Keyed by codex `thread_id`.
static ACTIVE_TURNS: LazyLock<SyncMutex<HashMap<String, ActiveTurn>>> =
    LazyLock::new(|| SyncMutex::new(HashMap::new()));

#[derive(Clone)]
struct ActiveTurn {
    turn_id: String,
}

#[derive(Debug, Error)]
pub enum TurnError {
    #[error("invalid params: {0}")]
    InvalidParams(String),
    #[error("thread `{0}` is not loaded; call thread/start or thread/resume first")]
    ThreadNotLoaded(String),
    #[error("expected_turn_id `{expected}` does not match active turn `{actual}`")]
    TurnIdMismatch { expected: String, actual: String },
    #[error("no active turn for thread `{0}`")]
    NoActiveTurn(String),
    #[error("input translation failed: {0}")]
    InputTranslation(String),
    #[error("claude rpc error: {0}")]
    ClaudeRpc(String),
    #[error("review/start is not implemented in claude-bridge v1")]
    ReviewUnsupported,
}

impl TurnError {
    pub fn rpc_code(&self) -> i64 {
        match self {
            TurnError::InvalidParams(_)
            | TurnError::TurnIdMismatch { .. }
            | TurnError::ThreadNotLoaded(_)
            | TurnError::NoActiveTurn(_)
            | TurnError::InputTranslation(_) => p::error_codes::INVALID_PARAMS,
            TurnError::ReviewUnsupported => p::error_codes::METHOD_NOT_FOUND,
            TurnError::ClaudeRpc(_) => p::error_codes::INTERNAL_ERROR,
        }
    }
}

// ============================================================================
// turn/start
// ============================================================================

pub async fn handle_turn_start(
    state: &Arc<ConnectionState>,
    params: p::TurnStartParams,
) -> Result<p::TurnStartResponse, TurnError> {
    let envelope = translate_user_input(&params.input)
        .map_err(|e| TurnError::InputTranslation(e.to_string()))?;

    let handle = match state.claude_pool().get(&params.thread_id).await {
        Some(handle) => handle,
        None => {
            let entry = state
                .thread_index()
                .lookup(&params.thread_id)
                .await
                .ok_or_else(|| TurnError::ThreadNotLoaded(params.thread_id.clone()))?;
            let cwd =
                resume_cwd_or_fallback(&entry.cwd, &params.thread_id, state.trust_persisted_cwd());
            let defaults = state.defaults();
            let model =
                normalize_claude_model(params.model.clone().or_else(|| defaults.model.clone()));
            // 本地可直接以 transcript 是否存在区分新线程和恢复线程。远程线程仍会在
            // thread/start/resume 预启动；这里的 preview 判断只负责进程意外退出后的兜底。
            let resume = if state.trust_persisted_cwd() {
                !entry.preview.trim().is_empty() || !state.thread_log(&params.thread_id).is_empty()
            } else {
                entry.metadata.claude_session_path.is_file()
            };
            state
                .claude_pool()
                .acquire_for_thread(
                    params.thread_id.clone(),
                    &cwd,
                    resume,
                    model,
                    defaults.system_prompt.clone(),
                )
                .await
                .map_err(|err| TurnError::ClaudeRpc(format!("starting claude process: {err:#}")))?
        }
    };

    // Apply per-turn runtime overrides via in-band control_requests BEFORE
    // writing the user envelope. The handle diffs against its cached state so
    // a turn that doesn't change the model/effort is a no-op (zero RTT).
    let normalized_model_override = params.model.as_deref().map(normalize_claude_model_id);
    let model_override = normalized_model_override.as_deref();
    let thinking_override = params.effort.map(effort_to_thinking_tokens);
    let permission_mode = claude_permission_mode(&params);
    if let Err(err) = handle
        .apply_runtime_overrides(
            model_override,
            thinking_override,
            Some(permission_mode),
            CONTROL_SET_TIMEOUT,
        )
        .await
    {
        return Err(TurnError::ClaudeRpc(format!(
            "applying runtime overrides: {err}"
        )));
    }

    let turn_id = Uuid::now_v7().to_string();
    register_active_turn(&params.thread_id, &turn_id);
    state.claude_pool().mark_active(&params.thread_id).await;

    let started_at = now_unix_secs();
    // Codex emits `startedAt: null` on the turn/start response but
    // populates it on the turn/started notification.
    let turn_for_notif = p::Turn {
        id: turn_id.clone(),
        items: Vec::new(),
        items_view: p::default_items_view(),
        status: p::TurnStatus::InProgress,
        error: None,
        started_at: Some(started_at),
        completed_at: None,
        duration_ms: None,
    };
    let mut turn = turn_for_notif.clone();
    turn.started_at = None;

    if state.should_emit("turn/started") {
        let frame = notification_frame(p::ServerNotification::TurnStarted(
            p::TurnStartedNotification {
                thread_id: params.thread_id.clone(),
                turn: turn_for_notif,
            },
        ));
        let _ = state.send(frame);
    }
    state.record_turn_started(&params.thread_id, turn_id.clone(), started_at);

    // Echo the user input back as a userMessage item lifecycle (codex
    // does this; see codex-rs app-server-protocol/src/protocol/v2.rs:5330).
    // Clients reconstruct history from these events.
    let user_message_item = p::ThreadItem::UserMessage {
        id: Uuid::now_v7().to_string(),
        content: params.input.clone(),
    };
    if state.should_emit("item/started") {
        let frame = notification_frame(p::ServerNotification::ItemStarted(
            p::ItemStartedNotification {
                item: user_message_item.clone(),
                thread_id: params.thread_id.clone(),
                turn_id: turn_id.clone(),
                parent_item_id: None,
            },
        ));
        let _ = state.send(frame);
    }
    if state.should_emit("item/completed") {
        let frame = notification_frame(p::ServerNotification::ItemCompleted(
            p::ItemCompletedNotification {
                item: user_message_item.clone(),
                thread_id: params.thread_id.clone(),
                turn_id: turn_id.clone(),
                parent_item_id: None,
            },
        ));
        let _ = state.send(frame);
    }
    state.record_item(&params.thread_id, &turn_id, user_message_item);

    // Subscribe BEFORE writing the prompt so the first event isn't lost.
    let events_rx = handle.subscribe_events();

    if let Err(e) = handle.send_serialized(&envelope) {
        clear_active_turn(&params.thread_id);
        state.claude_pool().mark_idle(&params.thread_id).await;
        return Err(TurnError::ClaudeRpc(e.to_string()));
    }

    spawn_event_pump(EventPumpArgs {
        state: Arc::clone(state),
        thread_id: params.thread_id.clone(),
        turn_id: turn_id.clone(),
        handle: Arc::clone(&handle),
        events_rx,
        started_at,
    });

    Ok(p::TurnStartResponse { turn })
}

// ============================================================================
// turn/steer
// ============================================================================

pub async fn handle_turn_steer(
    state: &Arc<ConnectionState>,
    params: p::TurnSteerParams,
) -> Result<p::TurnSteerResponse, TurnError> {
    let handle = state
        .claude_pool()
        .get(&params.thread_id)
        .await
        .ok_or_else(|| TurnError::ThreadNotLoaded(params.thread_id.clone()))?;

    let active = active_turn(&params.thread_id)
        .ok_or_else(|| TurnError::NoActiveTurn(params.thread_id.clone()))?;
    if active.turn_id != params.expected_turn_id {
        return Err(TurnError::TurnIdMismatch {
            expected: params.expected_turn_id,
            actual: active.turn_id,
        });
    }

    let envelope = translate_user_input(&params.input)
        .map_err(|e| TurnError::InputTranslation(e.to_string()))?;
    handle
        .send_serialized(&envelope)
        .map_err(|e| TurnError::ClaudeRpc(e.to_string()))?;
    Ok(p::TurnSteerResponse {
        turn_id: active.turn_id,
    })
}

// ============================================================================
// turn/interrupt
// ============================================================================

pub async fn handle_turn_interrupt(
    state: &Arc<ConnectionState>,
    params: p::TurnInterruptParams,
) -> Result<p::TurnInterruptResponse, TurnError> {
    let handle = state
        .claude_pool()
        .get(&params.thread_id)
        .await
        .ok_or_else(|| TurnError::ThreadNotLoaded(params.thread_id.clone()))?;
    if let Some(active) = active_turn(&params.thread_id) {
        if active.turn_id != params.turn_id {
            return Err(TurnError::TurnIdMismatch {
                expected: params.turn_id,
                actual: active.turn_id,
            });
        }
    }
    interrupt_handle(&handle).await;
    Ok(p::TurnInterruptResponse::default())
}

/// Aborts the in-flight turn the SDK way: `control_request{subtype:"interrupt"}`
/// over stdin, awaits the matching success response. On any failure (timeout,
/// claude reports error, transport down) falls back to a hard process kill so
/// the codex client still sees `turn/completed{Failed}`. Cross-platform —
/// works on Unix and Windows without the `nix` SIGINT path.
async fn interrupt_handle(handle: &Arc<ClaudeProcessHandle>) {
    match handle
        .request_control(ControlRequestBody::Interrupt, CONTROL_INTERRUPT_TIMEOUT)
        .await
    {
        Ok(_) => tracing::debug!(thread_id = %handle.thread_id(), "interrupt acked"),
        Err(ClaudeProcessError::ControlError { message, .. }) => {
            tracing::warn!(
                thread_id = %handle.thread_id(),
                %message,
                "claude rejected interrupt control_request; killing process",
            );
            handle.shutdown().await;
        }
        Err(err) => {
            tracing::warn!(
                thread_id = %handle.thread_id(),
                ?err,
                "interrupt control_request failed; killing process",
            );
            handle.shutdown().await;
        }
    }
}

// ============================================================================
// review/start
// ============================================================================

pub async fn handle_review_start(
    _state: &Arc<ConnectionState>,
    _params: p::ReviewStartParams,
) -> Result<p::ReviewStartResponse, TurnError> {
    Err(TurnError::ReviewUnsupported)
}

// ============================================================================
// helpers + event pump
// ============================================================================

fn now_unix_secs() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn register_active_turn(thread_id: &str, turn_id: &str) {
    ACTIVE_TURNS.lock().unwrap().insert(
        thread_id.to_string(),
        ActiveTurn {
            turn_id: turn_id.to_string(),
        },
    );
}

fn active_turn(thread_id: &str) -> Option<ActiveTurn> {
    ACTIVE_TURNS.lock().unwrap().get(thread_id).cloned()
}

fn clear_active_turn(thread_id: &str) {
    ACTIVE_TURNS.lock().unwrap().remove(thread_id);
}

fn notification_frame(notif: p::ServerNotification) -> p::JsonRpcMessage {
    let value = serde_json::to_value(&notif).expect("ServerNotification serializes");
    let method = value
        .get("method")
        .and_then(|m| m.as_str())
        .unwrap_or_default()
        .to_string();
    let params = value.get("params").cloned();
    p::JsonRpcMessage::Notification(p::JsonRpcNotification {
        jsonrpc: p::JsonRpcVersion,
        method,
        params,
    })
}

struct EventPumpArgs {
    state: Arc<ConnectionState>,
    thread_id: String,
    turn_id: String,
    /// Held by the pump so it can reply to inbound `control_request` envelopes
    /// (e.g. `can_use_tool` HITL prompts) on the same process that sent them.
    handle: Arc<ClaudeProcessHandle>,
    events_rx: broadcast::Receiver<ClaudeEvent>,
    started_at: i64,
}

fn spawn_event_pump(args: EventPumpArgs) {
    tokio::spawn(async move {
        run_event_pump(args).await;
    });
}

async fn run_event_pump(mut args: EventPumpArgs) {
    let mut translator = EventTranslatorState::new(args.thread_id.clone(), args.turn_id.clone());
    let mut error_message: Option<String> = None;
    // Claude 可并发发出多个 can_use_tool；移动端一次只展示一个交互，
    // 用同一把公平锁保证审批和提问按到达顺序串行完成。
    let interaction_gate = Arc::new(AsyncMutex::new(()));
    let mut interaction_tasks = Vec::new();

    loop {
        let event = match args.events_rx.recv().await {
            Ok(ev) => ev,
            Err(broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!(
                    thread_id = %args.thread_id,
                    turn_id = %args.turn_id,
                    "event pump lagged by {n} events; some notifications dropped"
                );
                continue;
            }
            Err(broadcast::error::RecvError::Closed) => {
                error_message = Some("claude process exited unexpectedly".into());
                break;
            }
        };

        let payload = event.payload;
        // Side-effect routes: refresh bridge caches and bridge HITL prompts.
        match &payload {
            ClaudeOutbound::System(crate::pool::claude_protocol::SystemEvent::Init(init)) => {
                args.state.refresh_init_cache((**init).clone());
            }
            ClaudeOutbound::RateLimitEvent(env) => {
                args.state
                    .refresh_rate_limit_cache(env.rate_limit_info.clone());
            }
            ClaudeOutbound::ControlRequest(value) => {
                // Spawn the HITL handler off the pump so the codex round-trip
                // (which can sit on a phone for minutes) doesn't block
                // subsequent stream events.
                if let Some(req) = approval::parse_can_use_tool(value) {
                    let state = Arc::clone(&args.state);
                    let handle = Arc::clone(&args.handle);
                    let thread_id = args.thread_id.clone();
                    let turn_id = args.turn_id.clone();
                    let request_id = req.request_id.clone();
                    let interaction_gate = Arc::clone(&interaction_gate);
                    interaction_tasks.push(tokio::spawn(async move {
                        let _guard = interaction_gate.lock().await;
                        match approval::handle_can_use_tool(
                            &state, &handle, &thread_id, &turn_id, req,
                        )
                        .await
                        {
                            Ok(outcome) => tracing::debug!(?outcome, "HITL bridged"),
                            Err(err) => {
                                tracing::warn!(?err, "HITL bridging failed");
                                // Best-effort: tell claude to abort by
                                // replying with an error so it doesn't
                                // hang waiting for our response.
                                approval::reply_control_error(
                                    &handle,
                                    &request_id,
                                    format!("bridge HITL failed: {err}"),
                                );
                            }
                        }
                    }));
                } else if let Some(request_id) =
                    value.get("request_id").and_then(serde_json::Value::as_str)
                {
                    // Unknown subtype (hook_callback / mcp_message / future).
                    // Reply with error so claude doesn't hang.
                    approval::reply_control_error(
                        &args.handle,
                        request_id,
                        "bridge does not handle this control_request subtype yet",
                    );
                }
            }
            _ => {}
        }
        let is_terminal = matches!(payload, ClaudeOutbound::Result(_));
        if let ClaudeOutbound::Result(ref r) = payload {
            if r.is_error || r.subtype != "success" {
                error_message = Some(r.result.clone().filter(|s| !s.is_empty()).unwrap_or_else(
                    || {
                        format!(
                            "claude turn ended with subtype {} (terminal_reason={:?})",
                            r.subtype, r.terminal_reason
                        )
                    },
                ));
            }
        }

        let notifications = translator.translate(payload);
        for notif in notifications {
            if !state_should_emit(&args.state, &notif) {
                continue;
            }
            // Record completed items in the per-thread log so `thread/read`
            // can answer from memory immediately after `turn/completed`,
            // without waiting for claude's process to flush its on-disk
            // JSONL (which has a small but reliable lag and otherwise drops
            // the assistant message in fast back-to-back reads).
            if let p::ServerNotification::ItemCompleted(ref n) = notif {
                args.state
                    .record_item(&args.thread_id, &args.turn_id, n.item.clone());
            }
            let frame = notification_frame(notif);
            let _ = args.state.send(frame);
        }

        if is_terminal {
            break;
        }
    }

    // turn 结束或进程断开时取消所有等待中的移动端交互；
    // approval::PendingRequestGuard 会同步回收 pending request 槽位。
    for task in interaction_tasks {
        task.abort();
    }

    // Emit turn/completed regardless of how we exited.
    let (status, error) = turn_status_from_result(error_message.as_deref());
    let completed_at = now_unix_secs();
    let duration_ms = ((completed_at - args.started_at) * 1000).max(0);
    let turn = p::Turn {
        id: args.turn_id.clone(),
        items: Vec::new(),
        items_view: p::default_items_view(),
        status,
        error: error.clone(),
        started_at: Some(args.started_at),
        completed_at: Some(completed_at),
        duration_ms: Some(duration_ms),
    };
    if args.state.should_emit("turn/completed") {
        let frame = notification_frame(p::ServerNotification::TurnCompleted(
            p::TurnCompletedNotification {
                thread_id: args.thread_id.clone(),
                turn,
            },
        ));
        let _ = args.state.send(frame);
    }
    args.state
        .record_turn_completed(&args.thread_id, &args.turn_id, completed_at, status, error);

    clear_active_turn(&args.thread_id);
    args.state.claude_pool().mark_idle(&args.thread_id).await;
}

/// Map a `ServerNotification` to its `method` string and consult the
/// connection's opt-out list.
fn state_should_emit(state: &Arc<ConnectionState>, notif: &p::ServerNotification) -> bool {
    let method = match notif {
        p::ServerNotification::Error(_) => "error",
        p::ServerNotification::ThreadStarted(_) => "thread/started",
        p::ServerNotification::ThreadStatusChanged(_) => "thread/status/changed",
        p::ServerNotification::ThreadArchived(_) => "thread/archived",
        p::ServerNotification::ThreadUnarchived(_) => "thread/unarchived",
        p::ServerNotification::ThreadClosed(_) => "thread/closed",
        p::ServerNotification::SkillsChanged(_) => "skills/changed",
        p::ServerNotification::ThreadNameUpdated(_) => "thread/name/updated",
        p::ServerNotification::ThreadGoalCleared(_) => "thread/goal/cleared",
        p::ServerNotification::ThreadTokenUsageUpdated(_) => "thread/tokenUsage/updated",
        p::ServerNotification::TurnStarted(_) => "turn/started",
        p::ServerNotification::TurnCompleted(_) => "turn/completed",
        p::ServerNotification::TurnDiffUpdated(_) => "turn/diff/updated",
        p::ServerNotification::TurnPlanUpdated(_) => "turn/plan/updated",
        p::ServerNotification::HookStarted(_) => "hook/started",
        p::ServerNotification::HookCompleted(_) => "hook/completed",
        p::ServerNotification::ItemStarted(_) => "item/started",
        p::ServerNotification::ItemCompleted(_) => "item/completed",
        p::ServerNotification::AgentMessageDelta(_) => "item/agentMessage/delta",
        p::ServerNotification::ReasoningTextDelta(_) => "item/reasoning/textDelta",
        p::ServerNotification::ReasoningSummaryTextDelta(_) => "item/reasoning/summaryTextDelta",
        p::ServerNotification::ReasoningSummaryPartAdded(_) => "item/reasoning/summaryPartAdded",
        p::ServerNotification::CommandExecutionOutputDelta(_) => {
            "item/commandExecution/outputDelta"
        }
        p::ServerNotification::CommandExecOutputDelta(_) => "command/exec/outputDelta",
        p::ServerNotification::FileChangeOutputDelta(_) => "item/fileChange/outputDelta",
        p::ServerNotification::FileChangePatchUpdated(_) => "item/fileChange/patchUpdated",
        p::ServerNotification::McpToolCallProgress(_) => "item/mcpToolCall/progress",
        p::ServerNotification::DynamicToolCallArgumentsDelta(_) => {
            "item/dynamicToolCall/argumentsDelta"
        }
        p::ServerNotification::ContextCompacted(_) => "thread/compacted",
        p::ServerNotification::ModelRerouted(_) => "model/rerouted",
        p::ServerNotification::Warning(_) => "warning",
        p::ServerNotification::ConfigWarning(_) => "configWarning",
        p::ServerNotification::DeprecationNotice(_) => "deprecationNotice",
        p::ServerNotification::ServerRequestResolved(_) => "serverRequest/resolved",
        p::ServerNotification::McpServerStatusUpdated(_) => "mcpServer/startupStatus/updated",
        p::ServerNotification::AccountRateLimitsUpdated(_) => "account/rateLimits/updated",
        p::ServerNotification::RemoteControlStatusChanged(_) => "remoteControl/status/changed",
    };
    state.should_emit(method)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn dummy_state() -> Arc<ConnectionState> {
        let dir = tempfile::tempdir().unwrap();
        let index = alleycat_bridge_core::ThreadIndex::<crate::index::ClaudeSessionRef>::open_at(
            dir.path().join("t.json"),
        )
        .await
        .unwrap();
        std::mem::forget(dir);
        let (state, _rx) = ConnectionState::for_test(
            Arc::new(crate::pool::ClaudePool::new("/dev/null")),
            index,
            Default::default(),
        );
        state
    }

    #[tokio::test]
    async fn turn_start_returns_thread_not_loaded_when_pool_empty() {
        let state = dummy_state().await;
        let err = handle_turn_start(
            &state,
            p::TurnStartParams {
                thread_id: "missing".into(),
                input: vec![p::UserInput::Text {
                    text: "hi".into(),
                    text_elements: Vec::new(),
                }],
                ..Default::default()
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(err, TurnError::ThreadNotLoaded(_)));
    }

    #[test]
    fn permission_modes_follow_the_three_safe_presets() {
        let mut params = p::TurnStartParams::default();
        assert_eq!(claude_permission_mode(&params), "default");

        params.sandbox_policy = Some(serde_json::json!({"type": "readOnly"}));
        assert_eq!(claude_permission_mode(&params), "plan");

        params.sandbox_policy = Some(serde_json::json!({"type": "workspaceWrite"}));
        params.approval_policy = Some(p::AskForApproval::OnFailure);
        params.approvals_reviewer = Some(p::ApprovalsReviewer::AutoReview);
        assert_eq!(claude_permission_mode(&params), "auto");

        params.approval_policy = Some(p::AskForApproval::Never);
        assert_eq!(claude_permission_mode(&params), "default");
    }

    #[tokio::test]
    async fn turn_steer_rejects_unknown_thread() {
        let state = dummy_state().await;
        let err = handle_turn_steer(
            &state,
            p::TurnSteerParams {
                thread_id: "missing".into(),
                input: vec![p::UserInput::Text {
                    text: "x".into(),
                    text_elements: Vec::new(),
                }],
                expected_turn_id: "any".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(err, TurnError::ThreadNotLoaded(_)));
    }

    #[tokio::test]
    async fn turn_interrupt_returns_thread_not_loaded_when_pool_empty() {
        let state = dummy_state().await;
        let err = handle_turn_interrupt(
            &state,
            p::TurnInterruptParams {
                thread_id: "missing".into(),
                turn_id: "tu".into(),
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(err, TurnError::ThreadNotLoaded(_)));
    }

    #[tokio::test]
    async fn review_start_is_unsupported() {
        let state = dummy_state().await;
        let err = handle_review_start(
            &state,
            p::ReviewStartParams {
                thread_id: "t".into(),
                target: p::ReviewTarget::UncommittedChanges,
                delivery: None,
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(err, TurnError::ReviewUnsupported));
        assert_eq!(err.rpc_code(), p::error_codes::METHOD_NOT_FOUND);
    }

    #[test]
    fn active_turn_table_round_trip() {
        let thread_id = format!("test-{}", Uuid::now_v7());
        register_active_turn(&thread_id, "tu1");
        let active = active_turn(&thread_id).unwrap();
        assert_eq!(active.turn_id, "tu1");
        clear_active_turn(&thread_id);
        assert!(active_turn(&thread_id).is_none());
    }

    #[test]
    fn turn_error_rpc_codes() {
        assert_eq!(
            TurnError::InvalidParams("x".into()).rpc_code(),
            p::error_codes::INVALID_PARAMS
        );
        assert_eq!(
            TurnError::ReviewUnsupported.rpc_code(),
            p::error_codes::METHOD_NOT_FOUND
        );
        assert_eq!(
            TurnError::ClaudeRpc("oops".into()).rpc_code(),
            p::error_codes::INTERNAL_ERROR
        );
    }
}
