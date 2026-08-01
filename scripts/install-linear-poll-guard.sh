#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
codex_data_root="${CODEX_HOME:-"$HOME/.codex"}"
destination_dir="$codex_data_root/automations/mimi-linear-issue/bin"
destination="$destination_dir/linear-poll-guard"

mkdir -p "$destination_dir"
chmod 700 "$destination_dir"

temporary="$(mktemp "$destination_dir/.linear-poll-guard.XXXXXX")"
cleanup() {
  rm -f "$temporary"
}
trap cleanup EXIT

(
  cd "$repo_root"
  go build -trimpath -o "$temporary" ./cmd/linear-poll-guard
)

chmod 700 "$temporary"
mv -f "$temporary" "$destination"
trap - EXIT

"$destination" version
