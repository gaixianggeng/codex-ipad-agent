//! HITL approval bridging for `--permission-prompt-tool stdio`.
//!
//! When the pool's `bypass_permissions` flag is OFF, claude is spawned with
//! `--permission-prompt-tool stdio` and emits an inbound
//! `control_request{subtype:"can_use_tool", tool_name, input, ...}` over
//! stdout for every tool call. The bridge translates that into a codex
//! `item/{commandExecution,fileChange}/requestApproval` server→client request,
//! awaits the connected client's `decision`, and replies via outbound
//! `control_response{response:{request_id, subtype:"success", response:{behavior:"allow"|"deny", ...}}}`.
//!
//! Wire-quirk note: both control_response directions nest `request_id`
//! INSIDE the outer `response` object — the SDK reads `Q.response.request_id`.
//! See `pool::claude_protocol`.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use thiserror::Error;
use uuid::Uuid;

use alleycat_codex_proto::{
    CommandExecutionRequestApprovalParams, FileChangeRequestApprovalParams, JsonRpcMessage,
    JsonRpcRequest, JsonRpcVersion, RequestId, ToolRequestUserInputParams,
    ToolRequestUserInputQuestion, ToolRequestUserInputResponse,
};

use crate::pool::ClaudeProcessHandle;
use crate::pool::claude_protocol::{
    ClaudeInbound, OutboundControlResponseEnvelope, OutboundControlResponseInner,
};
use crate::state::{ConnectionState, ServerRequestError};
use crate::translate::tool_call::{CodexToolKind, classify};

/// Errors a HITL bridge can surface.
#[derive(Debug, Error)]
pub enum ApprovalError {
    #[error("connection to codex client closed before approval landed")]
    ConnectionClosed,
    #[error("approval request timed out after {0:?}")]
    Timeout(Duration),
    #[error("codex client returned error {code}: {message}")]
    Rpc { code: i64, message: String },
    #[error("malformed approval response: {0}")]
    Malformed(String),
    #[error("failed to reply to claude: {0}")]
    ClaudeWrite(String),
}

impl From<ServerRequestError> for ApprovalError {
    fn from(value: ServerRequestError) -> Self {
        match value {
            ServerRequestError::Rpc { code, message } => Self::Rpc { code, message },
            ServerRequestError::ConnectionClosed => Self::ConnectionClosed,
            // Session 层没有携带原始时长；这里只保留错误类别。
            ServerRequestError::TimedOut => Self::Timeout(Duration::ZERO),
        }
    }
}

/// Parsed inbound `control_request{can_use_tool}`. Only the fields the bridge
/// reads are surfaced; everything else stays in the raw envelope and gets
/// dropped on the floor.
#[derive(Debug, Clone)]
pub struct CanUseToolRequest {
    pub request_id: String,
    pub tool_name: String,
    pub input: Value,
    pub tool_use_id: Option<String>,
    pub blocked_path: Option<String>,
    pub decision_reason: Option<String>,
    pub permission_suggestions: Vec<Value>,
}

/// Inspect a `ClaudeOutbound::ControlRequest(Value)` payload and extract a
/// typed [`CanUseToolRequest`] when the subtype matches. Returns `None` for
/// other inbound subtypes (`hook_callback`, `mcp_message`, ...) which the
/// bridge silently drops in v2-iter1.
pub fn parse_can_use_tool(value: &Value) -> Option<CanUseToolRequest> {
    let request_id = value.get("request_id")?.as_str()?.to_string();
    let request = value.get("request")?;
    let subtype = request.get("subtype")?.as_str()?;
    if subtype != "can_use_tool" {
        return None;
    }
    let tool_name = request.get("tool_name")?.as_str()?.to_string();
    let input = request.get("input").cloned().unwrap_or(Value::Null);
    Some(CanUseToolRequest {
        request_id,
        tool_name,
        input,
        tool_use_id: request
            .get("tool_use_id")
            .and_then(Value::as_str)
            .map(str::to_string),
        blocked_path: request
            .get("blocked_path")
            .and_then(Value::as_str)
            .map(str::to_string),
        decision_reason: request
            .get("decision_reason")
            .and_then(Value::as_str)
            .map(str::to_string),
        permission_suggestions: request
            .get("permission_suggestions")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
    })
}

/// Bucketed view of the codex client's decision. Mirrors pi-bridge's
/// `ApprovalOutcome` so future shared-helper extraction is a noop.
#[derive(Debug, Clone, PartialEq)]
pub enum ApprovalOutcome {
    Approved,
    ApprovedWithPermissionUpdate(Vec<Value>),
    Declined,
    Cancelled,
}

fn bucket_decision(value: &Value, eligible_updates: &[Value]) -> ApprovalOutcome {
    let tag = match value {
        Value::String(s) => s.as_str(),
        Value::Object(m) => match m.keys().next() {
            Some(k) => k.as_str(),
            None => return ApprovalOutcome::Declined,
        },
        _ => return ApprovalOutcome::Declined,
    };
    match tag {
        "acceptWithPermissionUpdate" if !eligible_updates.is_empty() => {
            ApprovalOutcome::ApprovedWithPermissionUpdate(eligible_updates.to_vec())
        }
        "accept"
        | "acceptForSession"
        | "acceptWithExecpolicyAmendment"
        | "applyNetworkPolicyAmendment" => ApprovalOutcome::Approved,
        "decline" => ApprovalOutcome::Declined,
        "cancel" => ApprovalOutcome::Cancelled,
        other => {
            tracing::warn!(
                decision = %other,
                "unknown codex approval decision tag — treating as decline"
            );
            ApprovalOutcome::Declined
        }
    }
}

/// Resolve a `can_use_tool` inbound control_request: classify the tool,
/// surface a codex `requestApproval` request, await the client's decision,
/// and reply on the claude side with the matching `control_response`.
///
/// On any failure (connection closed, timeout, malformed reply) the caller
/// gets `Err` and the function will NOT have sent a `control_response` —
/// callers should treat that as a hard deny and either retry or kill the
/// process. The pump in `handlers/turn.rs` chooses to deny + interrupt.
pub async fn handle_can_use_tool(
    state: &Arc<ConnectionState>,
    handle: &Arc<ClaudeProcessHandle>,
    thread_id: &str,
    turn_id: &str,
    req: CanUseToolRequest,
) -> Result<ApprovalOutcome, ApprovalError> {
    if req.tool_name == "AskUserQuestion" {
        return handle_ask_user_question(state, handle, thread_id, turn_id, req).await;
    }
    let kind = classify(&req.tool_name);
    let item_id = req
        .tool_use_id
        .clone()
        .unwrap_or_else(|| Uuid::now_v7().to_string());

    let eligible_updates = eligible_local_permission_updates(&req.permission_suggestions);
    let (outcome, server_request_id) = match kind {
        CodexToolKind::CommandExecution => {
            let command = req
                .input
                .get("command")
                .and_then(Value::as_str)
                .map(str::to_string);
            let params = CommandExecutionRequestApprovalParams {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                item_id: item_id.clone(),
                command,
                reason: req.decision_reason.clone(),
                ..Default::default()
            };
            let result = send_server_request(
                state,
                "item/commandExecution/requestApproval",
                enrich_approval_params(
                    serde_json::to_value(&params)
                        .map_err(|e| ApprovalError::Malformed(format!("encode params: {e}")))?,
                    &req,
                    &eligible_updates,
                ),
                None,
            )
            .await?;
            (
                bucket_decision(
                    result.value.get("decision").ok_or_else(|| {
                        ApprovalError::Malformed("response missing `decision`".into())
                    })?,
                    &eligible_updates,
                ),
                result.request_id,
            )
        }
        CodexToolKind::FileChange => {
            let params = FileChangeRequestApprovalParams {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                item_id: item_id.clone(),
                reason: req.decision_reason.clone(),
                grant_root: req.blocked_path.clone(),
            };
            let result = send_server_request(
                state,
                "item/fileChange/requestApproval",
                enrich_approval_params(
                    serde_json::to_value(&params)
                        .map_err(|e| ApprovalError::Malformed(format!("encode params: {e}")))?,
                    &req,
                    &eligible_updates,
                ),
                None,
            )
            .await?;
            (
                bucket_decision(
                    result.value.get("decision").ok_or_else(|| {
                        ApprovalError::Malformed("response missing `decision`".into())
                    })?,
                    &eligible_updates,
                ),
                result.request_id,
            )
        }
        // MCP and Dynamic tools (Read/Glob/Grep/Task/...) — no native codex
        // approval shape. v2 default is to use the command-execution
        // requestApproval shape with a synthetic command string so the user
        // still sees what's happening; v3 should mint a generic shape.
        CodexToolKind::Mcp { server, tool } => {
            let synthesized = format!(
                "MCP {server}.{tool}({})",
                truncated_json(&req.input, 16 * 1024)
            );
            let params = CommandExecutionRequestApprovalParams {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                item_id: item_id.clone(),
                command: Some(synthesized),
                reason: req.decision_reason.clone(),
                ..Default::default()
            };
            let result = send_server_request(
                state,
                "item/commandExecution/requestApproval",
                enrich_approval_params(
                    serde_json::to_value(&params)
                        .map_err(|e| ApprovalError::Malformed(format!("encode params: {e}")))?,
                    &req,
                    &eligible_updates,
                ),
                None,
            )
            .await?;
            (
                bucket_decision(
                    result.value.get("decision").ok_or_else(|| {
                        ApprovalError::Malformed("response missing `decision`".into())
                    })?,
                    &eligible_updates,
                ),
                result.request_id,
            )
        }
        // Dynamic + new semantic kinds (PlanExit, RequestUserInput,
        // Subagent, Exploration*, WebSearch, TodoUpdate) all share the
        // same approval path for now — synthesize a command-execution
        // request using the original tool name. Sections C/D/E/F may
        // later route some of these (eg AskUserQuestion) to a different
        // approval path; for now treat them uniformly.
        CodexToolKind::Dynamic { namespace, tool } => {
            let ns = namespace.as_deref().unwrap_or("");
            let synthesized = if ns.is_empty() {
                format!("{tool}({})", truncated_json(&req.input, 16 * 1024))
            } else {
                format!("{ns}::{tool}({})", truncated_json(&req.input, 16 * 1024))
            };
            let params = CommandExecutionRequestApprovalParams {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                item_id: item_id.clone(),
                command: Some(synthesized),
                reason: req.decision_reason.clone(),
                ..Default::default()
            };
            let result = send_server_request(
                state,
                "item/commandExecution/requestApproval",
                enrich_approval_params(
                    serde_json::to_value(&params)
                        .map_err(|e| ApprovalError::Malformed(format!("encode params: {e}")))?,
                    &req,
                    &eligible_updates,
                ),
                None,
            )
            .await?;
            (
                bucket_decision(
                    result.value.get("decision").ok_or_else(|| {
                        ApprovalError::Malformed("response missing `decision`".into())
                    })?,
                    &eligible_updates,
                ),
                result.request_id,
            )
        }
        CodexToolKind::PlanExit
        | CodexToolKind::RequestUserInput
        | CodexToolKind::Subagent
        | CodexToolKind::ExplorationRead
        | CodexToolKind::ExplorationSearch
        | CodexToolKind::ExplorationList
        | CodexToolKind::WebSearch
        | CodexToolKind::TodoUpdate => {
            let synthesized = format!(
                "claude::{}({})",
                req.tool_name,
                truncated_json(&req.input, 16 * 1024)
            );
            let params = CommandExecutionRequestApprovalParams {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                item_id: item_id.clone(),
                command: Some(synthesized),
                reason: req.decision_reason.clone(),
                ..Default::default()
            };
            let result = send_server_request(
                state,
                "item/commandExecution/requestApproval",
                enrich_approval_params(
                    serde_json::to_value(&params)
                        .map_err(|e| ApprovalError::Malformed(format!("encode params: {e}")))?,
                    &req,
                    &eligible_updates,
                ),
                None,
            )
            .await?;
            (
                bucket_decision(
                    result.value.get("decision").ok_or_else(|| {
                        ApprovalError::Malformed("response missing `decision`".into())
                    })?,
                    &eligible_updates,
                ),
                result.request_id,
            )
        }
    };

    let payload = match outcome {
        ApprovalOutcome::Approved => json!({"behavior": "allow", "updatedInput": req.input}),
        ApprovalOutcome::ApprovedWithPermissionUpdate(ref updates) => json!({
            "behavior": "allow",
            "updatedInput": req.input,
            "updatedPermissions": updates,
        }),
        ApprovalOutcome::Declined => json!({
            "behavior": "deny",
            "message": "user declined this tool call"
        }),
        ApprovalOutcome::Cancelled => json!({
            "behavior": "deny",
            "message": "user cancelled the turn",
            "interrupt": true
        }),
    };

    let envelope = ClaudeInbound::ControlResponse(OutboundControlResponseEnvelope {
        response: OutboundControlResponseInner::Success {
            request_id: req.request_id.clone(),
            response: Some(payload),
        },
    });
    handle
        .send_serialized(&envelope)
        .map_err(|e| ApprovalError::ClaudeWrite(e.to_string()))?;
    emit_resolved(state, thread_id, server_request_id);
    Ok(outcome)
}

/// Send an error-shaped `control_response` for an inbound control_request the
/// bridge couldn't satisfy. Used when codex returns malformed data, the
/// client closes mid-flight, or the bridge can't classify the tool.
pub fn reply_control_error(
    handle: &Arc<ClaudeProcessHandle>,
    request_id: &str,
    message: impl Into<String>,
) {
    let envelope = ClaudeInbound::ControlResponse(OutboundControlResponseEnvelope {
        response: OutboundControlResponseInner::Error {
            request_id: request_id.to_string(),
            error: message.into(),
        },
    });
    if let Err(e) = handle.send_serialized(&envelope) {
        tracing::warn!(?e, "failed to send error control_response to claude");
    }
}

#[derive(Debug)]
struct ServerRequestResult {
    request_id: RequestId,
    value: Value,
}

struct PendingRequestGuard {
    state: Arc<ConnectionState>,
    request_id: RequestId,
    thread_id: Option<String>,
    armed: bool,
}

impl Drop for PendingRequestGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let state = Arc::clone(&self.state);
        let request_id = self.request_id.clone();
        let thread_id = self.thread_id.clone();
        tokio::spawn(async move {
            let resolved = state
                .resolve_pending_request(&request_id, Err(ServerRequestError::ConnectionClosed))
                .await;
            // Claude 取消权限请求时，对应 future 会直接被 abort。除了清理
            // session pending 槽位，还必须通知 App 关闭已经显示的审批卡片。
            if resolved {
                if let Some(thread_id) = thread_id {
                    emit_resolved(&state, &thread_id, request_id);
                }
            }
        });
    }
}

/// Low-level helper: register a pending id, send the request, await the
/// response under a deadline, clean up on timeout. Returns the raw
/// `result` JSON. Mirrors pi-bridge's `send_server_request`.
async fn send_server_request(
    state: &Arc<ConnectionState>,
    method: &str,
    params: Value,
    timeout: Option<Duration>,
) -> Result<ServerRequestResult, ApprovalError> {
    // Session-scoped id so reattach-replay can rebuild the outstanding-prompt
    // set deterministically across iroh disconnects.
    let req_id_str = state.session().next_request_id();
    let req_id = RequestId::String(req_id_str);
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .map(str::to_string);
    let frame = JsonRpcMessage::Request(JsonRpcRequest {
        jsonrpc: JsonRpcVersion,
        id: req_id.clone(),
        method: method.to_string(),
        params: Some(params.clone()),
    });
    // Becoming outstanding and reaching the wire must be one step: a reattach
    // landing between them would show the client both the replay snapshot and
    // the live request.
    let rx = state
        .publish_server_request(req_id.clone(), method.to_string(), params, frame)
        .await
        .map_err(|_| ApprovalError::ConnectionClosed)?;
    let mut guard = PendingRequestGuard {
        state: Arc::clone(state),
        request_id: req_id.clone(),
        thread_id,
        armed: true,
    };

    let result = if let Some(deadline) = timeout {
        match tokio::time::timeout(deadline, rx).await {
            Ok(Ok(Ok(value))) => Ok(ServerRequestResult {
                request_id: req_id,
                value,
            }),
            Ok(Ok(Err(err))) => Err(err.into()),
            Ok(Err(_)) => Err(ApprovalError::ConnectionClosed),
            Err(_) => {
                let _ = state
                    .resolve_pending_request(&req_id, Err(ServerRequestError::TimedOut))
                    .await;
                Err(ApprovalError::Timeout(deadline))
            }
        }
    } else {
        match rx.await {
            Ok(Ok(value)) => Ok(ServerRequestResult {
                request_id: req_id,
                value,
            }),
            Ok(Err(err)) => Err(err.into()),
            Err(_) => Err(ApprovalError::ConnectionClosed),
        }
    };
    guard.armed = false;
    result
}

fn emit_resolved(state: &Arc<ConnectionState>, thread_id: &str, request_id: RequestId) {
    let params = alleycat_codex_proto::ServerRequestResolvedNotification {
        thread_id: thread_id.to_string(),
        request_id,
    };
    let frame = JsonRpcMessage::Notification(alleycat_codex_proto::JsonRpcNotification {
        jsonrpc: JsonRpcVersion,
        method: "serverRequest/resolved".to_string(),
        params: serde_json::to_value(params).ok(),
    });
    let _ = state.send(frame);
}

async fn handle_ask_user_question(
    state: &Arc<ConnectionState>,
    handle: &Arc<ClaudeProcessHandle>,
    thread_id: &str,
    turn_id: &str,
    req: CanUseToolRequest,
) -> Result<ApprovalOutcome, ApprovalError> {
    let item_id = req
        .tool_use_id
        .clone()
        .unwrap_or_else(|| Uuid::now_v7().to_string());
    let (questions, question_text_by_id) = parse_ask_user_questions(&req.input);
    if questions.is_empty() {
        return Err(ApprovalError::Malformed(
            "AskUserQuestion input has no valid questions".into(),
        ));
    }
    let params = ToolRequestUserInputParams {
        thread_id: thread_id.to_string(),
        turn_id: turn_id.to_string(),
        item_id,
        questions,
    };
    let result = send_server_request(
        state,
        "item/tool/requestUserInput",
        serde_json::to_value(params)
            .map_err(|e| ApprovalError::Malformed(format!("encode params: {e}")))?,
        None,
    )
    .await?;
    let response: ToolRequestUserInputResponse = serde_json::from_value(result.value)
        .map_err(|e| ApprovalError::Malformed(format!("decode response: {e}")))?;

    let mut answers = serde_json::Map::new();
    for (question_id, answer) in response.answers {
        let Some(question_text) = question_text_by_id.get(&question_id) else {
            continue;
        };
        let value = match answer.answers.len() {
            0 => Value::String(String::new()),
            1 => Value::String(answer.answers[0].clone()),
            _ => Value::Array(answer.answers.into_iter().map(Value::String).collect()),
        };
        answers.insert(question_text.clone(), value);
    }
    let mut updated_input = req.input.clone();
    let Some(object) = updated_input.as_object_mut() else {
        return Err(ApprovalError::Malformed(
            "AskUserQuestion input must be an object".into(),
        ));
    };
    object.insert("answers".into(), Value::Object(answers));

    let envelope = ClaudeInbound::ControlResponse(OutboundControlResponseEnvelope {
        response: OutboundControlResponseInner::Success {
            request_id: req.request_id,
            response: Some(json!({
                "behavior": "allow",
                "updatedInput": updated_input,
            })),
        },
    });
    handle
        .send_serialized(&envelope)
        .map_err(|e| ApprovalError::ClaudeWrite(e.to_string()))?;
    emit_resolved(state, thread_id, result.request_id);
    Ok(ApprovalOutcome::Approved)
}

fn parse_ask_user_questions(
    input: &Value,
) -> (
    Vec<ToolRequestUserInputQuestion>,
    std::collections::HashMap<String, String>,
) {
    let mut by_id = std::collections::HashMap::new();
    let questions = input
        .get("questions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
        .filter_map(|(index, value)| {
            let question = value.get("question")?.as_str()?.to_string();
            let id = format!("question-{index}");
            by_id.insert(id.clone(), question.clone());
            let options = value.get("options").and_then(Value::as_array).map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        Some(alleycat_codex_proto::ToolRequestUserInputOption {
                            label: item.get("label")?.as_str()?.to_string(),
                            description: item
                                .get("description")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string(),
                        })
                    })
                    .collect()
            });
            Some(ToolRequestUserInputQuestion {
                id,
                header: value
                    .get("header")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                question,
                is_other: true,
                is_secret: false,
                options,
                multi_select: value
                    .get("multiSelect")
                    .or_else(|| value.get("multi_select"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect();
    (questions, by_id)
}

fn eligible_local_permission_updates(suggestions: &[Value]) -> Vec<Value> {
    suggestions
        .iter()
        .filter(|update| {
            update.get("type").and_then(Value::as_str) == Some("addRules")
                && update.get("behavior").and_then(Value::as_str) == Some("allow")
                && update.get("destination").and_then(Value::as_str) == Some("localSettings")
                && update
                    .get("rules")
                    .and_then(Value::as_array)
                    .is_some_and(|rules| !rules.is_empty())
        })
        .cloned()
        .collect()
}

fn enrich_approval_params(
    mut params: Value,
    req: &CanUseToolRequest,
    eligible_updates: &[Value],
) -> Value {
    let Some(object) = params.as_object_mut() else {
        return params;
    };
    object.insert("toolName".into(), Value::String(req.tool_name.clone()));
    object.insert(
        "inputSummary".into(),
        Value::String(truncated_json(&req.input, 16 * 1024)),
    );
    if let Some(path) = file_path(&req.input).or(req.blocked_path.as_deref()) {
        object.insert("path".into(), Value::String(path.to_string()));
    }
    if let Some(diff) = file_diff(&req.tool_name, &req.input) {
        object.insert("diff".into(), Value::String(truncate_text(diff, 64 * 1024)));
    }
    if !eligible_updates.is_empty() {
        object.insert(
            "permissionSuggestions".into(),
            Value::Array(eligible_updates.to_vec()),
        );
        object.insert(
            "availableDecisions".into(),
            json!(["accept", "acceptWithPermissionUpdate", "decline"]),
        );
    } else {
        object.insert("availableDecisions".into(), json!(["accept", "decline"]));
    }
    params
}

fn file_path(input: &Value) -> Option<&str> {
    ["file_path", "path", "notebook_path"]
        .into_iter()
        .find_map(|key| input.get(key).and_then(Value::as_str))
}

fn file_diff(tool_name: &str, input: &Value) -> Option<String> {
    let path = file_path(input).unwrap_or("file");
    match tool_name {
        "Edit" => Some(format!(
            "--- a/{path}\n+++ b/{path}\n@@\n-{}\n+{}",
            input.get("old_string")?.as_str()?,
            input.get("new_string")?.as_str()?
        )),
        "Write" => Some(format!(
            "--- /dev/null\n+++ b/{path}\n@@\n+{}",
            input.get("content")?.as_str()?
        )),
        "MultiEdit" => {
            let edits = input.get("edits")?.as_array()?;
            let mut diff = format!("--- a/{path}\n+++ b/{path}\n");
            for edit in edits {
                diff.push_str("@@\n-");
                diff.push_str(edit.get("old_string")?.as_str()?);
                diff.push_str("\n+");
                diff.push_str(edit.get("new_string")?.as_str()?);
                diff.push('\n');
            }
            Some(diff)
        }
        "NotebookEdit" => Some(format!(
            "--- a/{path}\n+++ b/{path}\n@@ notebook cell @@\n+{}",
            input
                .get("new_source")
                .or_else(|| input.get("source"))?
                .as_str()?
        )),
        _ => None,
    }
}

fn truncated_json(value: &Value, limit: usize) -> String {
    truncate_text(value.to_string(), limit)
}

fn truncate_text(mut value: String, limit: usize) -> String {
    if value.len() <= limit {
        return value;
    }
    let mut end = limit;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value.truncate(end);
    value.push_str("\n…[truncated]");
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn dummy_state() -> (
        Arc<ConnectionState>,
        tokio::sync::mpsc::UnboundedReceiver<alleycat_bridge_core::session::Sequenced>,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let index = alleycat_bridge_core::ThreadIndex::<crate::index::ClaudeSessionRef>::open_at(
            dir.path().join("threads.json"),
        )
        .await
        .unwrap();
        std::mem::forget(dir);
        ConnectionState::for_test(
            Arc::new(crate::pool::ClaudePool::new("/dev/null")),
            index,
            Default::default(),
        )
    }

    #[test]
    fn parses_can_use_tool_request() {
        let v = json!({
            "request_id": "r1",
            "request": {
                "subtype": "can_use_tool",
                "tool_name": "Bash",
                "input": {"command": "ls"},
                "tool_use_id": "toolu_42",
                "blocked_path": "/tmp/x",
                "decision_reason": "outside add-dir"
            }
        });
        let parsed = parse_can_use_tool(&v).expect("parsed");
        assert_eq!(parsed.request_id, "r1");
        assert_eq!(parsed.tool_name, "Bash");
        assert_eq!(parsed.input["command"], "ls");
        assert_eq!(parsed.tool_use_id.as_deref(), Some("toolu_42"));
        assert_eq!(parsed.blocked_path.as_deref(), Some("/tmp/x"));
    }

    #[test]
    fn rejects_non_can_use_tool_subtype() {
        let v = json!({
            "request_id": "r1",
            "request": {"subtype": "hook_callback"}
        });
        assert!(parse_can_use_tool(&v).is_none());
    }

    #[test]
    fn rejects_missing_fields() {
        // Missing tool_name
        let v = json!({
            "request_id": "r1",
            "request": {"subtype": "can_use_tool"}
        });
        assert!(parse_can_use_tool(&v).is_none());
    }

    #[test]
    fn bucketing_decisions() {
        assert_eq!(
            bucket_decision(&json!("accept"), &[]),
            ApprovalOutcome::Approved
        );
        assert_eq!(
            bucket_decision(&json!("acceptForSession"), &[]),
            ApprovalOutcome::Approved
        );
        assert_eq!(
            bucket_decision(&json!("decline"), &[]),
            ApprovalOutcome::Declined
        );
        assert_eq!(
            bucket_decision(&json!("cancel"), &[]),
            ApprovalOutcome::Cancelled
        );
        assert_eq!(
            bucket_decision(&json!("nonsense"), &[]),
            ApprovalOutcome::Declined
        );
        assert_eq!(
            bucket_decision(&json!({"acceptWithExecpolicyAmendment": {}}), &[]),
            ApprovalOutcome::Approved
        );
        assert_eq!(bucket_decision(&json!(42), &[]), ApprovalOutcome::Declined);
    }

    #[test]
    fn persistent_permission_only_uses_exact_local_allow_rules() {
        let suggestions = vec![
            json!({
                "type": "addRules",
                "rules": [{"toolName": "Bash", "ruleContent": "git status"}],
                "behavior": "allow",
                "destination": "localSettings"
            }),
            json!({
                "type": "setMode",
                "mode": "bypassPermissions",
                "destination": "localSettings"
            }),
            json!({
                "type": "addRules",
                "rules": [{"toolName": "Bash"}],
                "behavior": "allow",
                "destination": "userSettings"
            }),
        ];
        let eligible = eligible_local_permission_updates(&suggestions);
        assert_eq!(eligible, vec![suggestions[0].clone()]);
        assert_eq!(
            bucket_decision(&json!("acceptWithPermissionUpdate"), &eligible),
            ApprovalOutcome::ApprovedWithPermissionUpdate(eligible)
        );
    }

    #[test]
    fn file_approval_keeps_path_diff_and_tool_context() {
        let req = CanUseToolRequest {
            request_id: "r1".into(),
            tool_name: "Edit".into(),
            input: json!({
                "file_path": "/repo/a.txt",
                "old_string": "before",
                "new_string": "after"
            }),
            tool_use_id: Some("toolu_1".into()),
            blocked_path: None,
            decision_reason: Some("write requested".into()),
            permission_suggestions: Vec::new(),
        };
        let params = enrich_approval_params(json!({}), &req, &[]);
        assert_eq!(params["toolName"], "Edit");
        assert_eq!(params["path"], "/repo/a.txt");
        assert!(params["diff"].as_str().unwrap().contains("-before"));
        assert_eq!(params["availableDecisions"], json!(["accept", "decline"]));
    }

    #[test]
    fn ask_user_question_preserves_text_and_multiselect() {
        let input = json!({
            "questions": [{
                "header": "Scope",
                "question": "Which targets?",
                "multiSelect": true,
                "options": [{"label": "iOS", "description": "App"}]
            }]
        });
        let (questions, by_id) = parse_ask_user_questions(&input);
        assert_eq!(questions.len(), 1);
        assert!(questions[0].multi_select);
        assert_eq!(by_id["question-0"], "Which targets?");
    }

    #[tokio::test]
    async fn file_approval_round_trip_replies_and_resolves() {
        let (state, mut client_rx) = dummy_state().await;
        let (writer_tx, mut writer_rx) = tokio::sync::mpsc::unbounded_channel();
        let (events_tx, _events_rx) = tokio::sync::broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            std::path::PathBuf::from("/repo"),
        ));
        let suggestion = json!({
            "type": "addRules",
            "rules": [{"toolName": "Edit", "ruleContent": "/repo/a.txt"}],
            "behavior": "allow",
            "destination": "localSettings"
        });
        let request = CanUseToolRequest {
            request_id: "claude-request-1".into(),
            tool_name: "Edit".into(),
            input: json!({
                "file_path": "/repo/a.txt",
                "old_string": "before",
                "new_string": "after"
            }),
            tool_use_id: Some("toolu_1".into()),
            blocked_path: None,
            decision_reason: Some("edit requested".into()),
            permission_suggestions: vec![suggestion.clone()],
        };
        let state_for_task = Arc::clone(&state);
        let handle_for_task = Arc::clone(&handle);
        let task = tokio::spawn(async move {
            handle_can_use_tool(
                &state_for_task,
                &handle_for_task,
                "thread-1",
                "turn-1",
                request,
            )
            .await
        });

        let approval = client_rx.recv().await.expect("approval request").payload;
        assert_eq!(approval["method"], "item/fileChange/requestApproval");
        assert_eq!(approval["params"]["path"], "/repo/a.txt");
        assert_eq!(approval["params"]["permissionSuggestions"][0], suggestion);
        let request_id: RequestId =
            serde_json::from_value(approval["id"].clone()).expect("request id");
        state
            .resolve_pending_request(
                &request_id,
                Ok(json!({"decision": "acceptWithPermissionUpdate"})),
            )
            .await;

        let claude_line = writer_rx.recv().await.expect("control response");
        let claude_response: Value = serde_json::from_str(&claude_line).unwrap();
        assert_eq!(claude_response["response"]["response"]["behavior"], "allow");
        assert_eq!(
            claude_response["response"]["response"]["updatedInput"]["file_path"],
            "/repo/a.txt"
        );
        assert_eq!(
            claude_response["response"]["response"]["updatedPermissions"][0],
            suggestion
        );
        assert_eq!(
            task.await.unwrap().unwrap(),
            ApprovalOutcome::ApprovedWithPermissionUpdate(vec![suggestion])
        );

        let resolved = client_rx
            .recv()
            .await
            .expect("resolved notification")
            .payload;
        assert_eq!(resolved["method"], "serverRequest/resolved");
        assert_eq!(resolved["params"]["requestId"], approval["id"]);
    }

    #[tokio::test]
    async fn ask_user_question_round_trip_uses_original_question_text() {
        let (state, mut client_rx) = dummy_state().await;
        let (writer_tx, mut writer_rx) = tokio::sync::mpsc::unbounded_channel();
        let (events_tx, _events_rx) = tokio::sync::broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            std::path::PathBuf::from("/repo"),
        ));
        let request = CanUseToolRequest {
            request_id: "claude-question-1".into(),
            tool_name: "AskUserQuestion".into(),
            input: json!({
                "questions": [{
                    "header": "Targets",
                    "question": "Which targets?",
                    "multiSelect": true,
                    "options": [
                        {"label": "iOS", "description": "App"},
                        {"label": "Server", "description": "Backend"}
                    ]
                }]
            }),
            tool_use_id: Some("toolu_question".into()),
            blocked_path: None,
            decision_reason: None,
            permission_suggestions: Vec::new(),
        };
        let state_for_task = Arc::clone(&state);
        let handle_for_task = Arc::clone(&handle);
        let task = tokio::spawn(async move {
            handle_can_use_tool(
                &state_for_task,
                &handle_for_task,
                "thread-1",
                "turn-1",
                request,
            )
            .await
        });

        let prompt = client_rx.recv().await.expect("question request").payload;
        assert_eq!(prompt["method"], "item/tool/requestUserInput");
        assert_eq!(prompt["params"]["questions"][0]["multiSelect"], true);
        let request_id: RequestId =
            serde_json::from_value(prompt["id"].clone()).expect("request id");
        state
            .resolve_pending_request(
                &request_id,
                Ok(json!({
                    "answers": {
                        "question-0": {"answers": ["iOS", "Server"]}
                    }
                })),
            )
            .await;

        let claude_line = writer_rx.recv().await.expect("control response");
        let claude_response: Value = serde_json::from_str(&claude_line).unwrap();
        assert_eq!(
            claude_response["response"]["response"]["updatedInput"]["answers"]["Which targets?"],
            json!(["iOS", "Server"])
        );
        assert_eq!(task.await.unwrap().unwrap(), ApprovalOutcome::Approved);
        let resolved = client_rx
            .recv()
            .await
            .expect("resolved notification")
            .payload;
        assert_eq!(resolved["method"], "serverRequest/resolved");
    }
}
