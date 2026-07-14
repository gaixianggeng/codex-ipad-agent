#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/git-testflight-push"
INSTALL_DIR="${HOME}/.local/bin"
TARGET="$INSTALL_DIR/git-testflight-push"

[[ -x "$SOURCE" ]] || {
  echo "install-git-testflight-push: source is not executable: $SOURCE" >&2
  exit 1
}

mkdir -p "$INSTALL_DIR"
install -m 0755 "$SOURCE" "$TARGET"

echo "install-git-testflight-push ok: $TARGET"
echo "run from a configured iOS repository: git testflight-push"
