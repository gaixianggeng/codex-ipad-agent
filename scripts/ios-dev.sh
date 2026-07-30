#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/ios/MimiRemote/MimiRemote.xcodeproj}"
SCHEME="${SCHEME:-MimiRemote}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TARGET_MODE="${IOS_TARGET_MODE:-auto}"
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPad Pro 13-inch (M5)}"
SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"
DEVICE_NAME="${IOS_DEVICE_NAME:-${DEVICE_NAME:-iPad Pro}}"
DEVICE_ID="${IOS_DEVICE_ID:-${DEVICE_ID:-}}"
DERIVED_DATA_PATH="${IOS_DERIVED_DATA_PATH:-$ROOT_DIR/ios/MimiRemote/build/dev-simulator-derived}"
DEVICE_DERIVED_DATA_PATH="${IOS_DEVICE_DERIVED_DATA_PATH:-$ROOT_DIR/ios/MimiRemote/build/dev-device-derived}"
BUNDLE_ID="${BUNDLE_ID:-com.gaixianggeng.mimi}"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/ios-dev.sh [build|build-for-testing|test|run]
  bash ./scripts/ios-dev.sh destination
  bash ./scripts/ios-dev.sh prepare
  bash ./scripts/ios-dev.sh target
  bash ./scripts/ios-dev.sh derived-data-path

默认目标：
  build/run: USB 真机优先，没有可用真机时使用 iPad Pro 13-inch (M5) Simulator
  test:      固定使用 iPad Pro 13-inch (M5) Simulator
  Scheme:    MimiRemote
  Config:    Debug

可选覆盖：
  IOS_TARGET_MODE         auto（默认）、device 或 simulator
  IOS_DEVICE_NAME         多台 USB 真机时优先的设备名，默认 iPad Pro
  IOS_DEVICE_ID           用 UDID 明确选择 USB 真机
  IOS_SIMULATOR_NAME      明确选择另一台 Simulator，用于兼容性测试
  IOS_SIMULATOR_ID        用 UDID 明确选择 Simulator，优先于名称
  IOS_TEST_DESTINATION    CI 使用的完整 destination，必须包含 Simulator UDID
  IOS_DERIVED_DATA_PATH   覆盖固定的 DerivedData 目录
  IOS_DEVICE_DERIVED_DATA_PATH 覆盖真机构建的固定 DerivedData 目录

脚本只把 available、paired、USB 连接的 iOS/iPadOS 设备视为真机候选。
不会创建、擦除 Simulator，也不会随机选择多台真机。
EOF
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少命令：$command_name" >&2
    exit 1
  fi
}

available_simulator_id() {
  local requested_id="$1"
  local requested_name="$2"

  xcrun simctl list devices available -j | \
    IOS_REQUESTED_ID="$requested_id" IOS_REQUESTED_NAME="$requested_name" ruby -rjson -e '
      requested_id = ENV.fetch("IOS_REQUESTED_ID", "")
      requested_name = ENV.fetch("IOS_REQUESTED_NAME")
      entries = JSON.parse(STDIN.read).fetch("devices").flat_map do |runtime, devices|
        version = runtime.scan(/\d+/).map(&:to_i)
        devices.map { |device| [version, device] }
      end

      candidates = entries.select do |_version, device|
        device["isAvailable"] &&
          (requested_id.empty? ? device["name"] == requested_name : device["udid"] == requested_id)
      end
      chosen = candidates.max_by { |version, _device| version }
      print chosen.last.fetch("udid") if chosen
    '
}

available_physical_device() {
  xcrun devicectl list devices --json-output - --quiet --timeout 5 | \
    IOS_REQUESTED_DEVICE_ID="$DEVICE_ID" IOS_REQUESTED_DEVICE_NAME="$DEVICE_NAME" ruby -rjson -e '
      requested_id = ENV.fetch("IOS_REQUESTED_DEVICE_ID", "")
      requested_name = ENV.fetch("IOS_REQUESTED_DEVICE_NAME")
      devices = JSON.parse(STDIN.read).fetch("result").fetch("devices")
      candidates = devices.map do |device|
        properties = device.fetch("properties", {})
        connection = properties.fetch("connection", {})
        hardware = properties.fetch("hardware", {})
        state = properties.fetch("state", {})
        next unless hardware["platform"] == "iOS" && hardware["reality"] == "physical"
        next unless connection["transportType"] == "wired"
        next unless connection["state"] == "connected" && connection["pairingState"] == "paired"

        udid = hardware["udid"]
        name = state["name"]
        next if udid.to_s.empty? || name.to_s.empty?
        [udid, name]
      end.compact

      if !requested_id.empty?
        chosen = candidates.find { |udid, _name| udid == requested_id }
        unless chosen
          warn "找不到可用的 USB 真机：#{requested_id}"
          exit 4
        end
        puts chosen.join("\t")
        exit
      end

      preferred = candidates.select { |_udid, name| name == requested_name }
      if preferred.length == 1
        puts preferred.first.join("\t")
      elsif preferred.length > 1
        warn "存在多台同名 USB 真机：#{requested_name}，请设置 IOS_DEVICE_ID。"
        preferred.each { |udid, name| warn "- #{name}: #{udid}" }
        exit 2
      elsif candidates.length == 1
        puts candidates.first.join("\t")
      elsif candidates.empty?
        exit 3
      else
        warn "检测到多台 USB 真机，但没有唯一的 #{requested_name}。请设置 IOS_DEVICE_ID。"
        candidates.each { |udid, name| warn "- #{name}: #{udid}" }
        exit 2
      end
    '
}

resolve_destination() {
  if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
    if [[ "$IOS_TEST_DESTINATION" != *"platform=iOS Simulator"* || "$IOS_TEST_DESTINATION" != *"id="* ]]; then
      echo "IOS_TEST_DESTINATION 必须是包含 Simulator UDID 的完整 destination。" >&2
      echo "示例：platform=iOS Simulator,id=00000000-0000-0000-0000-000000000000" >&2
      exit 1
    fi
    printf '%s\n' "$IOS_TEST_DESTINATION"
    return
  fi

  local resolved_id
  resolved_id="$(available_simulator_id "$SIMULATOR_ID" "$SIMULATOR_NAME")"
  if [[ -z "$resolved_id" ]]; then
    if [[ -n "$SIMULATOR_ID" ]]; then
      echo "找不到可用的 iOS Simulator：$SIMULATOR_ID" >&2
    else
      echo "找不到默认 iOS Simulator：$SIMULATOR_NAME" >&2
    fi
    echo "脚本不会自动选择其他设备。当前可用设备：" >&2
    xcrun simctl list devices available >&2
    exit 1
  fi

  printf 'platform=iOS Simulator,id=%s\n' "$resolved_id"
}

resolve_build_target() {
  local effective_mode="$TARGET_MODE"
  local device_record device_status simulator_destination simulator_id

  if [[ -z "${IOS_TARGET_MODE:-}" ]]; then
    if [[ -n "${IOS_TEST_DESTINATION:-}" || -n "${IOS_SIMULATOR_ID:-}" || -n "${IOS_SIMULATOR_NAME:-}" ]]; then
      effective_mode="simulator"
    elif [[ -n "$DEVICE_ID" || -n "${IOS_DEVICE_NAME:-}" ]]; then
      effective_mode="device"
    fi
  fi

  case "$effective_mode" in
    simulator)
      simulator_destination="$(resolve_destination)"
      simulator_id="$(simulator_id_from_destination "$simulator_destination")"
      printf 'simulator\t%s\t%s\n' "$simulator_id" "$SIMULATOR_NAME"
      ;;
    auto|device)
      if device_record="$(available_physical_device)"; then
        printf 'device\t%s\n' "$device_record"
        return
      else
        device_status=$?
      fi
      if [[ "$effective_mode" == "auto" && "$device_status" -eq 3 ]]; then
        simulator_destination="$(resolve_destination)"
        simulator_id="$(simulator_id_from_destination "$simulator_destination")"
        printf 'simulator\t%s\t%s\n' "$simulator_id" "$SIMULATOR_NAME"
        return
      fi
      if [[ "$device_status" -eq 3 ]]; then
        echo "没有检测到 available、paired、USB 连接的 iOS 真机。" >&2
      fi
      return "$device_status"
      ;;
    *)
      echo "IOS_TARGET_MODE 只支持 auto、device 或 simulator：$effective_mode" >&2
      return 2
      ;;
  esac
}

simulator_id_from_destination() {
  local destination="$1"
  local suffix
  suffix="${destination#*id=}"
  if [[ "$suffix" == "$destination" ]]; then
    return 1
  fi
  printf '%s\n' "${suffix%%,*}"
}

prepare_destination() {
  local destination target_id booted_id booted_ids
  destination="$(resolve_destination)"
  target_id="$(simulator_id_from_destination "$destination")"
  booted_ids="$(
    xcrun simctl list devices booted -j | ruby -rjson -e '
      JSON.parse(STDIN.read).fetch("devices").values.flatten.each do |device|
        puts device.fetch("udid") if device["state"] == "Booted"
      end
    '
  )"

  # 切换目标前关闭其他已启动设备，保证 Xcode、Codex 和测试脚本共用一台 Simulator。
  while IFS= read -r booted_id; do
    [[ -n "$booted_id" ]] || continue
    if [[ "$booted_id" != "$target_id" ]]; then
      echo "==> 关闭非默认 Simulator：$booted_id" >&2
      xcrun simctl shutdown "$booted_id"
    fi
  done <<< "$booted_ids"

  printf '%s\n' "$destination"
}

simulator_is_booted() {
  local target_id="$1"
  xcrun simctl list devices booted -j | IOS_TARGET_ID="$target_id" ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    exit(devices.any? { |device| device["udid"] == ENV.fetch("IOS_TARGET_ID") } ? 0 : 1)
  '
}

run_xcodebuild() {
  local action="$1"
  local destination="$2"
  shift 2

  echo "==> $SCHEME $CONFIGURATION · $action"
  echo "    destination: $destination"
  echo "    DerivedData: $DERIVED_DATA_PATH"

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    "$action"
}

run_device_action() {
  local action="$1"
  local target_id="$2"
  local target_name="$3"
  shift 3

  echo "==> 检测到 USB 真机，使用 $target_name ($target_id)"
  if [[ "$action" == "build" ]]; then
    DEVICE_ID="$target_id" \
      DEVICE_NAME="$target_name" \
      DERIVED_DATA_PATH="$DEVICE_DERIVED_DATA_PATH" \
      SKIP_INSTALL=1 \
      SKIP_LAUNCH=1 \
      bash "$ROOT_DIR/scripts/deploy-ipad.sh" "$@"
  else
    DEVICE_ID="$target_id" \
      DEVICE_NAME="$target_name" \
      DERIVED_DATA_PATH="$DEVICE_DERIVED_DATA_PATH" \
      bash "$ROOT_DIR/scripts/deploy-ipad.sh" "$@"
  fi
}

command_name="${1:-build}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$command_name" in
  destination)
    require_command xcrun
    require_command ruby
    resolve_destination
    ;;
  prepare)
    require_command xcrun
    require_command ruby
    prepare_destination
    ;;
  target)
    require_command xcrun
    require_command ruby
    target_record="$(resolve_build_target)"
    IFS=$'\t' read -r target_kind target_id target_name <<< "$target_record"
    printf '%s: %s (%s)\n' "$target_kind" "$target_name" "$target_id"
    ;;
  derived-data-path)
    printf '%s\n' "$DERIVED_DATA_PATH"
    ;;
  build)
    require_command xcodebuild
    require_command xcrun
    require_command ruby
    target_record="$(resolve_build_target)"
    IFS=$'\t' read -r target_kind target_id target_name <<< "$target_record"
    if [[ "$target_kind" == "device" ]]; then
      run_device_action build "$target_id" "$target_name" "$@"
    else
      resolved_destination="$(prepare_destination)"
      run_xcodebuild build "$resolved_destination" "$@"
    fi
    ;;
  build-for-testing|test)
    require_command xcodebuild
    require_command xcrun
    require_command ruby
    resolved_destination="$(prepare_destination)"
    run_xcodebuild "$command_name" "$resolved_destination" "$@"
    ;;
  run)
    require_command open
    require_command xcodebuild
    require_command xcrun
    require_command ruby
    target_record="$(resolve_build_target)"
    IFS=$'\t' read -r target_kind target_id target_name <<< "$target_record"
    if [[ "$target_kind" == "device" ]]; then
      run_device_action run "$target_id" "$target_name" "$@"
      exit 0
    fi

    resolved_destination="$(prepare_destination)"
    resolved_simulator_id="$(simulator_id_from_destination "$resolved_destination")"
    if ! simulator_is_booted "$resolved_simulator_id"; then
      xcrun simctl boot "$resolved_simulator_id"
    fi
    open -a Simulator
    xcrun simctl bootstatus "$resolved_simulator_id" -b
    run_xcodebuild build "$resolved_destination" "$@"

    app_path="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphonesimulator/MimiRemote.app"
    if [[ ! -d "$app_path" ]]; then
      echo "构建成功但找不到 App：$app_path" >&2
      exit 1
    fi
    xcrun simctl install "$resolved_simulator_id" "$app_path"
    xcrun simctl launch --terminate-running-process "$resolved_simulator_id" "$BUNDLE_ID"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "不支持的操作：$command_name" >&2
    usage >&2
    exit 2
    ;;
esac
