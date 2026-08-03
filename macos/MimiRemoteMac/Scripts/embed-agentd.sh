#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$SRCROOT/../.." && pwd)"
bundle_root="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
agentd_output="$bundle_root/Resources/agentd"
# agentd looks for the Claude bridge next to itself, so a complete install
# needs no per-machine configuration and no separate `cargo install`.
bridge_output="$bundle_root/Resources/alleycat-claude-bridge"
launch_agent_output="$bundle_root/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"
launch_agent_source="$SRCROOT/Resources/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"

find_go() {
  local candidate
  for candidate in "$(command -v go 2>/dev/null || true)" /usr/local/go/bin/go /opt/homebrew/bin/go; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      local resolved_goroot
      resolved_goroot="$($candidate env GOROOT 2>/dev/null || true)"
      if [[ -x "$resolved_goroot/bin/go" ]]; then
        printf '%s\n' "$resolved_goroot/bin/go"
        return 0
      fi
    fi
  done
  return 1
}

go_binary="$(find_go || true)"
if [[ -z "$go_binary" ]]; then
  echo "Mimi Remote Mac 构建失败：未找到可用 Go 工具链。" >&2
  exit 1
fi

go_version="$(GOTOOLCHAIN=local "$go_binary" env GOVERSION)"
if [[ "$go_version" != go1.25.* ]]; then
  echo "Mimi Remote Mac 构建失败：agentd 需要 Go 1.25，当前为 ${go_version}。" >&2
  exit 1
fi

mkdir -p "$(dirname "$agentd_output")" "$(dirname "$launch_agent_output")"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-agentd-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

architectures=($ARCHS)
outputs=()
agent_version="${MARKETING_VERSION:-devel}"
if [[ -n "${CURRENT_PROJECT_VERSION:-}" && "$agent_version" != "devel" ]]; then
  # 同一个 marketing version 会有多个本地/发布构建；把 App build 写进 agentd，
  # 才能识别更新 App 后 launchd 仍驻留旧二进制的情况。
  agent_version="${agent_version}+mac.${CURRENT_PROJECT_VERSION}"
fi
for architecture in "${architectures[@]}"; do
  case "$architecture" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *)
      echo "Mimi Remote Mac 构建失败：不支持架构 ${architecture}。" >&2
      exit 1
      ;;
  esac
  output="$build_dir/agentd-$architecture"
  (
    cd "$project_root"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" GOTOOLCHAIN=local \
      "$go_binary" build -trimpath \
      -ldflags "-s -w -X main.version=${agent_version}" \
      -o "$output" ./cmd/agentd
  )
  outputs+=("$output")
done

if [[ ${#outputs[@]} -eq 1 ]]; then
  cp "${outputs[0]}" "$agentd_output"
else
  /usr/bin/lipo -create "${outputs[@]}" -output "$agentd_output"
fi
chmod 0755 "$agentd_output"
cp "$launch_agent_source" "$launch_agent_output"
/usr/bin/plutil -lint "$launch_agent_output" >/dev/null

# --- Claude bridge -----------------------------------------------------------
find_cargo() {
  local candidate
  for candidate in "$(command -v cargo 2>/dev/null || true)" "$HOME/.cargo/bin/cargo" /opt/homebrew/bin/cargo; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

cargo_binary="$(find_cargo || true)"
if [[ -z "$cargo_binary" ]]; then
  echo "Mimi Remote Mac 构建失败：未找到 cargo，无法构建随包 Claude bridge。" >&2
  echo "安装 Rust 工具链后重试：https://rustup.rs" >&2
  exit 1
fi

bridge_outputs=()
for architecture in "${architectures[@]}"; do
  case "$architecture" in
    arm64) rust_target=aarch64-apple-darwin ;;
    x86_64) rust_target=x86_64-apple-darwin ;;
  esac
  # Drop MACOSX_DEPLOYMENT_TARGET for this build. Xcode sets it for the Swift
  # target, and cargo applies it to host artifacts too — which breaks the
  # proc-macro crates rustc has to load at compile time (`can't find crate for
  # tokio_macros`). The bridge's own deployment floor comes from the target
  # triple, so nothing is lost by unsetting it here.
  if ! env -u MACOSX_DEPLOYMENT_TARGET "$cargo_binary" build --release --locked \
    --manifest-path "$project_root/Cargo.toml" \
    --package alleycat-claude-bridge --bin alleycat-claude-bridge \
    --target "$rust_target" \
    --target-dir "$build_dir/rust"; then
    echo "Mimi Remote Mac 构建失败：无法为 $rust_target 构建 Claude bridge。" >&2
    echo "缺少目标时先安装：rustup target add $rust_target" >&2
    exit 1
  fi
  bridge_outputs+=("$build_dir/rust/$rust_target/release/alleycat-claude-bridge")
done

if [[ ${#bridge_outputs[@]} -eq 1 ]]; then
  cp "${bridge_outputs[0]}" "$bridge_output"
else
  /usr/bin/lipo -create "${bridge_outputs[@]}" -output "$bridge_output"
fi
chmod 0755 "$bridge_output"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.agentd \
    --options runtime --timestamp=none "$agentd_output"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --identifier com.gaixianggeng.mimi.mac.claude-bridge \
    --options runtime --timestamp=none "$bridge_output"
fi

"$agentd_output" version >/dev/null
"$bridge_output" --version >/dev/null

# This phase runs after Xcode has sealed the bundle, so the binaries it just
# wrote are not covered by that seal. On a full build Xcode signs afterwards
# and everything lines up; on an incremental build where the Swift target was
# untouched it skips signing, and the bundle ships with a stale seal that
# fails `codesign --verify`. Re-seal here so both paths end up valid.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  entitlements_args=()
  if [[ -n "${CODE_SIGN_ENTITLEMENTS:-}" && -f "$SRCROOT/$CODE_SIGN_ENTITLEMENTS" ]]; then
    entitlements_args=(--entitlements "$SRCROOT/$CODE_SIGN_ENTITLEMENTS")
  fi
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    "${entitlements_args[@]}" \
    --options runtime --timestamp=none \
    "$TARGET_BUILD_DIR/$WRAPPER_NAME"
fi
