use std::sync::Arc;
use std::time::Duration;

use alleycat_bridge_core::framing::write_json_line;
use alleycat_bridge_core::{
    ATTACH_METHOD, SessionRegistry, SessionRegistryConfig, serve_stream_attached,
};
use alleycat_claude_bridge::ClaudeBridge;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};
use tokio::time::timeout;

const STEP_TIMEOUT: Duration = Duration::from_secs(8);

#[tokio::test]
async fn explicit_first_page_refresh_discovers_new_history_and_rate_limits_repeat_scans() {
    let fixture = TempDir::new().expect("fixture");
    let codex_home = fixture.path().join("codex-home");
    let projects = fixture.path().join("claude-projects");
    let encoded_cwd = projects.join("-private-tmp-mimi-history-refresh");
    std::fs::create_dir_all(&encoded_cwd).expect("projects dir");
    let cwd = "/private/tmp/mimi-history-refresh";

    let bridge = ClaudeBridge::builder()
        .codex_home(codex_home)
        // Builder 的 override 是单个 encoded-cwd 目录；生产默认路径才会遍历 projects 根目录。
        .projects_dir_override(encoded_cwd.clone())
        .history_refresh_interval(Duration::from_secs(60))
        .build()
        .await
        .expect("build bridge");
    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    let (client_io, bridge_io) = tokio::io::duplex(64 * 1024);
    let bridge_for_server = Arc::clone(&bridge);
    let registry_for_server = Arc::clone(&registry);
    let server = tokio::spawn(async move {
        serve_stream_attached(bridge_for_server, bridge_io, &registry_for_server, "claude").await
    });
    let (client_reader, mut client_writer) = tokio::io::split(client_io);
    let mut client_reader = BufReader::new(client_reader);

    write_json_line(
        &mut client_writer,
        &json!({"jsonrpc":"2.0","method":ATTACH_METHOD,"params":{"sessionKey":"history-refresh"}}),
    )
    .await
    .expect("attach");
    let _ = next_message(&mut client_reader).await;

    write_session(&encoded_cwd, "first-session", cwd, "first prompt");
    let ordinary = request_list(&mut client_writer, &mut client_reader, 1, cwd, false).await;
    assert!(thread_ids(&ordinary).is_empty(), "普通列表不得扫描新 JSONL");

    let refreshed = request_list(&mut client_writer, &mut client_reader, 2, cwd, true).await;
    assert_eq!(thread_ids(&refreshed), vec!["first-session"]);

    write_session(&encoded_cwd, "second-session", cwd, "second prompt");
    let limited = request_list(&mut client_writer, &mut client_reader, 3, cwd, true).await;
    assert_eq!(
        thread_ids(&limited),
        vec!["first-session"],
        "冷却窗口内重复刷新不得再次遍历目录"
    );

    drop(client_writer);
    drop(client_reader);
    timeout(STEP_TIMEOUT, server)
        .await
        .expect("server timeout")
        .expect("server join")
        .expect("server result");
}

fn write_session(dir: &std::path::Path, id: &str, cwd: &str, prompt: &str) {
    let record = json!({
        "type": "user",
        "cwd": cwd,
        "message": {"role": "user", "content": prompt},
        "timestamp": "2026-08-06T09:00:00Z"
    });
    std::fs::write(dir.join(format!("{id}.jsonl")), format!("{record}\n")).expect("write session");
}

async fn request_list<R, W>(
    writer: &mut W,
    reader: &mut R,
    id: i64,
    cwd: &str,
    refresh_history: bool,
) -> Value
where
    R: AsyncBufRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    write_json_line(
        writer,
        &json!({
            "jsonrpc":"2.0",
            "id":id,
            "method":"thread/list",
            "params":{"cwd":cwd,"refreshHistory":refresh_history}
        }),
    )
    .await
    .expect("thread/list");
    await_response(reader, id).await
}

fn thread_ids(response: &Value) -> Vec<&str> {
    response["result"]["data"]
        .as_array()
        .expect("thread/list data")
        .iter()
        .filter_map(|thread| thread["id"].as_str())
        .collect()
}

async fn await_response<R: AsyncBufRead + Unpin>(reader: &mut R, id: i64) -> Value {
    loop {
        let frame = next_message(reader).await;
        if frame["id"] == id {
            return frame;
        }
    }
}

async fn next_message<R: AsyncBufRead + Unpin>(reader: &mut R) -> Value {
    timeout(STEP_TIMEOUT, async {
        let mut line = String::new();
        let count = reader.read_line(&mut line).await.expect("read frame");
        assert!(count > 0, "bridge closed before response");
        serde_json::from_str(line.trim_end()).expect("valid JSON frame")
    })
    .await
    .expect("frame timeout")
}
