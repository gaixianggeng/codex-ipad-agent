#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-}"

if [[ -z "$TARGET_DIR" ]]; then
  echo "用法：bash ./scripts/export-public-backend.sh <目标目录>" >&2
  exit 2
fi

for command_name in rsync tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "导出失败：缺少命令 ${command_name}。" >&2
    exit 127
  fi
done

mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
if [[ "$TARGET_DIR" == "$ROOT_DIR" || "$TARGET_DIR" == "$ROOT_DIR/"* ]]; then
  echo "导出失败：目标目录不能是当前私有仓库或其子目录。" >&2
  exit 2
fi

stage="$(mktemp -d -t mimi-remote-public)"
trap 'rm -rf "$stage"' EXIT

public_paths=(
  .github/workflows/codex-protocol.yml
  .github/workflows/go-ci.yml
  .github/workflows/public-repo-safety.yml
  .github/workflows/release.yml
  .gitignore
  .goreleaser.yml
  LICENSE
  NOTICE.md
  SECURITY.md
  THIRD_PARTY_NOTICES.md
  config.example.json
  go.mod
  go.sum
  cmd
  internal
  packaging/systemd
  docs/codex-protocol-support.md
  docs/install-upgrade-rollback.md
  docs/tailscale-peer-relay-ops.md
  scripts/check-codex-protocol.sh
  scripts/check-packaging.sh
  scripts/check-public-repo-safety.sh
  scripts/check-release-artifacts.sh
  scripts/check-release-prerequisites.sh
  scripts/check-third-party-notices.sh
  scripts/history-sync-regression.sh
  scripts/install-linux.sh
  scripts/ipad-ws-probe.go
  scripts/ipad_ws_probe_test.go
  scripts/test-install-linux.sh
  scripts/verify-release.sh
)

(
  cd "$ROOT_DIR"
  tar -cf - "${public_paths[@]}"
) | (
  cd "$stage"
  tar -xf -
)

cp "$ROOT_DIR/packaging/public/README.md" "$stage/README.md"
cp "$ROOT_DIR/packaging/public/NOTICE.md" "$stage/NOTICE.md"
cp "$ROOT_DIR/packaging/public/.gitignore" "$stage/.gitignore"
cp "$ROOT_DIR/packaging/public/check-third-party-notices.sh" "$stage/scripts/check-third-party-notices.sh"
awk '!/ios\/MimiRemote\/README\.md/' "$ROOT_DIR/scripts/check-public-repo-safety.sh" > "$stage/scripts/check-public-repo-safety.sh"
chmod +x "$stage/scripts/check-public-repo-safety.sh" "$stage/scripts/check-third-party-notices.sh"
awk '
  /^本文件随 Mimi Remote 源码/ {
    print "本文件随 Mimi Remote Agent 源码和 `agentd` 发布压缩包一起分发，用于保留运行时依赖的版权声明和许可证正文。"
    next
  }
  /^Go 依赖版本以/ {
    print "依赖版本以 `go.mod`、`go.sum` 为准。"
    next
  }
  /^\| `swift-/ || /^\| `xctest-/ { next }
  /^### swift-markdown 0\.8\.0$/ { exit }
  { print }
  END {
    print ""
    print "## 更新要求"
    print ""
    print "升级 Go 或 Go module 后，必须同步更新依赖清单和对应许可证正文，并运行 `bash ./scripts/check-third-party-notices.sh`。"
  }
' "$ROOT_DIR/THIRD_PARTY_NOTICES.md" > "$stage/THIRD_PARTY_NOTICES.md"

# 核心逻辑：目标仓库只保留白名单快照和自身 .git，防止私有 iOS 文件或历史被带入公开仓库。
rsync -a --delete --exclude='.git/' "$stage/" "$TARGET_DIR/"

if [[ -e "$TARGET_DIR/ios" ]] || find "$TARGET_DIR/.github/workflows" -type f -print | grep -Eq 'ios|testflight'; then
  echo "导出失败：公开快照中出现 iOS 源码或私有发布工作流。" >&2
  exit 1
fi

echo "后端公开快照已导出到：$TARGET_DIR"
