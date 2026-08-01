#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
main_prompt="$repo_root/config/automations/mimi-linear-issue.prompt.md"
detector_prompt="$repo_root/config/automations/mimi-linear-watchdog.prompt.md"

require_text() {
  local file="$1"
  local text="$2"
  if ! rg -Fq -- "$text" "$file"; then
    echo "缺少安全约束：$file -> $text" >&2
    exit 1
  fi
}

require_text "$main_prompt" '第一条外部操作必须是本地 guard'
require_text "$main_prompt" '禁止调用 `list_threads`、`wait_threads`、`read_thread`、`send_message_to_thread`'
require_text "$main_prompt" '<!-- mimi-dispatch-intent:v1 -->'
require_text "$main_prompt" '结果未确认前不得重复派发'
require_text "$main_prompt" '不得声称平台级强制取消'

require_text "$detector_prompt" '单轮只允许一次外部调用'
require_text "$detector_prompt" '禁止调用 `list_threads`、`wait_threads`、`read_thread`、`send_message_to_thread`'
require_text "$detector_prompt" 'manual_reconciliation_required_no_automatic_takeover'
require_text "$detector_prompt" '不要把“检测到阻塞”写成“已经终止阻塞调用”'

echo "Linear 巡检安全约束检查通过"
