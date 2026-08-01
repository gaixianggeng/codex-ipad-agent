//! Shared scalars and small enums used across multiple method modules.

use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;

/// `reasoning_effort` levels accepted by codex. Wire is lowercase per
/// codex-rs/protocol/src/openai_models.rs:41.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ReasoningEffort {
    None,
    Minimal,
    Low,
    Medium,
    High,
    XHigh,
    Max,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ReasoningSummary {
    Auto,
    Concise,
    Detailed,
    None,
}

/// Sandbox mode selector; wire is kebab-case (matches codex `SandboxMode`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum SandboxMode {
    ReadOnly,
    WorkspaceWrite,
    DangerFullAccess,
}

/// Codex `AskForApproval` tagged enum. Wire is kebab-case for the simple
/// variants and a tagged object `{"granular": {...}}` for the rule-based one.
/// The bridge does not introspect the granular variant, so we keep it as a
/// `Value`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum AskForApproval {
    #[serde(rename = "untrusted")]
    UnlessTrusted,
    OnFailure,
    OnRequest,
    Granular(Value),
    Never,
}

/// `approvals_reviewer` is one of `"user"`, `"auto_review"`, or the legacy
/// `"guardian_subagent"` (deserialized as `AutoReview`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalsReviewer {
    #[serde(rename = "user")]
    User,
    #[serde(rename = "auto_review", alias = "guardian_subagent")]
    AutoReview,
}

/// `SessionSource` mirror. Wire is camelCase except `vscode` which is the
/// rename target codex uses.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum SessionSource {
    Cli,
    #[serde(rename = "vscode")]
    VsCode,
    Exec,
    #[default]
    AppServer,
    Custom(String),
    SubAgent(Value),
    #[serde(other)]
    Unknown,
}

/// Git metadata captured per-thread.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GitInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_url: Option<String>,
}

/// `ThreadStatus` is a tagged enum on `type`. The `active` variant carries
/// flags. We keep it minimal — the bridge mostly reports `idle` / `active` /
/// `notLoaded` and pi has no equivalent of system_error.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ThreadStatus {
    NotLoaded,
    #[default]
    Idle,
    SystemError,
    #[serde(rename_all = "camelCase")]
    Active {
        #[serde(default)]
        active_flags: Vec<ThreadActiveFlag>,
    },
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ThreadActiveFlag {
    WaitingOnApproval,
    WaitingOnUserInput,
}

/// `TurnStatus` on the wire is a string enum (camelCase). See
/// codex v2.rs:4977.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TurnStatus {
    Completed,
    Interrupted,
    Failed,
    InProgress,
}

/// Error info attached to a failed turn or `error` notification. We only need
/// to round-trip; any specific codex error code is captured as a string.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TurnError {
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_error_info: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub additional_details: Option<String>,
}

/// `TokenUsageBreakdown` for `thread/tokenUsage/updated` notifications.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsageBreakdown {
    pub total_tokens: i64,
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_output_tokens: i64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTokenUsage {
    pub total: TokenUsageBreakdown,
    pub last: TokenUsageBreakdown,
    pub model_context_window: Option<i64>,
}

/// Personality hint on `thread/start` / `turn/start`. Wire is whatever codex
/// emits; we pass through verbatim.
pub type Personality = Value;

/// Service tier override; left opaque (codex emits a string).
pub type ServiceTier = Value;

/// Sandbox policy. The shape is a tagged enum keyed on `type` but with multiple
/// nested fields; for v1 we keep it as an opaque `Value` since the bridge does
/// not introspect any of its details (pi handles execution sandboxing on its
/// own and we surface the codex view back unchanged).
pub type SandboxPolicy = Value;

/// Permission profile (see `PermissionProfile` in v2.rs:1575). Same rationale
/// as `SandboxPolicy` — opaque.
pub type PermissionProfile = Value;

/// Server-side parsed-command actions. Used in `CommandExecution` items and
/// approval requests; we never inspect them on the bridge side.
pub type CommandAction = Value;

/// Optional config map carried through from `thread/start` etc. Always opaque.
pub type ConfigOverrides = HashMap<String, Value>;
