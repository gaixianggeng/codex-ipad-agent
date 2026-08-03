#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR_ID=""
OUTPUT_ROOT=""
SCENES_RAW="workspace,conversation,sessions,settings,mac-connection"
BUNDLE_ID="${BUNDLE_ID:-com.gaixianggeng.mimi}"
XCRUN_BIN="${IOS_XCRUN_BIN:-xcrun}"

usage() {
  cat <<'EOF'
Usage:
  capture-ios-store-screenshots.sh --simulator-id ID --output-root PATH [--scenes LIST]

说明：
  - App 必须已安装到目标 Simulator。
  - 默认依次采集简体中文与英文的工作区、会话详情、会话列表、设置和 Mac 连接页面。
  - --scenes 接受逗号分隔页面名，可用于只补采 mac-connection。
  - 脚本会临时切换截图 Simulator 的系统语言，并在结束时恢复中文配置后关机。
EOF
}

fail() {
  echo "capture-ios-store-screenshots: $1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator-id)
      [[ $# -ge 2 ]] || fail "--simulator-id requires a value"
      SIMULATOR_ID="$2"
      shift 2
      ;;
    --output-root)
      [[ $# -ge 2 ]] || fail "--output-root requires a value"
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --scenes)
      [[ $# -ge 2 ]] || fail "--scenes requires a value"
      SCENES_RAW="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$SIMULATOR_ID" ]] || fail "--simulator-id is required"
[[ -n "$OUTPUT_ROOT" ]] || fail "--output-root is required"
command -v "$XCRUN_BIN" >/dev/null 2>&1 || fail "missing xcrun"
command -v sips >/dev/null 2>&1 || fail "missing sips"
command -v ruby >/dev/null 2>&1 || fail "missing ruby"

IFS=',' read -r -a CAPTURE_SCENES <<< "$SCENES_RAW"
[[ ${#CAPTURE_SCENES[@]} -gt 0 ]] || fail "--scenes must not be empty"
for scene in "${CAPTURE_SCENES[@]}"; do
  case "$scene" in
    workspace|conversation|sessions|settings|mac-connection) ;;
    *) fail "unsupported scene: $scene" ;;
  esac
done

OUTPUT_ROOT="$(mkdir -p "$OUTPUT_ROOT" && cd "$OUTPUT_ROOT" && pwd)"
SIMULATOR_NAME="$(
  "$XCRUN_BIN" simctl list devices -j | \
    IOS_SCREENSHOT_SIMULATOR_ID="$SIMULATOR_ID" ruby -rjson -e '
      requested = ENV.fetch("IOS_SCREENSHOT_SIMULATOR_ID")
      devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
      selected = devices.find { |device| device["udid"] == requested && device["isAvailable"] }
      puts selected.fetch("name") if selected
    '
)"
[[ -n "$SIMULATOR_NAME" ]] || fail "simulator not found or unavailable: $SIMULATOR_ID"

# 截图、重启和构建共用同一套跨 Worktree 租约，避免其他任务在语言切换期间使用设备。
# shellcheck source=./ios-device-lease.sh
source "$ROOT_DIR/scripts/ios-device-lease.sh"
ios_lease_acquire_wait \
  simulator \
  "$SIMULATOR_ID" \
  "$SIMULATOR_NAME" \
  "bash ./scripts/capture-ios-store-screenshots.sh" \
  "$ROOT_DIR/ios/MimiRemote/build/dev-simulator-derived/$SIMULATOR_ID"
ios_lease_install_traps

ensure_booted() {
  "$XCRUN_BIN" simctl boot "$SIMULATOR_ID" 2>/dev/null || true
  "$XCRUN_BIN" simctl bootstatus "$SIMULATOR_ID" -b
}

set_system_locale() {
  local language="$1"
  local locale="$2"

  ensure_booted
  "$XCRUN_BIN" simctl spawn "$SIMULATOR_ID" defaults write NSGlobalDomain AppleLanguages -array "$language"
  "$XCRUN_BIN" simctl spawn "$SIMULATOR_ID" defaults write NSGlobalDomain AppleLocale "$locale"

  # SpringBoard 的日期与按钮文案只会在重新启动后读取新语言；因此每种语言只重启一次。
  "$XCRUN_BIN" simctl shutdown "$SIMULATOR_ID"
  ensure_booted
}

capture_locale() {
  local output_locale="$1"
  local system_language="$2"
  local system_locale="$3"
  local app_language="$4"
  local locale_dir="$OUTPUT_ROOT/$output_locale"

  mkdir -p "$locale_dir"
  set_system_locale "$system_language" "$system_locale"
  "$XCRUN_BIN" simctl ui "$SIMULATOR_ID" appearance light
  "$XCRUN_BIN" simctl status_bar "$SIMULATOR_ID" override \
    --time "09:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --batteryState charged \
    --batteryLevel 100

  local scene
  for scene in "${CAPTURE_SCENES[@]}"; do
    local output="$locale_dir/$scene.png"
    local route_scene="$scene"
    [[ "$scene" == "workspace" ]] && route_scene="workspaces"
    [[ ! -e "$output" ]] || fail "refusing to overwrite $output"

    "$XCRUN_BIN" simctl launch \
      --terminate-running-process \
      "$SIMULATOR_ID" \
      "$BUNDLE_ID" \
      --debug-skip-pairing \
      --debug-seed-ui \
      --debug-seed-store-ui \
      "--debug-open-$route_scene" \
      -app.language "$app_language" >/dev/null

    # Debug 内存种子无需网络；短暂等待只用于 SwiftUI 首次布局和设置 Sheet 动画落定。
    sleep 10
    "$XCRUN_BIN" simctl io "$SIMULATOR_ID" screenshot \
      --type=png \
      --mask=ignored \
      "$output" >/dev/null
    sips -g pixelWidth -g pixelHeight "$output" | tail -n 2
  done
}

capture_locale "zh-Hans" "zh-Hans-CN" "zh_CN" "zh-Hans"
capture_locale "en-US" "en-US" "en_US" "en"

# 不额外启动第三次：写回中文配置并关机，下次启动 Simulator 时自动恢复中文。
"$XCRUN_BIN" simctl spawn "$SIMULATOR_ID" defaults write NSGlobalDomain AppleLanguages -array "zh-Hans-CN" "en-CN"
"$XCRUN_BIN" simctl spawn "$SIMULATOR_ID" defaults write NSGlobalDomain AppleLocale "zh_CN"
"$XCRUN_BIN" simctl status_bar "$SIMULATOR_ID" clear || true
"$XCRUN_BIN" simctl shutdown "$SIMULATOR_ID"

echo "IOS_STORE_SCREENSHOTS=$OUTPUT_ROOT"
