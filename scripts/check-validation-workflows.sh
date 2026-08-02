#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:---check}"

fail() {
  echo "Nightly/Release workflow 自检失败：$1" >&2
  exit 1
}

for command_name in bash grep mktemp ruby; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令 ${command_name}。"
done

nightly="${MIMI_NIGHTLY_WORKFLOW:-.github/workflows/nightly.yml}"
release_validation="${MIMI_RELEASE_VALIDATION_WORKFLOW:-.github/workflows/release-validation.yml}"
release="${MIMI_RELEASE_WORKFLOW:-.github/workflows/release.yml}"
ios="${MIMI_IOS_WORKFLOW:-.github/workflows/ios-ci.yml}"
rollback_workflow="${MIMI_ROLLBACK_WORKFLOW:-.github/workflows/release-rollback-drill.yml}"
evidence_fetcher="${MIMI_EVIDENCE_FETCHER:-scripts/fetch-release-evidence.sh}"
runbook="docs/nightly-release-rollback.md"
rollback_script="scripts/check-rollback-readiness.sh"
rollback_drill_script="scripts/run-agentd-rollback-drill.sh"
readiness_script="scripts/check-release-readiness.sh"
testflight_distributor="${MIMI_TESTFLIGHT_DISTRIBUTOR:-scripts/distribute_internal_build.rb}"
macos_install_script="${MIMI_MACOS_INSTALL_SCRIPT:-scripts/test-macos-dmg-install.sh}"

run_checks() {
  for path in \
    "$nightly" \
    "$release_validation" \
    "$release" \
    "$ios" \
    "$rollback_workflow" \
    "$evidence_fetcher" \
    "$runbook" \
    "$rollback_script" \
    "$rollback_drill_script" \
    "$readiness_script" \
    "$testflight_distributor" \
    "$macos_install_script"; do
    [[ -f "$path" ]] || fail "缺少 ${path}。"
  done

  bash -n \
    "$rollback_script" \
    "$rollback_drill_script" \
    "$readiness_script" \
    "$evidence_fetcher" \
    "$macos_install_script" \
    scripts/check-validation-workflows.sh \
    scripts/history-sync-regression.sh

  ruby - "$nightly" "$release_validation" "$release" "$ios" \
    "$rollback_workflow" "$evidence_fetcher" "$rollback_drill_script" \
    "$testflight_distributor" <<'RUBY'
require "yaml"

def abort_check(message)
  abort("Nightly/Release workflow 自检失败：#{message}")
end

def load_workflow(path)
  YAML.safe_load(File.read(path), aliases: true)
rescue Psych::SyntaxError => error
  abort_check("#{path} YAML 无法解析：#{error.message}")
end

def triggers(workflow, path)
  value = workflow["on"] || workflow[true]
  abort_check("#{path} 缺少 on") unless value.is_a?(Hash)
  value
end

def steps(job)
  Array(job["steps"])
end

def step_named(job, name)
  steps(job).find { |step| step["name"] == name } || abort_check("缺少 step：#{name}")
end

def assert_unconditional_fail_closed_step(step, label)
  abort_check("#{label} 不得通过 if 跳过") if step.key?("if")
  abort_check("#{label} 不得忽略失败") if step.key?("continue-on-error")
end

def needs(job)
  Array(job["needs"])
end

def transitively_depends_on?(jobs, job_id, target, seen = [])
  return true if job_id == target
  return false if seen.include?(job_id)

  needs(jobs.fetch(job_id)).any? do |dependency|
    transitively_depends_on?(jobs, dependency, target, seen + [job_id])
  end
end

def assert_pinned_actions(path, workflow)
  workflow.fetch("jobs").each_value do |job|
    candidates = job.key?("uses") ? [job] : steps(job)
    candidates.each do |candidate|
      action = candidate["uses"]
      next unless action
      next if action.start_with?("./")
      abort_check("#{path} action 未固定完整 commit SHA：#{action}") unless
        action.match?(/@[0-9a-f]{40}$/)
    end
  end
end

def assert_timeouts(path, workflow)
  workflow.fetch("jobs").each do |job_id, job|
    next if job.key?("uses")
    timeout = job["timeout-minutes"]
    abort_check("#{path} 的 #{job_id} 缺少正数 timeout-minutes") unless
      timeout.is_a?(Integer) && timeout.positive?
  end
end

nightly_path, validation_path, release_path, ios_path, rollback_workflow_path,
  fetcher_path, rollback_drill_path, testflight_distributor_path = ARGV
nightly = load_workflow(nightly_path)
validation = load_workflow(validation_path)
release = load_workflow(release_path)
ios = load_workflow(ios_path)
rollback_workflow = load_workflow(rollback_workflow_path)
[nightly, validation, release, ios, rollback_workflow].zip(ARGV).each do |workflow, path|
  assert_pinned_actions(path, workflow)
  assert_timeouts(path, workflow)
end

# Nightly 只能使用公开源码/fixture，保留手工和定时入口。
abort_check("Nightly permissions 必须只有 contents: read") unless
  nightly["permissions"] == {"contents" => "read"}
abort_check("Nightly 重任务不得被后续触发取消") unless
  nightly.dig("concurrency", "cancel-in-progress") == false
nightly_triggers = triggers(nightly, nightly_path)
abort_check("Nightly 必须同时支持 schedule 和 workflow_dispatch") unless
  nightly_triggers.key?("schedule") && nightly_triggers.key?("workflow_dispatch")
abort_check("Nightly 每个 cron 条目必须有 cron") unless
  Array(nightly_triggers["schedule"]).all? { |entry| entry.is_a?(Hash) && !entry["cron"].to_s.empty? }
nightly_runtime = nightly.fetch("jobs").fetch("controlled-runtime-smoke")
nightly_runtime_steps = steps(nightly_runtime)
nightly_trust_index = nightly_runtime_steps.index { |step| step["name"] == "Trust gate before controlled runtime secrets" }
nightly_credentials_index = nightly_runtime_steps.index { |step| step["name"] == "Require isolated runtime credentials" }
nightly_smoke_index = nightly_runtime_steps.index { |step| step["name"] == "Run read-only Codex history smoke" }
abort_check("Nightly Runtime 必须在读取 secrets 前完成 trust gate") unless
  nightly_trust_index && nightly_credentials_index && nightly_smoke_index &&
  nightly_trust_index < nightly_credentials_index && nightly_credentials_index < nightly_smoke_index
nightly_trust = nightly_runtime_steps.fetch(nightly_trust_index)
abort_check("Nightly trust gate 本身不得读取 secrets") if nightly_trust.to_s.include?("secrets.")
nightly_pretrust_sources = [nightly.fetch("env", {}), nightly_runtime.fetch("env", {})] +
  nightly_runtime_steps.take(nightly_trust_index)
abort_check("Nightly Runtime trust gate 前不得有任何 secret 读取") if
  nightly_pretrust_sources.any? { |source| source.to_s.include?("secrets.") }
nightly_trust_script = nightly_trust.fetch("run")
[
  '[[ "$GITHUB_REPOSITORY" == "gaixianggeng/codex-ipad-agent" ]]',
  '[[ "$GITHUB_REF" == "refs/heads/main" ]]',
  '[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]',
  "+refs/heads/main:refs/remotes/origin/main",
  'head_sha="$(git rev-parse HEAD)"',
  'main_sha="$(git rev-parse refs/remotes/origin/main)"',
  '"$head_sha" == "$GITHUB_SHA" && "$main_sha" == "$GITHUB_SHA"',
].each do |needle|
  abort_check("Nightly Runtime trust gate 缺少：#{needle}") unless nightly_trust_script.include?(needle)
end
nightly_runtime_script = step_named(nightly_runtime, "Run read-only Codex history smoke").fetch("run")
[
  "/api/version",
  'body["build_commit"]',
  "runtime_commit",
  'runtime_commit" == "$EXPECTED_CANDIDATE_SHA',
  "[0-9a-f]{40}",
].each do |needle|
  abort_check("Nightly Runtime 必须解析并绑定 /api/version.build_commit：#{needle}") unless
    nightly_runtime_script.include?(needle)
end
abort_check("Nightly Runtime 禁止用 environment/vars 中声明的 SHA 代替真实 build_commit") if
  File.read(nightly_path).match?(/CONTROLLED_RUNTIME_CANDIDATE_SHA|MIMI_[A-Z0-9_]*RUNTIME[A-Z0-9_]*CANDIDATE_SHA|vars\.[A-Z0-9_]*CANDIDATE_SHA/)

# Release validation 只能验证受保护 main 的 github.sha，不能让任意 ref 执行带 secrets 的脚本。
abort_check("Release validation 必须以只读权限查询 Actions evidence") unless
  validation["permissions"] == {"contents" => "read", "actions" => "read"}
validation_triggers = triggers(validation, validation_path)
abort_check("Release validation 只能手工触发") unless validation_triggers.keys == ["workflow_dispatch"]
inputs = validation_triggers.dig("workflow_dispatch", "inputs")
expected_inputs = %w[
  previous_release_tag
  candidate_version
  validation_mode
  run_controlled_runtime_smoke
  internal_testflight_run_id
  rollback_drill_run_id
]
abort_check("Release validation inputs 必须使用正式 tag + run selector 模型") unless
  inputs.is_a?(Hash) && inputs.keys.sort == expected_inputs.sort
abort_check("Release validation 禁止 candidate_ref") if inputs.key?("candidate_ref")
abort_check("Release validation 禁止人工 evidence JSON 或任意 previous ref") if
  inputs.keys.any? { |key| key.end_with?("_evidence_json") || key == "previous_release_ref" }
%w[internal_testflight_run_id rollback_drill_run_id].each do |name|
  definition = inputs.fetch(name)
  abort_check("#{name} 只能是可选字符串 selector") unless
    definition["type"] == "string" && definition["required"] == false
end
abort_check("Release validation 不能取消同候选的在途签名验证") unless
  validation.dig("concurrency", "cancel-in-progress") == false

validation_jobs = validation.fetch("jobs")
resolve = validation_jobs.fetch("resolve")
checkout = step_named(resolve, "Checkout trusted main candidate")
abort_check("resolve 必须 checkout github.sha") unless checkout.dig("with", "ref") == "${{ github.sha }}"
resolve_script = step_named(resolve, "Resolve immutable commits and version metadata").fetch("run")
[
  "refs/heads/main",
  'candidate_sha" == "$GITHUB_SHA',
  'candidate_sha" == "$main_sha',
  "git fetch --no-tags origin",
  "refs/remotes/origin/main",
  "git merge-base --is-ancestor",
  "PREVIOUS_RELEASE_TAG",
  "refs/tags/$PREVIOUS_RELEASE_TAG",
  "releases/tags/$PREVIOUS_RELEASE_TAG",
  'release.fetch("tag_name")',
  'release.fetch("draft")',
  'release.fetch("prerelease")',
  "MARKETING_VERSION",
  "CURRENT_PROJECT_VERSION",
].each do |needle|
  abort_check("resolve trust gate 缺少：#{needle}") unless resolve_script.include?(needle)
end

macos = validation_jobs.fetch("macos-candidate")
abort_check("Mac signed candidate 必须使用 release production environment") unless
  macos["environment"] == "release-production-signing"
macos_install = step_named(macos, "Install DMG copy and verify embedded agentd runtime")
macos_install_script = macos_install.fetch("run")
[
  "scripts/test-macos-dmg-install.sh",
  "--dmg dist-macos/Mimi-Remote-Mac.dmg",
  '--expected-version "$CANDIDATE_VERSION"',
  '--expected-commit "$CANDIDATE_SHA"',
  "--output dist-macos/macos-install-evidence.json",
].each do |needle|
  abort_check("Mac Release 缺少安装后 readyz 证据：#{needle}") unless macos_install_script.include?(needle)
end
macos_upload = step_named(macos, "Upload audited Mac candidate")
abort_check("Mac 安装运行态证据未随候选 artifact 上传") unless
  macos_upload.dig("with", "path") == "dist-macos/"

windows = validation_jobs.fetch("windows-candidate")
abort_check("Windows signed candidate 必须使用 release production environment") unless
  windows["environment"] == "release-production-signing"
dry_windows = step_named(windows, "Build and inspect unsigned Windows snapshot")
signed_windows = step_named(windows, "Build and inspect signed Windows candidate")
abort_check("Windows dry-run 条件错误") unless dry_windows["if"] == "inputs.validation_mode == 'dry-run'"
abort_check("Windows dry-run 不得映射 PFX secrets") if
  dry_windows.fetch("env", {}).keys.any? { |key| key.start_with?("WINDOWS_SIGN_") } ||
  dry_windows.fetch("env", {}).values.any? { |value| value.to_s.include?("secrets.") }
abort_check("Windows publish-readiness 条件错误") unless
  signed_windows["if"] == "inputs.validation_mode == 'publish-readiness'"
%w[WINDOWS_SIGN_PFX WINDOWS_SIGN_PFX_PASSWORD].each do |key|
  abort_check("Windows signed step 缺少 #{key}") unless
    signed_windows.fetch("env", {}).fetch(key, "").include?("secrets.")
end
abort_check("Windows signed validation 必须 RequireSignature") unless
  signed_windows.fetch("run").include?("-RequireSignature")

ios_signed = validation_jobs.fetch("ios-app-store-validation")
abort_check("Signed iOS 只能在 publish-readiness 运行") unless
  ios_signed["if"] == "inputs.validation_mode == 'publish-readiness'"
abort_check("Signed iOS 必须复用 ios-ci") unless ios_signed["uses"] == "./.github/workflows/ios-ci.yml"
abort_check("Signed iOS 必须 checkout trusted candidate SHA") unless
  ios_signed.dig("with", "source_ref") == "${{ needs.resolve.outputs.candidate_sha }}"
abort_check("Signed iOS 必须 validate-app 且不上传") unless ios_signed.dig("with", "validate_app_store") == true
expected_ios_secrets = %w[
  ASC_KEY_ID
  ASC_ISSUER_ID
  ASC_PRIVATE_KEY
  IOS_APPSTORE_PROVISIONING_PROFILE_BASE64
  IOS_DISTRIBUTION_CERTIFICATE_BASE64
  IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
  IOS_KEYCHAIN_PASSWORD
]
abort_check("reusable iOS caller 禁止 secrets: inherit，必须显式最小映射") unless
  ios_signed["secrets"].is_a?(Hash) && ios_signed["secrets"].keys.sort == expected_ios_secrets.sort
expected_ios_secrets.each do |secret_name|
  abort_check("reusable iOS caller 的 #{secret_name} 映射错误") unless
    ios_signed.dig("secrets", secret_name) == "${{ secrets.#{secret_name} }}"
end

release_runtime = validation_jobs.fetch("controlled-runtime-smoke")
abort_check("Release Runtime secrets 必须使用专用 environment") unless
  release_runtime["environment"] == "nightly-runtime-smoke"
release_runtime_script = step_named(
  release_runtime,
  "Run read-only Codex and explicitly enabled Claude smoke"
).fetch("run")
[
  "/api/version",
  'body["build_commit"]',
  "runtime_commit",
  'runtime_commit" == "$CANDIDATE_SHA',
  "[0-9a-f]{40}",
].each do |needle|
  abort_check("Release Runtime 必须解析并绑定 /api/version.build_commit：#{needle}") unless
    release_runtime_script.include?(needle)
end
abort_check("Release Runtime 禁止用 environment/vars 中声明的 SHA 代替真实 build_commit") if
  release_runtime_script.match?(/CONTROLLED_RUNTIME_CANDIDATE_SHA|MIMI_[A-Z0-9_]*RUNTIME[A-Z0-9_]*CANDIDATE_SHA|vars\.[A-Z0-9_]*CANDIDATE_SHA/)

final_job = validation_jobs.fetch("release-validation-result")
expected_needs = %w[
  resolve
  go-rust-and-packaging
  macos-candidate
  windows-candidate
  ios-full
  ios-app-store-validation
  controlled-runtime-smoke
]
abort_check("Release validation final job 必须 always() 聚合") unless final_job["if"].to_s.include?("always()")
abort_check("Release validation final job needs 不完整") unless needs(final_job).sort == expected_needs.sort
abort_check("Release validation 不得继续接受人工 evidence JSON") if
  File.read(validation_path).match?(/internal_testflight_evidence_json|rollback_drill_evidence_json|EVIDENCE_JSON/)

summary_index = steps(final_job).index { |step| step["name"] == "Fail closed and summarize evidence" }
candidate_checkout_index = steps(final_job).index do |step|
  step["name"] == "Checkout immutable candidate for attestation verifier"
end
macos_download_index = steps(final_job).index { |step| step["name"] == "Download audited Mac candidate evidence" }
macos_verify_index = steps(final_job).index { |step| step["name"] == "Verify Mac DMG installed-runtime evidence" }
trusted_evidence_index = steps(final_job).index do |step|
  step["name"] == "Resolve trusted TestFlight and rollback evidence artifacts"
end
ipa_index = steps(final_job).index { |step| step["name"] == "Verify validated IPA provenance" }
attestation_index = steps(final_job).index do |step|
  step["name"] == "Create machine-readable publish-readiness attestation"
end
attestation_upload_index = steps(final_job).index do |step|
  step["name"] == "Upload exact publish-readiness attestation"
end
abort_check("Release attestation step DAG 顺序错误") unless
  [summary_index, candidate_checkout_index, macos_download_index, macos_verify_index,
    trusted_evidence_index, ipa_index,
    attestation_index, attestation_upload_index].all? &&
  summary_index < candidate_checkout_index &&
  candidate_checkout_index < macos_download_index &&
  macos_download_index < macos_verify_index &&
  macos_verify_index < trusted_evidence_index &&
  trusted_evidence_index < ipa_index &&
  ipa_index < attestation_index &&
  attestation_index < attestation_upload_index

summary_step = steps(final_job).fetch(summary_index)
%w[INTERNAL_TESTFLIGHT_RUN_ID ROLLBACK_DRILL_RUN_ID].each do |selector|
  abort_check("#{selector} 必须只作为十进制 run selector") unless
    summary_step.fetch("run").include?(%Q([[ "$#{selector}" =~ ^[1-9][0-9]*$ ]]))
end

trusted_evidence_step = steps(final_job).fetch(trusted_evidence_index)
trusted_evidence_script = trusted_evidence_step.fetch("run")
[
  "bash ./scripts/fetch-release-evidence.sh",
  '--run-id "$INTERNAL_TESTFLIGHT_RUN_ID"',
  '--workflow-path .github/workflows/ios-ci.yml',
  'internal-testflight-evidence-$CANDIDATE_SHA',
  '--run-id "$ROLLBACK_DRILL_RUN_ID"',
  '--workflow-path .github/workflows/release-rollback-drill.yml',
  'rollback-drill-evidence-$CANDIDATE_SHA',
  '--candidate-sha "$CANDIDATE_SHA"',
  "testflight_source=$testflight_dir/source.json",
  "rollback_source=$rollback_dir/source.json",
].each do |needle|
  abort_check("Release validation evidence selector/fetch 缺少：#{needle}") unless
    trusted_evidence_script.include?(needle)
end
abort_check("Release evidence fetch 必须使用只读 github.token") unless
  trusted_evidence_step.dig("env", "GH_TOKEN") == "${{ github.token }}"

macos_download = steps(final_job).fetch(macos_download_index)
abort_check("Release final job 必须下载同 candidate 的 Mac evidence artifact") unless
  macos_download["uses"].to_s.start_with?("actions/download-artifact@") &&
  macos_download.dig("with", "name") == "release-macos-${{ needs.resolve.outputs.candidate_sha }}"
macos_verify = steps(final_job).fetch(macos_verify_index)
[
  "macos-install-evidence.json",
  'value["candidate_sha"] == ENV.fetch("EXPECTED_CANDIDATE_SHA")',
  'value["version"] == ENV.fetch("EXPECTED_VERSION")',
  'value["readyz_http_status"] == 200',
  'value["doctor_ok"] == true',
].each do |needle|
  abort_check("Release final job 未严格验证 Mac 安装证据：#{needle}") unless
    macos_verify.fetch("run").include?(needle)
end

attestation_step = steps(final_job).fetch(attestation_index)
expected_attestation_sources = {
  "TESTFLIGHT_EVIDENCE" => "${{ steps.evidence.outputs.testflight_evidence }}",
  "TESTFLIGHT_SOURCE" => "${{ steps.evidence.outputs.testflight_source }}",
  "ROLLBACK_EVIDENCE" => "${{ steps.evidence.outputs.rollback_evidence }}",
  "ROLLBACK_SOURCE" => "${{ steps.evidence.outputs.rollback_source }}",
  "MACOS_INSTALL_EVIDENCE" => "${{ steps.macos.outputs.evidence }}",
}
expected_attestation_sources.each do |name, value|
  abort_check("attestation 没有消费受信 #{name}") unless attestation_step.dig("env", name) == value
end
abort_check("run ID 不得直接进入 attestation，只能经 fetcher source 绑定") if
  [attestation_step["env"], attestation_step["run"]].inspect.match?(/INTERNAL_TESTFLIGHT_RUN_ID|ROLLBACK_DRILL_RUN_ID/)
[
  "check-release-readiness.sh create",
  '--testflight-evidence "$TESTFLIGHT_EVIDENCE"',
  '--testflight-source "$TESTFLIGHT_SOURCE"',
  '--rollback-evidence "$ROLLBACK_EVIDENCE"',
  '--rollback-source "$ROLLBACK_SOURCE"',
  '--macos-install-evidence "$MACOS_INSTALL_EVIDENCE"',
  "check-release-readiness.sh verify",
].each do |needle|
  abort_check("attestation 没有同时绑定 evidence/source：#{needle}") unless
    attestation_step.fetch("run").include?(needle)
end
abort_check("Release attestation artifact 名未绑定 candidate/version") unless
  steps(final_job).fetch(attestation_upload_index).dig("with", "name") ==
    "release-readiness-${{ needs.resolve.outputs.candidate_sha }}-${{ needs.resolve.outputs.release_version }}"

# run ID 只是 API selector；fetcher 必须从官方 Actions API 重建并校验完整 provenance。
fetcher_text = File.read(fetcher_path)
[
  'GITHUB_REPOSITORY:-}" == "gaixianggeng/codex-ipad-agent"',
  ".github/workflows/ios-ci.yml|.github/workflows/release-rollback-drill.yml",
  'repos/$GITHUB_REPOSITORY/actions/runs/$RUN_ID',
  '"event" => "workflow_dispatch"',
  '"status" => "completed"',
  '"conclusion" => "success"',
  '"head_branch" => "main"',
  '"head_sha" => ENV.fetch("EXPECTED_CANDIDATE_SHA")',
  '"path" => ENV.fetch("EXPECTED_WORKFLOW_PATH")',
  'run.dig("repository", "full_name") == ENV.fetch("GITHUB_REPOSITORY")',
  'run.fetch("id").to_s == ENV.fetch("RUN_ID")',
  'actions/runs/$RUN_ID/artifacts?name=$ARTIFACT_NAME&per_page=100',
  'matches.length == 1',
  'item["expired"] == false',
  'sha256:[0-9a-f]{64}',
  'actions/artifacts/$artifact_id/zip',
  'actual_digest" == "$artifact_digest',
  '"${#evidence_files[@]}" == "1"',
  '"artifact_digest" => ENV.fetch("ARTIFACT_DIGEST")',
].each do |needle|
  abort_check("evidence fetcher 缺少 fail-closed 绑定：#{needle}") unless fetcher_text.include?(needle)
end
abort_check("evidence fetcher 不得允许操作者覆盖 repository/event/conclusion/head SHA") if
  fetcher_text.match?(/--repository|--event|--conclusion|--head-(?:branch|sha)/)

# Rollback evidence 必须来自当前 main 对正式 previous Release 二进制执行的真实恢复演练。
abort_check("Rollback Drill permissions 必须只有 contents: read") unless
  rollback_workflow["permissions"] == {"contents" => "read"}
rollback_triggers = triggers(rollback_workflow, rollback_workflow_path)
abort_check("Rollback Drill 只能手工触发") unless rollback_triggers.keys == ["workflow_dispatch"]
abort_check("Rollback Drill inputs 必须固定为正式 tag 和 candidate version") unless
  rollback_triggers.dig("workflow_dispatch", "inputs")&.keys&.sort ==
    %w[candidate_version previous_release_tag]
abort_check("Rollback Drill 不得取消同候选演练") unless
  rollback_workflow.dig("concurrency", "cancel-in-progress") == false
rollback_job = rollback_workflow.fetch("jobs").fetch("agentd-binary-rollback")
abort_check("Rollback Drill 只允许正式仓库") unless
  rollback_job["if"].to_s.include?("github.repository == 'gaixianggeng/codex-ipad-agent'")
rollback_trust = step_named(rollback_job, "Trust gate and resolve previous release").fetch("run")
[
  "refs/heads/main",
  "GITHUB_SHA",
  "git fetch --no-tags origin",
  "refs/remotes/origin/main",
  'git rev-parse HEAD)" == "$GITHUB_SHA',
  'git rev-parse refs/remotes/origin/main)" == "$GITHUB_SHA',
  "refs/tags/$PREVIOUS_TAG",
  "releases/tags/$PREVIOUS_TAG",
  'release.fetch("tag_name")',
  'release.fetch("draft")',
  'release.fetch("prerelease")',
  "git merge-base --is-ancestor",
].each do |needle|
  abort_check("Rollback Drill main/Release trust gate 缺少：#{needle}") unless rollback_trust.include?(needle)
end
rollback_artifact_step = step_named(rollback_job, "Build candidate and download previous release binary")
rollback_artifact_script = rollback_artifact_step.fetch("run")
[
  'gh release download "$PREVIOUS_TAG"',
  "checksums.txt",
  'expected_sha="$(awk',
  "sha256sum --check --strict",
  "mimi-remote_",
].each do |needle|
  abort_check("Rollback Drill previous 正式资产/checksum 缺少：#{needle}") unless
    rollback_artifact_script.include?(needle)
end
rollback_steps = steps(rollback_job)
drill_index = rollback_steps.index { |step| step["name"] == "Execute in-place candidate to previous rollback" }
provenance_index = rollback_steps.index { |step| step["name"] == "Add trusted workflow provenance" }
rollback_upload_index = rollback_steps.index { |step| step["name"] == "Upload rollback evidence" }
abort_check("Rollback Drill evidence 顺序错误") unless
  drill_index && provenance_index && rollback_upload_index &&
  drill_index < provenance_index && provenance_index < rollback_upload_index
drill_script = rollback_steps.fetch(drill_index).fetch("run")
[
  "bash ./scripts/run-agentd-rollback-drill.sh",
  '--candidate-binary "$RUNNER_TEMP/rollback/candidate/agentd"',
  '--previous-binary "$RUNNER_TEMP/rollback/previous/agentd"',
  '--candidate-sha "$GITHUB_SHA"',
  '--previous-sha "$PREVIOUS_SHA"',
  '--previous-asset-sha256 "$PREVIOUS_ASSET_SHA256"',
  '--output "$RUNNER_TEMP/rollback/evidence/rollback-drill.json"',
].each do |needle|
  abort_check("Rollback Drill 没有执行真实 binary rollback：#{needle}") unless drill_script.include?(needle)
end
rollback_upload = rollback_steps.fetch(rollback_upload_index)
abort_check("Rollback Drill artifact 名或内容未绑定 candidate SHA") unless
  rollback_upload.dig("with", "name") == "rollback-drill-evidence-${{ github.sha }}" &&
  rollback_upload.dig("with", "path") == "${{ runner.temp }}/rollback/evidence/rollback-drill.json" &&
  rollback_upload.dig("with", "if-no-files-found") == "error"
rollback_drill_text = File.read(rollback_drill_path)
[
  'deployment_binary="$deployment_dir/agentd"',
  'runtime_home="$work_dir/runtime-home"',
  'config_path="$work_dir/config.json"',
  'install_binary_at_deployment_path "$CANDIDATE_BINARY"',
  'probe_deployed_binary candidate',
  'install_binary_at_deployment_path "$PREVIOUS_BINARY"',
  'probe_deployed_binary previous',
  "/api/version",
  'body["build_commit"]',
  "/api/readyz",
  "doctor --config",
  '"binary_sha256" => ENV.fetch("previous_binary_sha256")',
  '"mode" => "in-place-shared-state"',
  '"candidate_deployed_sha256"',
  '"restored_deployed_sha256"',
  '"shared_config_sha256"',
  '"checksum_verified" => true',
  '"status" => "success"',
].each do |needle|
  abort_check("run-agentd-rollback-drill 缺少真实恢复观测：#{needle}") unless
    rollback_drill_text.include?(needle)
end

# 真正的 tag 发布必须先下载并验证同 SHA/版本、成功 workflow_dispatch 生成的 attestation。
abort_check("Release workflow 顶层必须允许读取 Actions artifact") unless
  release["permissions"] == {"contents" => "read", "actions" => "read"}
release_jobs = release.fetch("jobs")
readiness = release_jobs.fetch("readiness")
trusted_checkout = step_named(readiness, "Checkout trusted verifier from current main")
abort_check("Release readiness verifier 必须显式来自 main") unless trusted_checkout.dig("with", "ref") == "main"
readiness_script = steps(readiness).map { |step| step["run"].to_s }.join("\n")
[
  'candidate_sha="$GITHUB_SHA"',
  'tag_sha" == "$candidate_sha',
  'candidate_sha" == "$trusted_main_sha',
  'trusted_main_sha" == "$current_main_sha',
  "release-readiness-${candidate_sha}-${release_version}",
  "actions/artifacts",
  'candidate_artifact_digest" =~ ^sha256:',
  'actual_artifact_digest" == "$artifact_digest',
  'attested_run_attempt" == "$run_attempt',
  ".github/workflows/release-validation.yml",
  '"workflow_dispatch"',
  '"success"',
  "check-release-readiness.sh verify",
].each do |needle|
  abort_check("Release readiness gate 缺少：#{needle}") unless readiness_script.include?(needle)
end
%w[verify verify-windows].each do |job_id|
  abort_check("#{job_id} 必须依赖 readiness") unless needs(release_jobs.fetch(job_id)).include?("readiness")
end
%w[verify verify-windows release].each do |job_id|
  abort_check("#{job_id} 必须使用 release production environment") unless
    release_jobs.fetch(job_id)["environment"] == "release-production-signing"
  checkout = step_named(release_jobs.fetch(job_id), "Checkout")
  abort_check("#{job_id} 必须显式 checkout 触发事件的 immutable SHA") unless
    checkout.dig("with", "ref") == "${{ github.sha }}"
end
abort_check("release 必须依赖 verify 和 verify-windows") unless
  %w[verify verify-windows].all? { |required| needs(release_jobs.fetch("release")).include?(required) }
release_text = File.read(release_path)
abort_check("正式 Windows Release 不得允许 unsigned") if release_text.include?("AllowUnsignedRelease")
abort_check("正式 Windows Release 必须校验签名") unless release_text.include?("-RequireSignature")

side_effect_jobs = []
release_jobs.each do |job_id, job|
  body = [job["permissions"], steps(job)].inspect
  next unless body.include?('"contents"=>"write"') ||
    body.match?(/gh release upload|args.*release --clean|git push/)
  side_effect_jobs << job_id
end
side_effect_jobs.each do |job_id|
  abort_check("发布副作用 job #{job_id} 没有传递依赖 readiness") unless
    transitively_depends_on?(release_jobs, job_id, "readiness")
end

# Readiness 之后仍可能发生可变 tag 竞态；每个真实发布副作用前必须再次绑定事件 SHA。
release_job = release_jobs.fetch("release")
release_steps = steps(release_job)
goreleaser_index = release_steps.index { |step| step["name"] == "Release" }
goreleaser_tag_index = release_steps.index do |step|
  step["name"] == "Revalidate release tag before GoReleaser"
end
mac_upload_index = release_steps.index do |step|
  step["name"] == "Upload Mac installer to GitHub Release"
end
mac_tag_index = release_steps.index do |step|
  step["name"] == "Revalidate release tag before Mac upload"
end
abort_check("GoReleaser 前必须紧邻重新校验 tag") unless
  goreleaser_index && goreleaser_tag_index && goreleaser_tag_index + 1 == goreleaser_index
abort_check("Mac 上传前必须紧邻重新校验 tag") unless
  mac_upload_index && mac_tag_index && mac_tag_index + 1 == mac_upload_index
[goreleaser_tag_index, mac_tag_index].zip(
  ["GoReleaser tag gate", "Mac upload tag gate"]
).each do |index, label|
  assert_unconditional_fail_closed_step(release_steps.fetch(index), label)
end
[goreleaser_index, mac_upload_index].zip(
  ["GoReleaser 发布动作", "Mac upload 发布动作"]
).each do |index, label|
  assert_unconditional_fail_closed_step(release_steps.fetch(index), label)
end
[goreleaser_tag_index, mac_tag_index].each do |index|
  script = release_steps.fetch(index).fetch("run")
  [
    'git fetch --force --no-tags origin "$GITHUB_REF"',
    "FETCH_HEAD^{commit}",
    '"$current_tag_sha" == "$GITHUB_SHA"',
  ].each do |needle|
    abort_check("Release tag 二次校验缺少：#{needle}") unless script.include?(needle)
  end
end

windows_publish = release_jobs.fetch("publish-windows")
windows_publish_steps = steps(windows_publish)
windows_checkout = step_named(windows_publish, "Checkout")
abort_check("publish-windows 必须 checkout 事件 immutable SHA 以剥离 annotated tag") unless
  windows_checkout.dig("with", "ref") == "${{ github.sha }}" &&
  windows_checkout.dig("with", "fetch-depth") == 0
windows_upload_index = windows_publish_steps.index do |step|
  step["name"] == "Upload Windows installer to GitHub Release"
end
windows_tag_index = windows_publish_steps.index do |step|
  step["name"] == "Revalidate release tag before Windows upload"
end
abort_check("Windows 上传前必须紧邻重新校验 tag") unless
  windows_upload_index && windows_tag_index && windows_tag_index + 1 == windows_upload_index
assert_unconditional_fail_closed_step(
  windows_publish_steps.fetch(windows_tag_index),
  "Windows upload tag gate"
)
assert_unconditional_fail_closed_step(
  windows_publish_steps.fetch(windows_upload_index),
  "Windows upload 发布动作"
)
windows_tag_script = windows_publish_steps.fetch(windows_tag_index).fetch("run")
[
  "git fetch --force --no-tags origin",
  '$env:GITHUB_REF',
  "FETCH_HEAD^{commit}",
  '$currentTagSha -ne $env:GITHUB_SHA',
].each do |needle|
  abort_check("Windows tag 二次校验缺少：#{needle}") unless windows_tag_script.include?(needle)
end

# iOS 手工发布和 reusable validation 都必须先绑定当前 main/SHA，再读取生产 secrets。
abort_check("iOS signing workflow 不得互相取消") unless ios.dig("concurrency", "cancel-in-progress") == false
ios_release = ios.fetch("jobs").fetch("app-store-release")
abort_check("iOS signed job 必须使用独立 production environment") unless
  ios_release["environment"] == "ios-production-signing"
signed_condition = ios_release["if"].to_s
%w[workflow_dispatch publish_app_store workflow_call validate_app_store].each do |needle|
  abort_check("iOS signed job 缺少触发条件：#{needle}") unless signed_condition.include?(needle)
end
checkout_index = steps(ios_release).index { |step| step["name"] == "Checkout clean release source" }
trust_index = steps(ios_release).index { |step| step["name"] == "Trust gate for every signed iOS path" }
secret_index = steps(ios_release).index { |step| step["name"] == "Prepare App Store signing" }
abort_check("iOS signing trust gate 必须紧随 checkout 且在读取 secrets 前执行") unless
  checkout_index && trust_index && secret_index && trust_index == checkout_index + 1 && trust_index < secret_index
trust_step = steps(ios_release).fetch(trust_index)
abort_check("iOS signing trust gate 不得只覆盖部分 signed 入口") if trust_step.key?("if")
abort_check("iOS signing trust gate 前不得读取 secrets") if
  ios_release.fetch("env", {}).inspect.include?("secrets.") ||
  steps(ios_release).take(trust_index).inspect.include?("secrets.")
trust_script = trust_step.fetch("run")
[
  "gaixianggeng/codex-ipad-agent",
  "refs/heads/main",
  "GITHUB_EVENT_NAME",
  "workflow_call",
  "GITHUB_SHA",
  "SOURCE_REF",
  "git rev-parse HEAD",
  "git fetch --no-tags origin",
  "refs/remotes/origin/main",
  'candidate_sha" == "$GITHUB_SHA',
  'head_sha" == "$candidate_sha',
  'main_sha" == "$candidate_sha',
].each do |needle|
  abort_check("iOS signing trust gate 缺少 #{needle}") unless trust_script.include?(needle)
end

archive_index = steps(ios_release).index { |step| step["name"] == "Archive, audit, upload, and distribute build" }
evidence_index = steps(ios_release).index { |step| step["name"] == "Record uploaded Internal TestFlight evidence" }
evidence_upload_index = steps(ios_release).index { |step| step["name"] == "Upload Internal TestFlight evidence" }
abort_check("Internal TestFlight 机器证据必须在真实上传成功后生成并上传") unless
  archive_index && evidence_index && evidence_upload_index &&
  archive_index < evidence_index && evidence_index < evidence_upload_index
archive_step = steps(ios_release).fetch(archive_index)
evidence_step = steps(ios_release).fetch(evidence_index)
evidence_upload = steps(ios_release).fetch(evidence_upload_index)
receipt_path = "${{ runner.temp }}/mimi-testflight/app-store-connect-receipt.json"
abort_check("Internal TestFlight 证据前必须执行真实上传脚本") unless
  archive_step["run"] == "bash ./scripts/ios_testflight_ci.sh" &&
  ios_release.dig("env", "IOS_TESTFLIGHT_UPLOAD").to_s.include?("workflow_dispatch") &&
  ios_release.dig("env", "IOS_TESTFLIGHT_UPLOAD").to_s.include?("publish_app_store") &&
  archive_step.dig("env", "TESTFLIGHT_EVIDENCE_PATH") == receipt_path &&
  evidence_step.dig("env", "TESTFLIGHT_EVIDENCE_PATH") == receipt_path
dispatch_publish_condition = "github.event_name == 'workflow_dispatch' && inputs.publish_app_store"
abort_check("Internal TestFlight 证据只能在 workflow_dispatch 发布成功路径生成") unless
  evidence_step["if"] == dispatch_publish_condition && evidence_upload["if"] == dispatch_publish_condition
abort_check("Internal TestFlight 证据必须使用唯一 SHA artifact 名") unless
  evidence_upload["uses"].to_s.start_with?("actions/upload-artifact@") &&
  evidence_upload.dig("with", "name") == "internal-testflight-evidence-${{ github.sha }}" &&
  steps(ios_release).count { |step| step.dig("with", "name") == "internal-testflight-evidence-${{ github.sha }}" } == 1
abort_check("Internal TestFlight 证据缺少 fail-closed artifact 上传") unless
  evidence_upload.dig("with", "if-no-files-found") == "error"
evidence_script = evidence_step.fetch("run")
[
  "find \"$RUNNER_TEMP/mimi-testflight\" -name '*.ipa'",
  '"${#ipa_candidates[@]}" == "1"',
  "unzip -q",
  "CFBundleIdentifier",
  "CFBundleShortVersionString",
  "CFBundleVersion",
  "shasum -a 256",
  'candidate_sha="$(git rev-parse HEAD)"',
  '"candidate_sha" => ENV.fetch("candidate_sha")',
  '"bundle_id" => ENV.fetch("bundle_id")',
  '"version" => ENV.fetch("version")',
  '"build" => ENV.fetch("build")',
  '"ipa_sha256" => ENV.fetch("ipa_sha256")',
  '"run_id" => run_id',
  '"run_attempt" => run_attempt',
  '"repository" => ENV.fetch("GITHUB_REPOSITORY")',
  '"workflow" => ENV.fetch("GITHUB_WORKFLOW")',
  '"event" => ENV.fetch("GITHUB_EVENT_NAME")',
  '"uploaded" => true',
  '"generated_at" => Time.now.utc.iso8601',
  'JSON.parse(File.binread(ENV.fetch("TESTFLIGHT_EVIDENCE_PATH")))',
  '"app_store_connect_internal_distribution"',
  'receipt["asc_processing_state"] == "VALID"',
  'receipt["internal_group"] == true',
  'receipt["tester_count"].is_a?(Integer)',
  'receipt["what_to_test_verified"] == true',
  '"asc_receipt" => receipt',
].each do |needle|
  abort_check("Internal TestFlight 机器证据缺少：#{needle}") unless evidence_script.include?(needle)
end
abort_check("Internal TestFlight 机器证据不得来自人工 JSON input") if
  evidence_script.match?(/inputs\..*evidence|EVIDENCE_JSON/)
testflight_distributor = File.read(testflight_distributor_path)
abort_check("App Store Connect 内部组判断必须严格为 true，字段缺失时失败关闭") unless
  testflight_distributor.include?(
    'abort_release("目标组不是内部测试组") unless group.dig("attributes", "isInternalGroup") == true'
  ) && testflight_distributor.include?(
    '"internal_group" => group.dig("attributes", "isInternalGroup") == true'
  )
validated_index = steps(ios_release).index { |step| step["name"] == "Record validated IPA provenance" }
validated_upload_index = steps(ios_release).index { |step| step["name"] == "Upload validated IPA without publishing" }
abort_check("reusable iOS validate 路径必须继续上传 IPA provenance") unless
  validated_index && validated_upload_index && archive_index < validated_index && validated_index < validated_upload_index
validated_step = steps(ios_release).fetch(validated_index)
validated_upload = steps(ios_release).fetch(validated_upload_index)
validate_condition = "github.event_name == 'workflow_call' && inputs.validate_app_store"
abort_check("reusable iOS validate artifact 条件错误") unless
  validated_step["if"] == validate_condition && validated_upload["if"] == validate_condition
abort_check("reusable iOS validate artifact 缺少 IPA 或 provenance") unless
  validated_upload["uses"].to_s.start_with?("actions/upload-artifact@") &&
  validated_upload.dig("with", "path").to_s.include?("**/*.ipa") &&
  validated_upload.dig("with", "path").to_s.include?("release-ios-metadata.json") &&
  validated_upload.dig("with", "if-no-files-found") == "error"

# 任何验证 workflow 都不能悄悄执行发布。
forbidden = [
  /gh release create/,
  /gh release upload/,
  /goreleaser.*release --clean/,
  /ios_testflight_local\.sh.*--upload/,
  /git push/,
]
[nightly_path, validation_path].each do |path|
  text = File.read(path)
  forbidden.each do |pattern|
    abort_check("#{path} 包含禁止的发布动作：#{pattern.source}") if text.match?(pattern)
  end
end
RUBY

  grep -Fq 'retention-days:' "$nightly" \
    || fail "Nightly artifact 没有明确保留期。"
  grep -Fq 'retention-days:' "$release_validation" \
    || fail "Release artifact 没有明确保留期。"
  grep -Fq -- '--require-all-successful' "$nightly" \
    && grep -Fq -- '--require-all-successful' "$release_validation" \
    || fail "Nightly/Release Runtime smoke 没有 fail-closed。"

  for phrase in \
    'PR Gate' \
    'Nightly' \
    'Release validation' \
    'fail-closed' \
    'Internal TestFlight' \
    'attestation'; do
    grep -Fq "$phrase" "$runbook" || fail "运行手册缺少：${phrase}"
  done

  grep -Fq 'git merge-base --is-ancestor' "$rollback_script" \
    || fail "回滚检查没有验证 previous/candidate 历史关系。"
  grep -Fq 'minimum_supported_client_revision' "$rollback_script" \
    || fail "回滚检查没有验证 MIM-28 最低客户端窗口。"
  grep -Fq 'version-current.json' "$rollback_script" \
    || fail "回滚检查没有验证 capability 状态 fixture。"
  grep -Fq 'headers' "$rollback_script" \
    || fail "回滚检查没有验证协议 header map。"

  for needle in \
    'ditto "$source_app" "$installed_app"' \
    'hdiutil detach "$mount_dir"' \
    'CFBundleVersion' \
    'runtime_version="${EXPECTED_VERSION}+mac.${bundle_build}"' \
    '"$agent_binary" serve --config' \
    '/api/version' \
    'body["build_commit"]' \
    '/api/readyz' \
    'doctor --config' \
    '"kind" => "macos_dmg_drag_install_runtime"'; do
    grep -Fq "$needle" "$macos_install_script" \
      || fail "Mac DMG 安装运行态脚本缺少：${needle}"
  done

  echo "Nightly/Release workflow 自检通过：候选信任、最小 secrets、DAG、签名、attestation 与真实发布门禁均 fail-closed。"
}

self_test() {
  run_checks >/dev/null
  local test_root
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-validation-self-test.XXXXXX")"
  trap 'rm -rf "$test_root"' EXIT
  cp "$release_validation" "$test_root/release-validation.yml"
  cp "$release" "$test_root/release.yml"

  ruby - "$test_root/release-validation.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!('ref: ${{ github.sha }}', 'ref: ${{ inputs.candidate_ref }}') or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_VALIDATION_WORKFLOW="$test_root/release-validation.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：任意 candidate_ref 没有被拒绝。"
  fi

  cp "$release_validation" "$test_root/release-validation.yml"
  ruby - "$test_root/release.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!("    needs: readiness\n", "") or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：移除 readiness dependency 没有被拒绝。"
  fi

  cp "$release" "$test_root/release.yml"
  ruby - "$test_root/release.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!('candidate_sha="$GITHUB_SHA"', 'candidate_sha="$tag_sha"') or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Release candidate 未绑定事件 GITHUB_SHA 仍被接受。"
  fi

  cp "$release" "$test_root/release.yml"
  ruby - "$test_root/release.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!(
  '[[ "$current_tag_sha" == "$GITHUB_SHA" ]]',
  '[[ -n "$current_tag_sha" ]]'
) or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：GoReleaser 前 tag 未重新绑定事件 SHA 仍被接受。"
  fi

  cp "$release" "$test_root/release.yml"
  ruby - "$test_root/release.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
needle = '[[ "$current_tag_sha" == "$GITHUB_SHA" ]]'
indices = text.enum_for(:scan, Regexp.new(Regexp.escape(needle))).map { Regexp.last_match.begin(0) }
abort("fixture mutation failed") unless indices.length >= 2
text[indices.fetch(1), needle.length] = '[[ -n "$current_tag_sha" ]]'
File.write(path, text)
RUBY
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Mac 上传前 tag 未重新绑定事件 SHA 仍被接受。"
  fi

  cp "$release" "$test_root/release.yml"
  ruby - "$test_root/release.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!(
  '$currentTagSha -ne $env:GITHUB_SHA',
  '[string]::IsNullOrWhiteSpace($currentTagSha)'
) or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Windows 上传前 peeled tag 未重新绑定事件 SHA 仍被接受。"
  fi

  cp "$release" "$test_root/release.yml"
  ruby - "$test_root/release.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
marker = "      - name: Revalidate release tag before GoReleaser\n"
text.sub!(marker, marker + "        if: ${{ false }}\n") or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：GoReleaser tag gate 可被 if 跳过。"
  fi

  cp "$release" "$test_root/release.yml"
  ruby - "$test_root/release.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
marker = "      - name: Revalidate release tag before Mac upload\n"
text.sub!(marker, marker + "        continue-on-error: true\n") or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Mac tag gate 可忽略失败。"
  fi

  cp "$release" "$test_root/release.yml"
  ruby - "$test_root/release.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
marker = "      - name: Upload Windows installer to GitHub Release\n"
text.sub!(marker, marker + "        if: always()\n") or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Windows 发布动作可用 always() 绕过失败 gate。"
  fi

  cp "$release" "$test_root/release.yml"
  printf '\n# -AllowUnsignedRelease\n' >>"$test_root/release.yml"
  if MIMI_RELEASE_WORKFLOW="$test_root/release.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：unsigned Release 没有被拒绝。"
  fi

  cp "$ios" "$test_root/ios-ci.yml"
  ruby - "$test_root/ios-ci.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
marker = "      - name: Trust gate for every signed iOS path\n"
replacement = marker + "        if: github.event_name == 'workflow_call' && inputs.validate_app_store\n"
text.sub!(marker, replacement) or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_IOS_WORKFLOW="$test_root/ios-ci.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：workflow_dispatch signed 路径绕过 trust gate 没有被拒绝。"
  fi

  cp "$release_validation" "$test_root/release-validation.yml"
  ruby - "$test_root/release-validation.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!("      internal_testflight_run_id:\n", "      internal_testflight_evidence_json:\n") or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_VALIDATION_WORKFLOW="$test_root/release-validation.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：人工 evidence JSON input 没有被拒绝。"
  fi

  cp "$release_validation" "$test_root/release-validation.yml"
  ruby - "$test_root/release-validation.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
job_start = text.index("  ios-app-store-validation:") or abort("fixture mutation failed")
start = text.index("    secrets:\n", job_start) or abort("fixture mutation failed")
finish = text.index("\n\n  controlled-runtime-smoke:", start) or abort("fixture mutation failed")
text[start...finish] = "    secrets: inherit"
File.write(path, text)
RUBY
  if MIMI_RELEASE_VALIDATION_WORKFLOW="$test_root/release-validation.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：reusable caller secrets: inherit 没有被拒绝。"
  fi

  cp "$release_validation" "$test_root/release-validation.yml"
  ruby - "$test_root/release-validation.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!("    environment: release-production-signing\n", "") or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_VALIDATION_WORKFLOW="$test_root/release-validation.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Release production environment 移除后没有被拒绝。"
  fi

  cp "$release_validation" "$test_root/release-validation.yml"
  ruby - "$test_root/release-validation.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!("bash ./scripts/test-macos-dmg-install.sh", "echo macos-install-check-skipped") or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_VALIDATION_WORKFLOW="$test_root/release-validation.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Mac DMG 安装后 readyz 检查移除后没有被拒绝。"
  fi

  cp "$release_validation" "$test_root/release-validation.yml"
  ruby - "$test_root/release-validation.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!(
  '${{ steps.evidence.outputs.testflight_source }}',
  '${{ inputs.internal_testflight_run_id }}'
) or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_VALIDATION_WORKFLOW="$test_root/release-validation.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：run ID 直接进入 attestation 没有被拒绝。"
  fi

  cp "$evidence_fetcher" "$test_root/fetch-release-evidence.sh"
  ruby - "$test_root/fetch-release-evidence.sh" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!('"conclusion" => "success"', '"conclusion" => run["conclusion"]') or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_EVIDENCE_FETCHER="$test_root/fetch-release-evidence.sh" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：evidence run success 绑定移除后没有被拒绝。"
  fi

  cp "$evidence_fetcher" "$test_root/fetch-release-evidence.sh"
  ruby - "$test_root/fetch-release-evidence.sh" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!("matches.length == 1", "matches.length >= 1") or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_EVIDENCE_FETCHER="$test_root/fetch-release-evidence.sh" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：evidence artifact 唯一性移除后没有被拒绝。"
  fi

  cp "$rollback_workflow" "$test_root/release-rollback-drill.yml"
  ruby - "$test_root/release-rollback-drill.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!("bash ./scripts/run-agentd-rollback-drill.sh", "echo rollback-drill-skipped") or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_ROLLBACK_WORKFLOW="$test_root/release-rollback-drill.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：真实 agentd rollback drill 移除后没有被拒绝。"
  fi

  cp "$rollback_workflow" "$test_root/release-rollback-drill.yml"
  ruby - "$test_root/release-rollback-drill.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!("sha256sum --check --strict", "sha256sum --version") or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_ROLLBACK_WORKFLOW="$test_root/release-rollback-drill.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：previous Release checksum 校验移除后没有被拒绝。"
  fi

  cp "$testflight_distributor" "$test_root/distribute_internal_build.rb"
  ruby - "$test_root/distribute_internal_build.rb" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.gsub!(
  'group.dig("attributes", "isInternalGroup") == true',
  'group.dig("attributes", "isInternalGroup") != false'
) or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_TESTFLIGHT_DISTRIBUTOR="$test_root/distribute_internal_build.rb" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：ASC 内部组字段缺失时仍被接受。"
  fi

  cp "$nightly" "$test_root/nightly.yml"
  ruby - "$test_root/nightly.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!("  cancel-in-progress: false", "  cancel-in-progress: true") or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_NIGHTLY_WORKFLOW="$test_root/nightly.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Nightly 取消运行中的重任务没有被拒绝。"
  fi

  cp "$nightly" "$test_root/nightly.yml"
  ruby - "$test_root/nightly.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!('[[ "$GITHUB_REF" == "refs/heads/main" ]]', '[[ -n "$GITHUB_REF" ]]') or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_NIGHTLY_WORKFLOW="$test_root/nightly.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Nightly Runtime main trust gate 移除后没有被拒绝。"
  fi

  cp "$nightly" "$test_root/nightly.yml"
  ruby - "$test_root/nightly.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
marker = "      - name: Trust gate before controlled runtime secrets\n"
injection = <<~YAML.gsub(/^/, "      ")
- name: Premature runtime secret read
  env:
    LEAK: ${{ secrets.MIMI_NIGHTLY_RUNTIME_TOKEN }}
  run: test -n "$LEAK"
YAML
text.sub!(marker, injection + marker) or abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_NIGHTLY_WORKFLOW="$test_root/nightly.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Nightly trust gate 前读取 secrets 没有被拒绝。"
  fi

  cp "$nightly" "$test_root/nightly.yml"
  ruby - "$test_root/nightly.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!('commit = body["build_commit"]', 'commit = ENV["CONTROLLED_RUNTIME_CANDIDATE_SHA"]') or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_NIGHTLY_WORKFLOW="$test_root/nightly.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Nightly 未解析 runtime build_commit 仍被接受。"
  fi

  cp "$release_validation" "$test_root/release-validation.yml"
  ruby - "$test_root/release-validation.yml" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
text.sub!('commit = body["build_commit"]', 'commit = ENV["CONTROLLED_RUNTIME_CANDIDATE_SHA"]') or
  abort("fixture mutation failed")
File.write(path, text)
RUBY
  if MIMI_RELEASE_VALIDATION_WORKFLOW="$test_root/release-validation.yml" \
    bash "$0" --check >/dev/null 2>&1; then
    fail "自测失败：Release 未解析 runtime build_commit 仍被接受。"
  fi

  rm -rf "$test_root"
  trap - EXIT
  echo "Nightly/Release workflow 负向自测通过。"
}

case "$MODE" in
  --check)
    run_checks
    ;;
  --self-test)
    self_test
    ;;
  -h|--help)
    echo "用法：bash ./scripts/check-validation-workflows.sh [--check|--self-test]"
    ;;
  *)
    fail "未知参数：$MODE"
    ;;
esac
