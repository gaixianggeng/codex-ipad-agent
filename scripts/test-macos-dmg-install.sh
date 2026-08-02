#!/usr/bin/env bash
set -euo pipefail

DMG_PATH=""
EXPECTED_VERSION=""
EXPECTED_COMMIT=""
OUTPUT_PATH=""

fail() {
  echo "Mac DMG 安装运行态验收失败：$1" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dmg) DMG_PATH="$2"; shift 2 ;;
    --expected-version) EXPECTED_VERSION="$2"; shift 2 ;;
    --expected-commit) EXPECTED_COMMIT="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    *) fail "未知参数 $1" ;;
  esac
done

for command_name in codex curl ditto hdiutil plutil ruby shasum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令 $command_name"
done
[[ -f "$DMG_PATH" ]] || fail "DMG 不存在：$DMG_PATH"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
  || fail "expected version 非法"
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "expected commit 必须为完整 40 位"
[[ -n "$OUTPUT_PATH" ]] || fail "缺少 --output"
mkdir -p "$(dirname "$OUTPUT_PATH")"
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"

work_dir="$(mktemp -d -t mimi-macos-dmg-install)"
mount_dir="$work_dir/mount"
install_root="$work_dir/Applications"
runtime_home="$work_dir/home"
config_path="$work_dir/config.json"
values_path="$work_dir/values.json"
agent_pid=""
mounted=0
cleanup() {
  [[ -z "$agent_pid" ]] || kill "$agent_pid" 2>/dev/null || true
  if [[ "$mounted" == "1" ]]; then
    hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
mkdir -p "$mount_dir" "$install_root" "$runtime_home/.config"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
dmg_sha256="$(sha256_file "$DMG_PATH")"

# 复刻 DMG 拖放安装：把 App 复制到独立 Applications 目录，然后卸载镜像。
# 后续所有运行态检查只使用已安装副本，避免误把“挂载后可执行”当成安装成功。
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount_dir" "$DMG_PATH"
mounted=1
source_app="$mount_dir/Mimi Remote Mac.app"
installed_app="$install_root/Mimi Remote Mac.app"
[[ -d "$source_app" ]] || fail "DMG 中缺少 Mimi Remote Mac.app"
ditto "$source_app" "$installed_app"
hdiutil detach "$mount_dir" -quiet
mounted=0

agent_binary="$installed_app/Contents/Resources/agentd"
info_plist="$installed_app/Contents/Info.plist"
[[ -x "$agent_binary" ]] || fail "已安装 App 缺少可执行 agentd"
[[ -f "$info_plist" ]] || fail "已安装 App 缺少 Info.plist"
bundle_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
bundle_build="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
[[ "$bundle_version" == "$EXPECTED_VERSION" ]] || fail "已安装 App 版本与候选不一致"
[[ "$bundle_build" =~ ^[1-9][0-9]*$ ]] || fail "已安装 App build 不是正整数"
runtime_version="${EXPECTED_VERSION}+mac.${bundle_build}"
[[ "$("$agent_binary" version)" == "$runtime_version" ]] \
  || fail "已安装 agentd 版本与候选不一致"
agent_sha256="$(sha256_file "$agent_binary")"

CONFIG_PATH="$config_path" VALUES_PATH="$values_path" WORK_DIR="$work_dir" \
  CODEX_BIN="$(command -v codex)" ruby -rjson -rsecurerandom -rsocket -e '
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    upstream_port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    token = SecureRandom.hex(32)
    upstream_token_path = File.join(ENV.fetch("WORK_DIR"), "upstream-token")
    File.write(upstream_token_path, SecureRandom.hex(32), mode: "w", perm: 0o600)
    project_path = File.join(ENV.fetch("WORK_DIR"), "project")
    Dir.mkdir(project_path)
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
      "codex" => {
        "bin" => ENV.fetch("CODEX_BIN"), "default_args" => ["--no-alt-screen"],
        "env" => { "TERM" => "xterm-256color" }
      },
      "claude" => {
        "enabled" => false, "bridge_bin" => "alleycat-claude-bridge",
        "max_concurrent_bridges" => 1
      },
      "session" => { "output_buffer_bytes" => 131072 },
      "projects" => [{ "id" => "dmg-install", "name" => "dmg-install", "path" => project_path }],
      "scan_roots" => []
    }
    File.write(ENV.fetch("CONFIG_PATH"), JSON.generate(config) + "\n", mode: "w", perm: 0o600)
    File.write(ENV.fetch("VALUES_PATH"), JSON.generate({"port" => port, "token" => token}) + "\n", mode: "w", perm: 0o600)
  '
read -r port token < <(
  ruby -rjson -e 'v=JSON.parse(File.read(ARGV.fetch(0))); puts [v.fetch("port"),v.fetch("token")].join(" ")' \
    "$values_path"
)

log_path="$work_dir/agentd.log"
HOME="$runtime_home" XDG_CONFIG_HOME="$runtime_home/.config" \
  "$agent_binary" serve --config "$config_path" >"$log_path" 2>&1 &
agent_pid=$!
version_path="$work_dir/version.json"
http_status=""
for _ in $(seq 1 90); do
  kill -0 "$agent_pid" 2>/dev/null \
    || fail "已安装 agentd 提前退出：$(tail -n 20 "$log_path" | tr '\n' ' ')"
  http_status="$(curl --silent --output "$version_path" --write-out '%{http_code}' \
    --max-time 2 --header "Authorization: Bearer $token" \
    "http://127.0.0.1:$port/api/version" || true)"
  [[ "$http_status" == "200" ]] && break
  sleep 1
done
[[ "$http_status" == "200" ]] || fail "已安装 agentd /api/version 未就绪"
RUNTIME_VERSION="$runtime_version" EXPECTED_COMMIT="$EXPECTED_COMMIT" ruby -rjson -e '
  body = JSON.parse(File.read(ARGV.fetch(0)))
  abort "version mismatch" unless body["version"] == ENV.fetch("RUNTIME_VERSION")
  abort "build_commit mismatch" unless body["build_commit"] == ENV.fetch("EXPECTED_COMMIT")
' "$version_path"

ready_path="$work_dir/ready.json"
ready_status="$(curl --silent --output "$ready_path" --write-out '%{http_code}' \
  --max-time 10 --header "Authorization: Bearer $token" \
  "http://127.0.0.1:$port/api/readyz" || true)"
[[ "$ready_status" == "200" ]] || fail "已安装 agentd readyz HTTP $ready_status"
ruby -rjson -e 'b=JSON.parse(File.read(ARGV.fetch(0))); abort "readyz ok != true" unless b["ok"] == true' \
  "$ready_path"
doctor_path="$work_dir/doctor.json"
HOME="$runtime_home" XDG_CONFIG_HOME="$runtime_home/.config" \
  "$agent_binary" doctor --config "$config_path" --json >"$doctor_path"
ruby -rjson -e 'b=JSON.parse(File.read(ARGV.fetch(0))); abort "doctor ok != true" unless b["ok"] == true' \
  "$doctor_path"
kill "$agent_pid"
wait "$agent_pid" || true
agent_pid=""

completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
export EXPECTED_VERSION EXPECTED_COMMIT bundle_build runtime_version
export dmg_sha256 agent_sha256 ready_status started_at completed_at
export ready_sha256="$(sha256_file "$ready_path")"
ruby -rjson -e '
  evidence = {
    "schema_version" => 1,
    "kind" => "macos_dmg_drag_install_runtime",
    "status" => "success",
    "candidate_sha" => ENV.fetch("EXPECTED_COMMIT"),
    "version" => ENV.fetch("EXPECTED_VERSION"),
    "build" => Integer(ENV.fetch("bundle_build"), 10),
    "runtime_version" => ENV.fetch("runtime_version"),
    "install_method" => "dmg-drag-copy",
    "dmg_sha256" => ENV.fetch("dmg_sha256"),
    "installed_agentd_sha256" => ENV.fetch("agent_sha256"),
    "readyz_http_status" => Integer(ENV.fetch("ready_status"), 10),
    "readyz_body_sha256" => ENV.fetch("ready_sha256"),
    "doctor_ok" => true,
    "started_at" => ENV.fetch("started_at"),
    "completed_at" => ENV.fetch("completed_at")
  }
  File.write(ARGV.fetch(0), JSON.generate(evidence) + "\n", mode: "w", perm: 0o600)
' "$OUTPUT_PATH"

echo "Mac DMG 安装运行态验收通过：version=$runtime_version commit=$EXPECTED_COMMIT"
