#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${RELAY_ENDPOINT:-http://124.221.80.250}"
CONFIG_PATH="${AGENTD_CONFIG:-$HOME/Library/Application Support/codex-ipad-agent/config.json}"
MIN_BYTES="262144"
MIN_LATENCY_MS="2000"
SHOW_RAW="0"

usage() {
  cat <<'USAGE'
用法：
  bash ./scripts/relay-bandwidth-diagnose.sh [options]

只读读取 /api/diagnostics/relay，并用 jq 定位 thread/list、thread/turns/list 大响应。

Options:
  --endpoint URL          agentd endpoint，默认 http://124.221.80.250
  --config PATH          本机 agentd config.json，用于读取 auth.token
  --min-bytes N          大响应阈值，默认 262144
  --min-latency-ms N     慢 RPC 阈值，默认 2000
  --raw                  输出完整 diagnostics JSON
  -h, --help             显示帮助

Token:
  优先读取 AGENTD_TOKEN；为空时读取 --config 里的 .auth.token。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)
      ENDPOINT="${2:?--endpoint 需要 URL}"
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:?--config 需要路径}"
      shift 2
      ;;
    --min-bytes)
      MIN_BYTES="${2:?--min-bytes 需要整数}"
      shift 2
      ;;
    --min-latency-ms)
      MIN_LATENCY_MS="${2:?--min-latency-ms 需要整数}"
      shift 2
      ;;
    --raw)
      SHOW_RAW="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少依赖：$1" >&2
    exit 127
  fi
}

require_integer() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == *[!0-9]* ]]; then
    echo "$name 必须是非负整数：$value" >&2
    exit 2
  fi
}

require_command curl
require_command jq
require_integer "--min-bytes" "$MIN_BYTES"
require_integer "--min-latency-ms" "$MIN_LATENCY_MS"

TOKEN="${AGENTD_TOKEN:-}"
if [[ -z "${TOKEN//[[:space:]]/}" && -f "$CONFIG_PATH" ]]; then
  # 只读读取本机配置里的外侧 Bearer Token；不要把 token 打印到终端。
  TOKEN="$(jq -er '.auth.token // empty' "$CONFIG_PATH" 2>/dev/null || true)"
fi

if [[ -z "${TOKEN//[[:space:]]/}" ]]; then
  echo "缺少 Token：请设置 AGENTD_TOKEN，或用 --config 指向 agentd config.json" >&2
  exit 2
fi

ENDPOINT="${ENDPOINT%/}"
DIAGNOSTICS_URL="$ENDPOINT/api/diagnostics/relay"

# 这是只读诊断请求，不会建立 /api/app-server/ws，也不会触发新的 thread/list。
diagnostics_json="$(
  curl -fsS \
    -H "Authorization: Bearer $TOKEN" \
    "$DIAGNOSTICS_URL"
)"

if [[ "$SHOW_RAW" == "1" ]]; then
  printf '%s\n' "$diagnostics_json" | jq '.'
  exit 0
fi

printf '%s\n' "$diagnostics_json" | jq \
  --argjson min_bytes "$MIN_BYTES" \
  --argjson min_latency "$MIN_LATENCY_MS" '
def kb: (((. // 0) / 1024) * 100 | floor / 100);

{
  generated_at,
  hints,
  thresholds: {
    min_bytes: $min_bytes,
    min_latency_ms: $min_latency
  },
  gateway_totals: {
    active_connections: .app_server_gateway.active_connections,
    upstream_to_client: {
      frames: .app_server_gateway.upstream_to_client.frames,
      bytes: .app_server_gateway.upstream_to_client.bytes,
      bytes_kb: (.app_server_gateway.upstream_to_client.bytes | kb),
      write_ms_max: .app_server_gateway.upstream_to_client.write_ms_max,
      last_frame_bytes: .app_server_gateway.upstream_to_client.last_frame_bytes,
      last_frame_kb: (.app_server_gateway.upstream_to_client.last_frame_bytes | kb)
    },
    rpc: .app_server_gateway.rpc,
    history_methods: (
      (.app_server_gateway.methods // {})
      | with_entries(select(.key == "thread/list"
                           or .key == "thread/turns/list"
                           or .key == "thread/resume"
                           or .key == "thread/read"))
    )
  },
  recent_large_list_rpc: (
    [.app_server_gateway.recent_rpc[]?
     | select(.method == "thread/list" or .method == "thread/turns/list")
     | select(((.response_bytes // 0) >= $min_bytes) or ((.latency_ms // 0) >= $min_latency))
     | {
         completed_at,
         method,
         latency_ms,
         request_bytes,
         request_kb: (.request_bytes | kb),
         response_bytes,
         response_kb: (.response_bytes | kb),
         outstanding,
         outstanding_for_ms
       }]
    | sort_by(.response_bytes)
    | reverse
    | .[:20]
  ),
  active_connections: (
    [.app_server_gateway.active_connections_detail[]?
     | {
         id,
         remote,
         host,
         duration_ms,
         last_client_method,
         last_client_frame_bytes,
         last_client_frame_kb: (.last_client_frame_bytes | kb),
         last_upstream_method,
         last_upstream_frame_bytes,
         last_upstream_frame_kb: (.last_upstream_frame_bytes | kb),
         upstream_to_client: {
           bytes: .upstream_to_client.bytes,
           bytes_kb: (.upstream_to_client.bytes | kb),
           write_ms_max: .upstream_to_client.write_ms_max,
           last_frame_bytes: .upstream_to_client.last_frame_bytes,
           last_frame_kb: (.upstream_to_client.last_frame_bytes | kb)
         },
         rpc: {
           latency_ms_max: .rpc.latency_ms_max,
           outstanding_requests: .rpc.outstanding_requests,
           outstanding_ms_max: .rpc.outstanding_ms_max
         },
         recent_large_list_rpc: (
           [.recent_rpc[]?
            | select(.method == "thread/list" or .method == "thread/turns/list")
            | select(((.response_bytes // 0) >= $min_bytes) or ((.latency_ms // 0) >= $min_latency))
            | {
                completed_at,
                method,
                latency_ms,
                request_bytes,
                request_kb: (.request_bytes | kb),
                response_bytes,
                response_kb: (.response_bytes | kb)
              }]
           | sort_by(.response_bytes)
           | reverse
           | .[:10]
         )
       }]
    | sort_by(.upstream_to_client.bytes)
    | reverse
  )
}'
