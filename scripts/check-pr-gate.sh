#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "PR Gate 自检失败：$1" >&2
  exit 1
}

for command_name in bash grep mktemp ruby; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "缺少命令 ${command_name}。"
done

bash -n scripts/ci-pr-scope.sh scripts/check-pr-gate.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-pr-gate-check.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

assert_scope() {
  local case_name="$1"
  local expected_go="$2"
  local expected_ios="$3"
  local expected_rust="$4"
  shift 4

  local paths_path="$test_root/${case_name}.paths"
  local output_path="$test_root/${case_name}.output"
  printf '%s\0' "$@" > "$paths_path"
  bash ./scripts/ci-pr-scope.sh --paths-file "$paths_path" > "$output_path"

  grep -Fqx "go=$expected_go" "$output_path" \
    || fail "${case_name} 的 Go 分类错误。"
  grep -Fqx "ios=$expected_ios" "$output_path" \
    || fail "${case_name} 的 iOS 分类错误。"
  grep -Fqx "rust=$expected_rust" "$output_path" \
    || fail "${case_name} 的 Rust 分类错误。"
}

assert_scope go_only true false false internal/httpapi/router.go
assert_scope ios_only false true false ios/MimiRemote/Sources/App/MimiRemoteApp.swift
assert_scope rust_only false false true bridges/claude/crates/claude-bridge/src/main.rs
assert_scope release true false false scripts/check-release-artifacts.sh
assert_scope windows_release true false false scripts/build-windows-installer.ps1
assert_scope ios_release false true false scripts/ios_testflight_ci.sh
assert_scope ios_device_lease false true false scripts/ios-device-lease.sh
assert_scope ios_device_fixture false true false scripts/testdata/ios-device-management/simulators.json
assert_scope docs_only false false false CONTRIBUTING.md
assert_scope workflow true true true .github/workflows/pr-gate.yml
assert_scope mixed true true true \
  cmd/agentd/main.go \
  ios/MimiRemote/project.yml \
  Cargo.lock

ruby <<'RUBY'
require "yaml"

def load_workflow(path)
  YAML.safe_load(File.read(path), aliases: true)
rescue Psych::SyntaxError => error
  abort("PR Gate 自检失败：#{path} YAML 无法解析：#{error.message}")
end

def triggers(workflow, path)
  value = workflow["on"] || workflow[true]
  abort("PR Gate 自检失败：#{path} 缺少 on。") unless value.is_a?(Hash)
  value
end

gate_path = ".github/workflows/pr-gate.yml"
gate = load_workflow(gate_path)
abort("PR Gate 自检失败：workflow 名称必须稳定为 PR Gate。") unless gate["name"] == "PR Gate"

gate_triggers = triggers(gate, gate_path)
abort("PR Gate 自检失败：PR Gate 必须监听所有 pull_request。") unless gate_triggers.key?("pull_request")
pull_request_trigger = gate_triggers["pull_request"]
if pull_request_trigger.is_a?(Hash) && (pull_request_trigger.key?("paths") || pull_request_trigger.key?("paths-ignore"))
  abort("PR Gate 自检失败：PR Gate 顶层禁止 paths/paths-ignore。")
end

unless gate.dig("concurrency", "cancel-in-progress") == true
  abort("PR Gate 自检失败：必须保留 cancel-in-progress。")
end

expected_calls = {
  "codex-protocol" => "./.github/workflows/codex-protocol.yml",
  "repository-safety" => "./.github/workflows/public-repo-safety.yml",
  "go" => "./.github/workflows/go-ci.yml",
  "ios" => "./.github/workflows/ios-ci.yml",
  "rust" => "./.github/workflows/claude-bridge-ci.yml",
}
jobs = gate.fetch("jobs")
expected_calls.each do |job_id, workflow_path|
  unless jobs.dig(job_id, "uses") == workflow_path
    abort("PR Gate 自检失败：#{job_id} 没有调用 #{workflow_path}。")
  end
end

final_gate = jobs.fetch("gate")
abort("PR Gate 自检失败：最终 check 名称必须为 PR Gate。") unless final_gate["name"] == "PR Gate"
unless final_gate["if"].to_s.include?("always()")
  abort("PR Gate 自检失败：最终聚合 job 必须在上游失败或跳过时仍执行。")
end
expected_needs = %w[scope codex-protocol repository-safety go ios rust]
unless Array(final_gate["needs"]).sort == expected_needs.sort
  abort("PR Gate 自检失败：最终聚合 job 的 needs 不完整。")
end

expected_calls.values.each do |workflow_path|
  called_workflow = load_workflow(workflow_path)
  called_triggers = triggers(called_workflow, workflow_path)
  unless called_triggers.key?("workflow_call")
    abort("PR Gate 自检失败：#{workflow_path} 缺少 workflow_call。")
  end
  if called_triggers.key?("pull_request")
    abort("PR Gate 自检失败：#{workflow_path} 不应绕过 PR Gate 单独监听 pull_request。")
  end
end
RUBY

rm -rf "$test_root"
trap - EXIT

echo "PR Gate 自检通过：触发器、聚合依赖和路径分类均符合预期。"
