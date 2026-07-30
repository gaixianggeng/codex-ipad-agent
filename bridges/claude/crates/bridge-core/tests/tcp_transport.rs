use std::sync::Arc;

use alleycat_bridge_core::framing::{read_json_line, write_json_line};
use alleycat_bridge_core::session::{SessionRegistry, SessionRegistryConfig};
use alleycat_bridge_core::{Bridge, Conn, JsonRpcError, bind_loopback_tcp, serve_tcp_listener};
use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::BufReader;
use tokio::net::TcpStream;

struct EchoBridge;

#[async_trait]
impl Bridge for EchoBridge {
    async fn initialize(&self, _ctx: &Conn, _params: Value) -> Result<Value, JsonRpcError> {
        Ok(json!({"userAgent": "tcp-test"}))
    }

    async fn dispatch(
        &self,
        _ctx: &Conn,
        method: &str,
        params: Value,
    ) -> Result<Value, JsonRpcError> {
        Ok(json!({"method": method, "params": params}))
    }
}

#[tokio::test]
async fn binds_loopback_and_serves_attached_jsonl_session() {
    let listener = bind_loopback_tcp("127.0.0.1:0".parse().unwrap())
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    assert!(addr.ip().is_loopback());
    assert_ne!(addr.port(), 0);

    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    let server = tokio::spawn(serve_tcp_listener(
        Arc::new(EchoBridge),
        listener,
        "claude",
        registry,
    ));

    let stream = TcpStream::connect(addr).await.unwrap();
    let (read, mut write) = tokio::io::split(stream);
    let mut read = BufReader::new(read);
    write_json_line(
        &mut write,
        &json!({
            "jsonrpc": "2.0",
            "method": "_alleycat/attach",
            "params": {"sessionKey": "tcp-client"}
        }),
    )
    .await
    .unwrap();

    let attached: Value = read_json_line(&mut read).await.unwrap().unwrap();
    assert_eq!(attached["method"], "_alleycat/attached");
    assert_eq!(attached["params"]["sessionKey"], "tcp-client");
    assert_eq!(attached["params"]["kind"], "fresh");

    write_json_line(
        &mut write,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "test/echo",
            "params": {"value": 42}
        }),
    )
    .await
    .unwrap();

    let response: Value = read_json_line(&mut read).await.unwrap().unwrap();
    assert_eq!(response["id"], 1);
    assert_eq!(response["result"]["method"], "test/echo");
    assert_eq!(response["result"]["params"]["value"], 42);
    server.abort();
}

#[tokio::test]
async fn rejects_unspecified_ipv4_bind() {
    let error = bind_loopback_tcp("0.0.0.0:0".parse().unwrap())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("loopback"));
}

#[tokio::test]
async fn rejects_public_ipv4_bind() {
    let error = bind_loopback_tcp("192.0.2.1:9000".parse().unwrap())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("loopback"));
}

#[tokio::test]
async fn binds_ipv6_loopback_when_available() {
    match bind_loopback_tcp("[::1]:0".parse().unwrap()).await {
        Ok(listener) => assert!(listener.local_addr().unwrap().ip().is_loopback()),
        Err(error) if error.to_string().contains("loopback") => {
            panic!("IPv6 loopback was rejected by validation: {error}")
        }
        Err(_) => {
            // Some CI hosts disable IPv6 entirely; validation still accepted
            // the address and the OS-level bind was the only failure.
        }
    }
}
