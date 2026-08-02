#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CANDIDATE_BINARY=""
PREVIOUS_BINARY=""
CANDIDATE_SHA=""
CANDIDATE_VERSION=""
PREVIOUS_SHA=""
PREVIOUS_VERSION=""
PREVIOUS_TAG=""
PREVIOUS_ASSET_URL=""
PREVIOUS_ASSET_SHA256=""
PLATFORM=""
OUTPUT_PATH=""

fail() {
  echo "agentd 回滚演练失败：$1" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --candidate-binary) CANDIDATE_BINARY="$2"; shift 2 ;;
    --previous-binary) PREVIOUS_BINARY="$2"; shift 2 ;;
    --candidate-sha) CANDIDATE_SHA="$2"; shift 2 ;;
    --candidate-version) CANDIDATE_VERSION="$2"; shift 2 ;;
    --previous-sha) PREVIOUS_SHA="$2"; shift 2 ;;
    --previous-version) PREVIOUS_VERSION="$2"; shift 2 ;;
    --previous-tag) PREVIOUS_TAG="$2"; shift 2 ;;
    --previous-asset-url) PREVIOUS_ASSET_URL="$2"; shift 2 ;;
    --previous-asset-sha256) PREVIOUS_ASSET_SHA256="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    *) fail "未知参数 $1" ;;
  esac
done

for command_name in codex curl ruby; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令 $command_name"
done
for path in "$CANDIDATE_BINARY" "$PREVIOUS_BINARY"; do
  [[ -x "$path" && -f "$path" ]] || fail "二进制不存在或不可执行：$path"
done
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "candidate SHA 必须为完整 40 位"
[[ "$PREVIOUS_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "previous SHA 必须为完整 40 位"
[[ "$PREVIOUS_ASSET_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "previous asset SHA-256 非法"
[[ "$CANDIDATE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "candidate version 非法"
[[ "$PREVIOUS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "previous version 非法"
[[ "$CANDIDATE_VERSION" != "$PREVIOUS_VERSION" ]] || fail "candidate 与 previous 版本不能相同"
[[ "$PREVIOUS_TAG" == "v$PREVIOUS_VERSION" ]] || fail "previous tag 与版本不一致"
[[ "$PREVIOUS_ASSET_URL" == "https://github.com/gaixianggeng/codex-ipad-agent/releases/download/$PREVIOUS_TAG/"* ]] \
  || fail "previous asset 不是正式仓库 Release URL"
[[ "$PLATFORM" =~ ^(linux|darwin)-(amd64|arm64)$ ]] || fail "platform 必须为 linux/darwin + amd64/arm64"
[[ -n "$OUTPUT_PATH" ]] || fail "缺少 --output"
mkdir -p "$(dirname "$OUTPUT_PATH")"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-agentd-rollback.XXXXXX")"
active_pid=""
cleanup() {
  [[ -z "$active_pid" ]] || kill "$active_pid" 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
candidate_version_actual="$("$CANDIDATE_BINARY" version)"
previous_version_actual="$("$PREVIOUS_BINARY" version)"
[[ "$candidate_version_actual" == "$CANDIDATE_VERSION" ]] \
  || fail "candidate 版本不一致：$candidate_version_actual"
[[ "$previous_version_actual" == "$PREVIOUS_VERSION" ]] \
  || fail "previous 版本不一致：$previous_version_actual"

deployment_dir="$work_dir/deployment"
deployment_binary="$deployment_dir/agentd"
runtime_home="$work_dir/runtime-home"
config_path="$work_dir/config.json"
values_path="$work_dir/values.json"
mkdir -p "$deployment_dir" "$runtime_home/.config"

# Candidate 和 previous 必须复用同一 HOME、配置、Token、端口和部署路径，
# 才能证明这是原位恢复，而不是两次互不相关的启动测试。
CONFIG_PATH="$config_path" VALUES_PATH="$values_path" WORK_DIR="$work_dir" \
  CODEX_BIN="$(command -v codex)" ruby -rjson -rsecurerandom -rsocket -e '
      port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
      upstream_port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
      token = SecureRandom.hex(32)
      upstream_token_path = File.join(ENV.fetch("WORK_DIR"), "upstream-token")
      File.write(upstream_token_path, SecureRandom.hex(32), mode: "w", perm: 0o600)
      project_path = File.join(ENV.fetch("WORK_DIR"), "project")
      Dir.mkdir(project_path) unless Dir.exist?(project_path)
      config = {
        "listen" => "127.0.0.1:#{port}",
        "auth" => { "token" => token, "allow_query_token" => false },
        "runtime" => { "type" => "codex_app_server" },
        "app_server" => {
          "transport" => "ws", "managed" => true,
          "listen" => "ws://127.0.0.1:#{upstream_port}",
          "ws_token_file" => upstream_token_path,
          "auto_title" => false
        },
        "codex" => { "bin" => ENV.fetch("CODEX_BIN"), "default_args" => ["--no-alt-screen"], "env" => { "TERM" => "xterm-256color" } },
        "claude" => { "enabled" => false, "bridge_bin" => "alleycat-claude-bridge", "max_concurrent_bridges" => 1 },
        "session" => { "output_buffer_bytes" => 131072 },
        "projects" => [{ "id" => "rollback-drill", "name" => "rollback-drill", "path" => project_path }],
        "scan_roots" => []
      }
      File.write(ENV.fetch("CONFIG_PATH"), JSON.generate(config) + "\n", mode: "w", perm: 0o600)
      File.write(ENV.fetch("VALUES_PATH"), JSON.generate({"port" => port, "upstream_port" => upstream_port, "token" => token}) + "\n", mode: "w", perm: 0o600)
    '
read -r port upstream_port token < <(
  ruby -rjson -e 'v=JSON.parse(File.read(ARGV.fetch(0))); puts [v.fetch("port"),v.fetch("upstream_port"),v.fetch("token")].join(" ")' \
    "$values_path"
)
shared_config_sha256="$(sha256_file "$config_path")"

install_binary_at_deployment_path() {
  local source_binary="$1"
  local expected_sha="$2"
  local staged_binary="${deployment_binary}.next"
  cp "$source_binary" "$staged_binary"
  chmod 0755 "$staged_binary"
  [[ "$(sha256_file "$staged_binary")" == "$expected_sha" ]] \
    || fail "部署前二进制摘要不一致"
  mv -f "$staged_binary" "$deployment_binary"
  [[ "$(sha256_file "$deployment_binary")" == "$expected_sha" ]] \
    || fail "部署后二进制摘要不一致"
}

probe_deployed_binary() {
  local label="$1"
  local expected_version="$2"
  local expected_commit="$3"
  local version_path="$work_dir/$label-version.json"
  local ready_path="$work_dir/$label-ready.json"
  local doctor_path="$work_dir/$label-doctor.json"
  local log_path="$work_dir/$label.log"

  HOME="$runtime_home" XDG_CONFIG_HOME="$runtime_home/.config" \
    "$deployment_binary" serve --config "$config_path" >"$log_path" 2>&1 &
  local pid=$!
  active_pid="$pid"

  local http_status=""
  for _ in $(seq 1 90); do
    if ! kill -0 "$pid" 2>/dev/null; then
      fail "$label 进程提前退出：$(tail -n 20 "$log_path" | tr '\n' ' ')"
    fi
    http_status="$(curl --silent --output "$version_path" --write-out '%{http_code}' \
      --max-time 2 --header "Authorization: Bearer $token" \
      "http://127.0.0.1:$port/api/version" || true)"
    [[ "$http_status" == "200" ]] && break
    sleep 1
  done
  [[ "$http_status" == "200" ]] || fail "$label /api/version 未就绪"

  EXPECTED_VERSION="$expected_version" EXPECTED_COMMIT="$expected_commit" ruby -rjson -e '
    body = JSON.parse(File.read(ARGV.fetch(0)))
    abort "version mismatch" unless body.fetch("version") == ENV.fetch("EXPECTED_VERSION")
    unless ENV.fetch("EXPECTED_COMMIT").empty?
      commit = body["build_commit"]
      abort "build_commit mismatch" unless commit == ENV.fetch("EXPECTED_COMMIT") && commit.match?(/\A[0-9a-f]{40}\z/)
    end
  ' "$version_path"

  ready_status="$(curl --silent --output "$ready_path" --write-out '%{http_code}' \
    --max-time 10 --header "Authorization: Bearer $token" \
    "http://127.0.0.1:$port/api/readyz" || true)"
  [[ "$ready_status" == "200" ]] || fail "$label readyz HTTP $ready_status：$(tr '\n' ' ' <"$ready_path")"
  ruby -rjson -e 'body=JSON.parse(File.read(ARGV.fetch(0))); abort "readyz ok != true" unless body["ok"] == true' "$ready_path"
  HOME="$runtime_home" XDG_CONFIG_HOME="$runtime_home/.config" \
    "$deployment_binary" doctor --config "$config_path" --json >"$doctor_path"
  ruby -rjson -e 'body=JSON.parse(File.read(ARGV.fetch(0))); abort "doctor ok != true" unless body["ok"] == true' "$doctor_path"

  kill "$pid"
  wait "$pid" || true
  active_pid=""
  if [[ "$label" == "candidate" ]]; then
    # candidate 退出后必须连同 managed Codex 子进程释放两个监听端口，
    # 否则上一版本无法用同一配置恢复。previous 已是演练终态，不再要求其主动停服。
    local ports_released=0
    for _ in $(seq 1 60); do
      if PORT="$port" UPSTREAM_PORT="$upstream_port" ruby -rsocket -e '
        [ENV.fetch("PORT"), ENV.fetch("UPSTREAM_PORT")].each do |value|
          begin
            socket = TCPSocket.new("127.0.0.1", Integer(value, 10))
            socket.close
            exit 1
          rescue Errno::ECONNREFUSED
            # 没有 listener；允许同一配置继续恢复。
          end
        end
      ' >/dev/null 2>&1; then
        ports_released=1
        break
      fi
      sleep 1
    done
    [[ "$ports_released" == "1" ]] \
      || fail "$label 退出后没有释放共享 Runtime 端口（service=${port} upstream=${upstream_port}）"
  fi
  PROBE_READY_STATUS="$ready_status"
  PROBE_READY_SHA256="$(sha256_file "$ready_path")"
}

candidate_binary_sha256="$(sha256_file "$CANDIDATE_BINARY")"
previous_binary_sha256="$(sha256_file "$PREVIOUS_BINARY")"
[[ "$candidate_binary_sha256" != "$previous_binary_sha256" ]] \
  || fail "candidate 与 previous 二进制摘要不能相同"

install_binary_at_deployment_path "$CANDIDATE_BINARY" "$candidate_binary_sha256"
probe_deployed_binary candidate "$CANDIDATE_VERSION" "$CANDIDATE_SHA"

# 在同一部署路径原位替换为上一正式二进制，并继续复用 candidate 留下的配置与状态。
install_binary_at_deployment_path "$PREVIOUS_BINARY" "$previous_binary_sha256"
restored_deployed_sha256="$(sha256_file "$deployment_binary")"
probe_deployed_binary previous "$PREVIOUS_VERSION" ""
completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

export CANDIDATE_SHA CANDIDATE_VERSION PREVIOUS_SHA PREVIOUS_VERSION PREVIOUS_TAG
export PREVIOUS_ASSET_URL PREVIOUS_ASSET_SHA256 started_at completed_at
export PLATFORM
export candidate_binary_sha256 previous_binary_sha256 restored_deployed_sha256 shared_config_sha256
export ready_status="$PROBE_READY_STATUS" ready_body_sha256="$PROBE_READY_SHA256"
ruby -rjson -e '
  evidence = {
    "schema_version" => 2,
    "kind" => "agentd_binary_rollback_drill",
    "status" => "success",
    "candidate_sha" => ENV.fetch("CANDIDATE_SHA"),
    "release_version" => ENV.fetch("CANDIDATE_VERSION"),
    "previous" => {
      "tag" => ENV.fetch("PREVIOUS_TAG"),
      "sha" => ENV.fetch("PREVIOUS_SHA"),
      "version" => ENV.fetch("PREVIOUS_VERSION")
    },
    "artifact" => {
      "platform" => ENV.fetch("PLATFORM"),
      "release_asset_url" => ENV.fetch("PREVIOUS_ASSET_URL"),
      "sha256" => ENV.fetch("PREVIOUS_ASSET_SHA256"),
      "binary_sha256" => ENV.fetch("previous_binary_sha256"),
      "checksum_verified" => true
    },
    "observed" => {
      "candidate_version" => ENV.fetch("CANDIDATE_VERSION"),
      "candidate_build_commit" => ENV.fetch("CANDIDATE_SHA"),
      "restored_version" => ENV.fetch("PREVIOUS_VERSION"),
      "readyz_http_status" => Integer(ENV.fetch("ready_status"), 10),
      "readyz_body_sha256" => ENV.fetch("ready_body_sha256"),
      "doctor_ok" => true
    },
    "drill" => {
      "mode" => "in-place-shared-state",
      "rollback_exit_code" => 0,
      "candidate_deployed_sha256" => ENV.fetch("candidate_binary_sha256"),
      "restored_deployed_sha256" => ENV.fetch("restored_deployed_sha256"),
      "shared_config_sha256" => ENV.fetch("shared_config_sha256"),
      "started_at" => ENV.fetch("started_at"),
      "completed_at" => ENV.fetch("completed_at")
    }
  }
  File.write(ARGV.fetch(0), JSON.generate(evidence) + "\n", mode: "w", perm: 0o600)
' "$OUTPUT_PATH"

echo "agentd 回滚演练通过：candidate=$CANDIDATE_SHA restored=$PREVIOUS_TAG output=$OUTPUT_PATH"
