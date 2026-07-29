#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "Nightly/Release workflow 自检失败：$1" >&2
  exit 1
}

for command_name in bash grep ruby; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令 ${command_name}。"
done

nightly=".github/workflows/nightly.yml"
release_validation=".github/workflows/release-validation.yml"
runbook="docs/nightly-release-rollback.md"
rollback_script="scripts/check-rollback-readiness.sh"

for path in "$nightly" "$release_validation" "$runbook" "$rollback_script"; do
  [[ -f "$path" ]] || fail "缺少 ${path}。"
done

bash -n "$rollback_script" scripts/check-validation-workflows.sh scripts/history-sync-regression.sh

ruby - "$nightly" "$release_validation" <<'RUBY'
require "yaml"

def abort_check(message)
  abort("Nightly/Release workflow 自检失败：#{message}")
end

def load_workflow(path)
  YAML.safe_load(File.read(path), aliases: true)
rescue Psych::SyntaxError => error
  abort_check("#{path} YAML 无法解析：#{error.message}")
end

def triggers(workflow)
  value = workflow["on"] || workflow[true]
  abort_check("workflow 缺少 on") unless value.is_a?(Hash)
  value
end

def validate_common(path, workflow)
  permissions = workflow["permissions"]
  abort_check("#{path} 必须固定 permissions.contents=read") unless
    permissions.is_a?(Hash) && permissions["contents"] == "read" && permissions.keys == ["contents"]

  concurrency = workflow["concurrency"]
  abort_check("#{path} 缺少 concurrency.group") unless concurrency.is_a?(Hash) && concurrency["group"]
  abort_check("#{path} 缺少 cancel-in-progress") unless [true, false].include?(concurrency["cancel-in-progress"])

  workflow.fetch("jobs").each do |job_id, job|
    next if job.key?("uses")
    timeout = job["timeout-minutes"]
    abort_check("#{path} 的 #{job_id} 缺少正数 timeout-minutes") unless timeout.is_a?(Integer) && timeout.positive?
  end

  File.readlines(path, chomp: true).each do |line|
    next unless line =~ /^\s*uses:\s*(\S+)/
    action = Regexp.last_match(1)
    next if action.start_with?("./")
    abort_check("#{path} action 未固定完整 commit SHA：#{action}") unless action.match?(/@[0-9a-f]{40}$/)
  end
end

nightly_path, release_path = ARGV
nightly = load_workflow(nightly_path)
release = load_workflow(release_path)
validate_common(nightly_path, nightly)
validate_common(release_path, release)

nightly_triggers = triggers(nightly)
abort_check("Nightly 必须同时支持 schedule 和 workflow_dispatch") unless
  nightly_triggers.key?("schedule") && nightly_triggers.key?("workflow_dispatch")
abort_check("Nightly 每个 cron 条目必须有 cron") unless
  Array(nightly_triggers["schedule"]).all? { |entry| entry.is_a?(Hash) && entry["cron"].to_s != "" }

release_triggers = triggers(release)
abort_check("Release validation 只能手工触发") unless release_triggers.keys == ["workflow_dispatch"]
inputs = release_triggers.dig("workflow_dispatch", "inputs")
%w[candidate_ref previous_release_ref candidate_version validation_mode run_controlled_runtime_smoke internal_testflight_evidence rollback_drill_evidence].each do |name|
  abort_check("Release validation 缺少 input #{name}") unless inputs.is_a?(Hash) && inputs.key?(name)
end
RUBY

grep -Fq 'retention-days:' "$nightly" \
  || fail "Nightly artifact 没有明确保留期。"
grep -Fq 'retention-days:' "$release_validation" \
  || fail "Release artifact 没有明确保留期。"
grep -Fq 'scripts/check-rollback-readiness.sh' "$release_validation" \
  || fail "Release validation 没有执行回滚检查。"
grep -Fq 'validation_mode == '\''publish-readiness'\''' "$release_validation" \
  || fail "Release validation 没有区分 dry-run 与 publish-readiness。"
grep -Fq 'run_controlled_runtime_smoke' "$nightly" \
  || fail "Nightly 没有受控 Runtime smoke 开关。"
grep -Fq 'MIMI_NIGHTLY_RUNTIME_SMOKE_ENABLED' "$nightly" \
  || fail "Nightly 定时 Runtime smoke 没有显式仓库变量开关。"
grep -Fq 'scripts/history-sync-regression.sh' "$nightly" \
  || fail "Nightly 没有复用只读真实 Codex history smoke。"
grep -Fq -- '--require-all-successful' "$nightly" \
  && grep -Fq -- '--require-all-successful' "$release_validation" \
  || fail "Nightly/Release 的 Runtime smoke 没有在请求失败时 fail-closed。"
grep -Fq 'runtime claude' "$nightly" \
  || fail "Nightly 没有记录受控 Claude smoke。"
grep -Fq 'runtime_version' "$release_validation" \
  && grep -Fq 'CANDIDATE_VERSION' "$release_validation" \
  && grep -Fq 'MIMI_NIGHTLY_RUNTIME_CANDIDATE_SHA' "$nightly" \
  && grep -Fq 'MIMI_NIGHTLY_RUNTIME_CANDIDATE_SHA' "$release_validation" \
  || fail "Nightly/Release 没有把受控 Runtime 绑定到候选 commit 与版本。"

for forbidden in \
  'gh release create' \
  'gh release upload' \
  'goreleaser.*release --clean' \
  'ios_testflight_local.sh.*--upload' \
  'git push'; do
  if grep -Eq "$forbidden" "$nightly" "$release_validation"; then
    fail "验证 workflow 包含禁止的发布动作：${forbidden}"
  fi
done

for phrase in \
  'PR Gate' \
  'Nightly' \
  'Release validation' \
  'fail-closed' \
  'file_upload_v1' \
  'Internal TestFlight'; do
  grep -Fq "$phrase" "$runbook" || fail "运行手册缺少：${phrase}"
done

grep -Fq 'git merge-base --is-ancestor' "$rollback_script" \
  || fail "回滚检查没有验证 previous/candidate 历史关系。"
grep -Fq 'minimum_supported_client_revision' "$rollback_script" \
  || fail "回滚检查没有验证 MIM-28 最低客户端窗口。"
grep -Fq 'minimum_supported_server_revision' "$rollback_script" \
  || fail "回滚检查没有验证 MIM-28 最低服务端窗口。"
grep -Fq 'file_upload_v1' "$rollback_script" \
  || fail "回滚检查没有验证 MIM-30 kill switch 证据。"

echo "Nightly/Release workflow 自检通过：触发、权限、超时、action 固定、artifact、回滚和禁止发布边界均明确。"
