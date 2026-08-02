#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-release-readiness.sh create \
    --candidate-sha <40-hex> \
    --release-version <semver> \
    --previous-sha <40-hex> \
    --ios-bundle-id <bundle-id> \
    --ios-version <本次 validate-app 的版本> \
    --ios-build <本次 validate-app 的构建号> \
    --artifact-sha256 <本次 validated IPA 的 64-hex SHA-256> \
    --testflight-evidence <internal-testflight.json> \
    --testflight-source <source.json> \
    --rollback-evidence <rollback-drill.json> \
    --rollback-source <source.json> \
    --macos-install-evidence <macos-install-evidence.json> \
    --run-metadata <github-run.json> \
    --output <attestation.json>

  bash ./scripts/check-release-readiness.sh verify \
    --attestation <attestation.json> \
    --candidate-sha <40-hex> \
    --release-version <semver>

  bash ./scripts/check-release-readiness.sh --self-test

只读取本地 JSON 并写入本地 attestation；不会联网、读取凭据、发布或修改外部状态。

两份 evidence 必须来自受信 GitHub Actions artifact，并分别提供 fetcher 生成的 source.json。
checker 会绑定固定 workflow path、artifact name、run identity、candidate SHA 和 artifact digest；
不接受人工 URL 作为发布证明。详细 exact schema 由 --self-test 覆盖。

Run metadata 必须精确包含：
  schema_version, run_id, run_attempt, repository, workflow, url, verified_at
run.url 必须等于 https://github.com/<repository>/actions/runs/<run_id>。
EOF
}

fail() {
  echo "Release readiness 校验失败：$1" >&2
  exit 1
}

require_value() {
  [[ "$2" -ge 2 ]] || fail "$1 缺少值。"
}

run_validator() {
  command -v ruby >/dev/null 2>&1 || fail "缺少 ruby；本工具仅依赖 Bash 与 Ruby 标准库。"

  ruby -rjson -rtime -ruri - "$@" <<'RUBY'
class ValidationError < StandardError; end

# 同名 JSON key 会让不同解析器得出不同证据；发布判定必须失败关闭。
class StrictHash < Hash
  def []=(key, value)
    raise ValidationError, "JSON 含重复字段 #{key.inspect}" if key?(key)
    super
  end
end

OFFICIAL_REPOSITORY = "gaixianggeng/codex-ipad-agent".freeze
TESTFLIGHT_WORKFLOW_PATH = ".github/workflows/ios-ci.yml".freeze
ROLLBACK_WORKFLOW_PATH = ".github/workflows/release-rollback-drill.yml".freeze

TESTFLIGHT_KEYS = %w[
  asc_receipt build bundle_id candidate_sha event generated_at ipa_sha256 kind repository
  run_attempt run_id schema_version uploaded version workflow
].freeze
ROLLBACK_KEYS = %w[
  artifact candidate_sha drill kind observed previous release_version schema_version source_run status
].freeze
ASC_RECEIPT_KEYS = %w[
  asc_build_id asc_processing_state bundle_id generated_at internal_beta_group
  internal_beta_group_id internal_group ios_build ios_version kind schema_version tester_count
  what_to_test_verified
].freeze
SOURCE_KEYS = %w[
  artifact_created_at artifact_digest artifact_id artifact_name conclusion event head_branch
  head_sha repository run_attempt run_id schema_version workflow_path
].freeze
ROLLBACK_PREVIOUS_KEYS = %w[sha tag version].freeze
ROLLBACK_ARTIFACT_KEYS = %w[binary_sha256 checksum_verified platform release_asset_url sha256].freeze
ROLLBACK_OBSERVED_KEYS = %w[
  candidate_build_commit candidate_version doctor_ok readyz_body_sha256 readyz_http_status restored_version
].freeze
ROLLBACK_DRILL_KEYS = %w[
  candidate_deployed_sha256 completed_at mode restored_deployed_sha256 rollback_exit_code
  shared_config_sha256 started_at
].freeze
ROLLBACK_SOURCE_RUN_KEYS = %w[event head_sha repository run_attempt run_id workflow_path].freeze
RUN_KEYS = %w[repository run_attempt run_id schema_version url verified_at workflow].freeze
ATTESTATION_KEYS = %w[
  candidate_sha checks created_at internal_testflight_evidence internal_testflight_source kind
  macos_install_evidence previous_sha release_version rollback_evidence rollback_source run
  schema_version status validated_ipa
].freeze
MACOS_INSTALL_KEYS = %w[
  build candidate_sha completed_at dmg_sha256 doctor_ok install_method installed_agentd_sha256 kind
  readyz_body_sha256 readyz_http_status runtime_version schema_version started_at status version
].freeze

def reject(message)
  raise ValidationError, message
end

def read_json(path, label)
  reject("#{label} 路径为空") unless path.is_a?(String) && !path.empty?
  reject("#{label} 不存在或不是普通文件：#{path}") unless File.file?(path)
  reject("#{label} 超过 1 MiB：#{path}") if File.size(path) > 1_048_576
  value = JSON.parse(File.binread(path), object_class: StrictHash)
  reject("#{label} 顶层必须是 JSON object") unless value.is_a?(Hash)
  value
rescue JSON::ParserError => error
  reject("#{label} 不是合法 JSON：#{error.message}")
end

def exact_keys!(value, expected, label)
  reject("#{label} 必须是 JSON object") unless value.is_a?(Hash)
  actual = value.keys.sort
  expected = expected.sort
  return if actual == expected

  missing = expected - actual
  extra = actual - expected
  details = []
  details << "缺少 #{missing.join(', ')}" unless missing.empty?
  details << "多出 #{extra.join(', ')}" unless extra.empty?
  reject("#{label} 字段不完整：#{details.join('；')}")
end

def valid_sha!(value, length, label)
  reject("#{label} 必须是 #{length} 位小写十六进制字符串") unless
    value.is_a?(String) && value.match?(/\A[0-9a-f]{#{length}}\z/)
end

def valid_release_version!(value, label = "release_version")
  pattern = /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-.][0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\z/
  reject("#{label} 必须是不含 v 的语义版本") unless value.is_a?(String) && value.match?(pattern)
end

def valid_bundle_id!(value, label)
  pattern = /\A[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+\z/
  reject("#{label} 格式非法") unless value.is_a?(String) && value.match?(pattern)
end

def valid_ios_version!(value, label)
  reject("#{label} 必须是 1 至 3 段数字版本") unless
    value.is_a?(String) && value.match?(/\A(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){0,2}\z/)
end

def valid_ios_build!(value, label)
  reject("#{label} 必须是正整数构建号") unless value.is_a?(String) && value.match?(/\A[1-9][0-9]*\z/)
end

def valid_time!(value, label)
  reject("#{label} 必须是 UTC RFC3339 秒级时间") unless
    value.is_a?(String) && value.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/)
  reject("#{label} 必须是规范 UTC RFC3339 时间") unless Time.iso8601(value).utc.iso8601 == value
rescue ArgumentError
  reject("#{label} 不是有效时间")
end

def valid_https_url!(value, label)
  reject("#{label} 必须是 HTTPS URL 字符串") unless value.is_a?(String) && !value.empty?
  uri = URI.parse(value)
  reject("#{label} 必须使用 https") unless uri.is_a?(URI::HTTPS)
  reject("#{label} 缺少主机名") if uri.host.nil? || uri.host.empty?
  reject("#{label} 不允许用户名、密码或非 443 端口") if uri.user || uri.password || uri.port != 443
  reject("#{label} 不允许 fragment") if uri.fragment
  reject("#{label} 路径不能为空") if uri.path.nil? || uri.path.empty? || uri.path == "/"
rescue URI::InvalidURIError
  reject("#{label} 不是合法 URL")
end

def validate_run!(run)
  exact_keys!(run, RUN_KEYS, "run metadata")
  reject("run.schema_version 必须为 1") unless run["schema_version"] == 1
  reject("run_id 必须是十进制字符串") unless run["run_id"].is_a?(String) && run["run_id"].match?(/\A[1-9][0-9]*\z/)
  reject("run_attempt 必须是正整数") unless run["run_attempt"].is_a?(Integer) && run["run_attempt"].positive?
  reject("run.repository 非正式仓库") unless run["repository"] == OFFICIAL_REPOSITORY
  reject("run.workflow 非 Release Validation") unless
    run["workflow"] == ".github/workflows/release-validation.yml"
  valid_https_url!(run["url"], "run.url")
  valid_time!(run["verified_at"], "run.verified_at")
  expected_url = "https://github.com/#{run['repository']}/actions/runs/#{run['run_id']}"
  reject("run.url 与 repository/run_id 不一致") unless run["url"] == expected_url
end

def nonempty_string!(value, label, max_bytes = 500)
  reject("#{label} 必须是非空字符串") unless
    value.is_a?(String) && !value.strip.empty? && value.bytesize <= max_bytes
end

def valid_run_identity!(run_id, run_attempt, label)
  reject("#{label}.run_id 必须是十进制字符串") unless
    run_id.is_a?(String) && run_id.match?(/\A[1-9][0-9]*\z/)
  reject("#{label}.run_attempt 必须是正整数") unless run_attempt.is_a?(Integer) && run_attempt.positive?
end

def validate_source!(source, label:, candidate_sha:, workflow_path:, artifact_name:)
  exact_keys!(source, SOURCE_KEYS, label)
  reject("#{label}.schema_version 必须为 1") unless source["schema_version"] == 1
  reject("#{label}.repository 非正式仓库") unless source["repository"] == OFFICIAL_REPOSITORY
  reject("#{label}.workflow_path 非受信 workflow") unless source["workflow_path"] == workflow_path
  reject("#{label}.event 必须为 workflow_dispatch") unless source["event"] == "workflow_dispatch"
  reject("#{label}.head_branch 必须为 main") unless source["head_branch"] == "main"
  reject("#{label}.head_sha 与 candidate 不一致") unless source["head_sha"] == candidate_sha
  reject("#{label}.conclusion 必须为 success") unless source["conclusion"] == "success"
  reject("#{label}.artifact_name 不匹配") unless source["artifact_name"] == artifact_name
  valid_run_identity!(source["run_id"], source["run_attempt"], label)
  reject("#{label}.artifact_id 必须是正整数") unless
    source["artifact_id"].is_a?(Integer) && source["artifact_id"].positive?
  reject("#{label}.artifact_digest 格式非法") unless
    source["artifact_digest"].is_a?(String) && source["artifact_digest"].match?(/\Asha256:[0-9a-f]{64}\z/)
  valid_time!(source["artifact_created_at"], "#{label}.artifact_created_at")
end

def validate_asc_receipt!(receipt, evidence)
  exact_keys!(receipt, ASC_RECEIPT_KEYS, "ASC receipt")
  reject("ASC receipt schema_version 必须为 2") unless receipt["schema_version"] == 2
  reject("ASC receipt kind 非内部 TestFlight 分发") unless
    receipt["kind"] == "app_store_connect_internal_distribution"
  reject("ASC build 未达到 VALID") unless receipt["asc_processing_state"] == "VALID"
  reject("ASC receipt bundle/version/build 与上传 IPA 不一致") unless
    receipt["bundle_id"] == evidence["bundle_id"] &&
    receipt["ios_version"] == evidence["version"] &&
    receipt["ios_build"] == evidence["build"]
  reject("ASC receipt 未确认内部组") unless receipt["internal_group"] == true
  reject("ASC 内部组没有 tester") unless receipt["tester_count"].is_a?(Integer) && receipt["tester_count"].positive?
  reject("ASC What to Test 未回读验证") unless receipt["what_to_test_verified"] == true
  nonempty_string!(receipt["asc_build_id"], "ASC asc_build_id")
  nonempty_string!(receipt["internal_beta_group_id"], "ASC internal_beta_group_id")
  nonempty_string!(receipt["internal_beta_group"], "ASC internal_beta_group")
  valid_bundle_id!(receipt["bundle_id"], "ASC bundle_id")
  valid_ios_version!(receipt["ios_version"], "ASC ios_version")
  valid_ios_build!(receipt["ios_build"], "ASC ios_build")
  valid_time!(receipt["generated_at"], "ASC generated_at")
end

def validate_testflight!(evidence, source, candidate_sha:, bundle_id:, ios_version:)
  exact_keys!(evidence, TESTFLIGHT_KEYS, "Internal TestFlight evidence")
  reject("TestFlight schema_version 必须为 1") unless evidence["schema_version"] == 1
  reject("TestFlight kind 必须为 internal_testflight_upload") unless
    evidence["kind"] == "internal_testflight_upload"
  reject("TestFlight repository 非正式仓库") unless evidence["repository"] == OFFICIAL_REPOSITORY
  reject("TestFlight workflow 必须为 iOS CI") unless evidence["workflow"] == "iOS CI"
  reject("TestFlight event 必须为 workflow_dispatch") unless evidence["event"] == "workflow_dispatch"
  reject("TestFlight uploaded 必须为 true") unless evidence["uploaded"] == true
  reject("TestFlight candidate 与候选参数不一致") unless evidence["candidate_sha"] == candidate_sha
  reject("TestFlight bundle/version 与 validated IPA 不一致") unless
    evidence["bundle_id"] == bundle_id && evidence["version"] == ios_version
  valid_sha!(evidence["candidate_sha"], 40, "TestFlight candidate_sha")
  valid_bundle_id!(evidence["bundle_id"], "TestFlight bundle_id")
  valid_ios_version!(evidence["version"], "TestFlight version")
  # 已上传 build/digest 与本次 validate-app 产物独立，只校验其自身和 ASC receipt。
  valid_ios_build!(evidence["build"], "TestFlight build")
  valid_sha!(evidence["ipa_sha256"], 64, "TestFlight ipa_sha256")
  valid_run_identity!(evidence["run_id"], evidence["run_attempt"], "TestFlight")
  valid_time!(evidence["generated_at"], "TestFlight generated_at")
  validate_asc_receipt!(evidence["asc_receipt"], evidence)

  expected_artifact = "internal-testflight-evidence-#{candidate_sha}"
  validate_source!(source,
    label: "TestFlight source",
    candidate_sha: candidate_sha,
    workflow_path: TESTFLIGHT_WORKFLOW_PATH,
    artifact_name: expected_artifact)
  reject("TestFlight source run 与 evidence 不一致") unless
    source["run_id"] == evidence["run_id"] &&
    source["run_attempt"] == evidence["run_attempt"] &&
    source["repository"] == evidence["repository"] &&
    source["event"] == evidence["event"]
  reject("ASC receipt 晚于 TestFlight evidence") if
    Time.iso8601(evidence["asc_receipt"]["generated_at"]) > Time.iso8601(evidence["generated_at"])
  reject("TestFlight evidence 晚于 artifact 创建时间") if
    Time.iso8601(evidence["generated_at"]) > Time.iso8601(source["artifact_created_at"])
end

def validate_official_release_url!(value, tag, version)
  valid_https_url!(value, "rollback release_asset_url")
  expected = "https://github.com/#{OFFICIAL_REPOSITORY}/releases/download/#{tag}/mimi-remote_#{version}_linux_amd64.tar.gz"
  reject("rollback release_asset_url 不是正式仓库对应 tag 的 linux-amd64 产物") unless value == expected
end

def validate_rollback!(evidence, source, candidate_sha:, release_version:, previous_sha:)
  exact_keys!(evidence, ROLLBACK_KEYS, "rollback evidence")
  reject("rollback schema_version 必须为 2") unless evidence["schema_version"] == 2
  reject("rollback kind 必须为 agentd_binary_rollback_drill") unless
    evidence["kind"] == "agentd_binary_rollback_drill"
  reject("rollback status 必须为 success") unless evidence["status"] == "success"
  reject("rollback candidate/release 与候选参数不一致") unless
    evidence["candidate_sha"] == candidate_sha && evidence["release_version"] == release_version
  valid_sha!(evidence["candidate_sha"], 40, "rollback candidate_sha")
  valid_release_version!(evidence["release_version"], "rollback release_version")

  previous = evidence["previous"]
  exact_keys!(previous, ROLLBACK_PREVIOUS_KEYS, "rollback previous")
  valid_sha!(previous["sha"], 40, "rollback previous.sha")
  valid_release_version!(previous["version"], "rollback previous.version")
  reject("rollback previous.sha 与候选参数不一致") unless previous["sha"] == previous_sha
  reject("rollback previous.tag 与 version 不一致") unless previous["tag"] == "v#{previous['version']}"

  artifact = evidence["artifact"]
  exact_keys!(artifact, ROLLBACK_ARTIFACT_KEYS, "rollback artifact")
  reject("rollback artifact.platform 必须为 linux-amd64") unless artifact["platform"] == "linux-amd64"
  valid_sha!(artifact["sha256"], 64, "rollback artifact.sha256")
  valid_sha!(artifact["binary_sha256"], 64, "rollback artifact.binary_sha256")
  reject("rollback checksum 未验证") unless artifact["checksum_verified"] == true
  validate_official_release_url!(artifact["release_asset_url"], previous["tag"], previous["version"])

  observed = evidence["observed"]
  exact_keys!(observed, ROLLBACK_OBSERVED_KEYS, "rollback observed")
  reject("rollback candidate_version 不一致") unless observed["candidate_version"] == release_version
  reject("rollback candidate_build_commit 不一致") unless observed["candidate_build_commit"] == candidate_sha
  reject("rollback restored_version 不一致") unless observed["restored_version"] == previous["version"]
  reject("rollback readyz 必须为 HTTP 200") unless observed["readyz_http_status"] == 200
  valid_sha!(observed["readyz_body_sha256"], 64, "rollback readyz_body_sha256")
  reject("rollback doctor 必须通过") unless observed["doctor_ok"] == true

  drill = evidence["drill"]
  exact_keys!(drill, ROLLBACK_DRILL_KEYS, "rollback drill")
  reject("rollback drill.mode 必须为 in-place-shared-state") unless drill["mode"] == "in-place-shared-state"
  reject("rollback exit code 必须为 0") unless drill["rollback_exit_code"] == 0
  valid_sha!(drill["candidate_deployed_sha256"], 64, "rollback candidate deployed sha256")
  valid_sha!(drill["restored_deployed_sha256"], 64, "rollback restored deployed sha256")
  valid_sha!(drill["shared_config_sha256"], 64, "rollback shared config sha256")
  reject("rollback 未把部署路径替换为上一正式二进制") unless
    drill["restored_deployed_sha256"] == artifact["binary_sha256"] &&
    drill["candidate_deployed_sha256"] != drill["restored_deployed_sha256"]
  valid_time!(drill["started_at"], "rollback started_at")
  valid_time!(drill["completed_at"], "rollback completed_at")
  reject("rollback completed_at 早于 started_at") if
    Time.iso8601(drill["completed_at"]) < Time.iso8601(drill["started_at"])

  source_run = evidence["source_run"]
  exact_keys!(source_run, ROLLBACK_SOURCE_RUN_KEYS, "rollback source_run")
  reject("rollback source_run 非受信 workflow") unless
    source_run["repository"] == OFFICIAL_REPOSITORY &&
    source_run["workflow_path"] == ROLLBACK_WORKFLOW_PATH &&
    source_run["event"] == "workflow_dispatch" &&
    source_run["head_sha"] == candidate_sha
  valid_run_identity!(source_run["run_id"], source_run["run_attempt"], "rollback source_run")

  expected_artifact = "rollback-drill-evidence-#{candidate_sha}"
  validate_source!(source,
    label: "rollback source",
    candidate_sha: candidate_sha,
    workflow_path: ROLLBACK_WORKFLOW_PATH,
    artifact_name: expected_artifact)
  %w[repository workflow_path run_id run_attempt event head_sha].each do |key|
    reject("rollback source.#{key} 与 evidence.source_run 不一致") unless source[key] == source_run[key]
  end
  reject("rollback drill 晚于 artifact 创建时间") if
    Time.iso8601(drill["completed_at"]) > Time.iso8601(source["artifact_created_at"])
end

def validate_evidence_times_against_run!(testflight_source, rollback_source, run)
  [
    [testflight_source, "TestFlight source"],
    [rollback_source, "rollback source"]
  ].each do |source, label|
    reject("#{label}.artifact_created_at 晚于 attestation run.verified_at") if
      Time.iso8601(source["artifact_created_at"]) > Time.iso8601(run["verified_at"])
  end
end

def validate_macos_install!(evidence, candidate_sha:, release_version:, run:)
  exact_keys!(evidence, MACOS_INSTALL_KEYS, "macOS install evidence")
  reject("macOS install schema_version 必须为 1") unless evidence["schema_version"] == 1
  reject("macOS install kind 非预期") unless evidence["kind"] == "macos_dmg_drag_install_runtime"
  reject("macOS install status 必须为 success") unless evidence["status"] == "success"
  reject("macOS install candidate/version 不一致") unless
    evidence["candidate_sha"] == candidate_sha && evidence["version"] == release_version
  reject("macOS install_method 必须为 dmg-drag-copy") unless evidence["install_method"] == "dmg-drag-copy"
  valid_sha!(evidence["candidate_sha"], 40, "macOS install candidate_sha")
  valid_release_version!(evidence["version"], "macOS install version")
  reject("macOS install build 必须为正整数") unless evidence["build"].is_a?(Integer) && evidence["build"].positive?
  reject("macOS runtime_version 与 App version/build 不一致") unless
    evidence["runtime_version"] == "#{evidence['version']}+mac.#{evidence['build']}"
  valid_sha!(evidence["dmg_sha256"], 64, "macOS DMG sha256")
  valid_sha!(evidence["installed_agentd_sha256"], 64, "macOS installed agentd sha256")
  reject("macOS installed readyz 必须为 HTTP 200") unless evidence["readyz_http_status"] == 200
  valid_sha!(evidence["readyz_body_sha256"], 64, "macOS readyz body sha256")
  reject("macOS installed Doctor 必须通过") unless evidence["doctor_ok"] == true
  valid_time!(evidence["started_at"], "macOS install started_at")
  valid_time!(evidence["completed_at"], "macOS install completed_at")
  reject("macOS install completed_at 早于 started_at") if
    Time.iso8601(evidence["completed_at"]) < Time.iso8601(evidence["started_at"])
  reject("macOS install evidence 晚于 attestation run") if
    Time.iso8601(evidence["completed_at"]) > Time.iso8601(run["verified_at"])
end

def deep_sort(value)
  case value
  when Hash
    value.keys.sort.to_h { |key| [key, deep_sort(value[key])] }
  when Array
    value.map { |item| deep_sort(item) }
  else
    value
  end
end

def emit_json(value, output_path)
  reject("--output 不能为空") unless output_path.is_a?(String) && !output_path.empty?
  body = JSON.generate(deep_sort(value)) << "\n"
  if output_path == "-"
    STDOUT.write(body)
    return
  end

  expanded = File.expand_path(output_path)
  directory = File.dirname(expanded)
  reject("输出目录不存在：#{directory}") unless Dir.exist?(directory)
  temporary = "#{expanded}.tmp.#{$$}"
  begin
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(body)
      file.flush
      file.fsync
    end
    File.rename(temporary, expanded)
  ensure
    File.delete(temporary) if File.exist?(temporary)
  end
end

def validate_candidate!(candidate_sha, release_version, previous_sha)
  valid_sha!(candidate_sha, 40, "candidate_sha")
  valid_sha!(previous_sha, 40, "previous_sha")
  reject("candidate_sha 与 previous_sha 不能相同") if candidate_sha == previous_sha
  valid_release_version!(release_version)
end

def validate_validated_ipa!(ipa)
  exact_keys!(ipa, %w[build bundle_id sha256 version], "validated_ipa")
  valid_bundle_id!(ipa["bundle_id"], "validated_ipa.bundle_id")
  valid_ios_version!(ipa["version"], "validated_ipa.version")
  valid_ios_build!(ipa["build"], "validated_ipa.build")
  valid_sha!(ipa["sha256"], 64, "validated_ipa.sha256")
end

def create_attestation(arguments)
  reject("create 内部参数数量错误") unless arguments.length == 14
  candidate_sha, release_version, previous_sha, bundle_id, ios_version, ios_build,
    validated_ipa_sha256, testflight_path, testflight_source_path, rollback_path,
    rollback_source_path, macos_install_path, run_path, output_path = arguments

  validate_candidate!(candidate_sha, release_version, previous_sha)
  validated_ipa = {
    "bundle_id" => bundle_id,
    "version" => ios_version,
    "build" => ios_build,
    "sha256" => validated_ipa_sha256
  }
  validate_validated_ipa!(validated_ipa)
  run = read_json(run_path, "run metadata")
  validate_run!(run)
  testflight = read_json(testflight_path, "Internal TestFlight evidence")
  testflight_source = read_json(testflight_source_path, "TestFlight source")
  rollback = read_json(rollback_path, "rollback evidence")
  rollback_source = read_json(rollback_source_path, "rollback source")
  macos_install = read_json(macos_install_path, "macOS install evidence")
  validate_testflight!(testflight, testflight_source,
    candidate_sha: candidate_sha,
    bundle_id: bundle_id,
    ios_version: ios_version)
  validate_rollback!(rollback, rollback_source,
    candidate_sha: candidate_sha,
    release_version: release_version,
    previous_sha: previous_sha)
  validate_evidence_times_against_run!(testflight_source, rollback_source, run)
  validate_macos_install!(macos_install,
    candidate_sha: candidate_sha,
    release_version: release_version,
    run: run)

  # v3 ready 同时绑定安装后 Mac 运行态；其余外部 evidence 只接受受信 run/artifact。
  attestation = {
    "schema_version" => 3,
    "kind" => "mimi_release_readiness_attestation",
    "status" => "ready",
    "candidate_sha" => candidate_sha,
    "release_version" => release_version,
    "previous_sha" => previous_sha,
    "validated_ipa" => validated_ipa,
    "internal_testflight_evidence" => testflight,
    "internal_testflight_source" => testflight_source,
    "rollback_evidence" => rollback,
    "rollback_source" => rollback_source,
    "macos_install_evidence" => macos_install,
    "run" => run,
    "created_at" => run["verified_at"],
    "checks" => [
      { "name" => "validated_ipa", "status" => "success" },
      { "name" => "internal_testflight", "status" => "success" },
      { "name" => "internal_testflight_source", "status" => "success" },
      { "name" => "signed_rollback_drill", "status" => "success" },
      { "name" => "rollback_source", "status" => "success" },
      { "name" => "macos_dmg_install_runtime", "status" => "success" }
    ]
  }
  emit_json(attestation, output_path)
end

def verify_attestation(arguments)
  reject("verify 内部参数数量错误") unless arguments.length == 3
  attestation_path, expected_candidate_sha, expected_release_version = arguments
  valid_sha!(expected_candidate_sha, 40, "expected candidate_sha")
  valid_release_version!(expected_release_version, "expected release_version")

  attestation = read_json(attestation_path, "attestation")
  exact_keys!(attestation, ATTESTATION_KEYS, "attestation")
  reject("attestation.schema_version 必须为 3") unless attestation["schema_version"] == 3
  reject("attestation.kind 非预期") unless attestation["kind"] == "mimi_release_readiness_attestation"
  reject("attestation.status 必须为 ready") unless attestation["status"] == "ready"
  reject("attestation.candidate_sha 与期望不一致") unless attestation["candidate_sha"] == expected_candidate_sha
  reject("attestation.release_version 与期望不一致") unless attestation["release_version"] == expected_release_version
  validate_candidate!(attestation["candidate_sha"], attestation["release_version"], attestation["previous_sha"])
  validate_validated_ipa!(attestation["validated_ipa"])
  validate_run!(attestation["run"])
  valid_time!(attestation["created_at"], "attestation.created_at")
  reject("attestation.created_at 与 run.verified_at 不一致") unless
    attestation["created_at"] == attestation["run"]["verified_at"]

  checks = attestation["checks"]
  reject("attestation.checks 必须是数组") unless checks.is_a?(Array)
  reject("attestation.checks 必须恰好包含 6 项") unless checks.length == 6
  reject("任一 check 非 success，attestation 无效") unless
    checks.all? { |check| check.is_a?(Hash) && check["status"] == "success" }

  by_name = {}
  checks.each do |check|
    name = check["name"]
    reject("check.name 必须是非空字符串") unless name.is_a?(String) && !name.empty?
    reject("check.name 重复：#{name}") if by_name.key?(name)
    by_name[name] = check
  end
  required_checks = %w[
    internal_testflight internal_testflight_source macos_dmg_install_runtime rollback_source
    signed_rollback_drill validated_ipa
  ]
  reject("缺少必需 checks") unless by_name.keys.sort == required_checks
  exact_keys!(by_name["validated_ipa"], %w[name status], "validated_ipa check")
  exact_keys!(by_name["internal_testflight"], %w[name status], "internal_testflight check")
  exact_keys!(by_name["internal_testflight_source"], %w[name status], "internal_testflight_source check")
  exact_keys!(by_name["signed_rollback_drill"], %w[name status], "signed_rollback_drill check")
  exact_keys!(by_name["rollback_source"], %w[name status], "rollback_source check")
  exact_keys!(by_name["macos_dmg_install_runtime"], %w[name status], "macos install check")

  testflight = attestation["internal_testflight_evidence"]
  testflight_source = attestation["internal_testflight_source"]
  rollback = attestation["rollback_evidence"]
  rollback_source = attestation["rollback_source"]
  macos_install = attestation["macos_install_evidence"]
  validate_testflight!(testflight, testflight_source,
    candidate_sha: attestation["candidate_sha"],
    bundle_id: attestation["validated_ipa"]["bundle_id"],
    ios_version: attestation["validated_ipa"]["version"])
  validate_rollback!(rollback, rollback_source,
    candidate_sha: attestation["candidate_sha"],
    release_version: attestation["release_version"],
    previous_sha: attestation["previous_sha"])
  validate_evidence_times_against_run!(testflight_source, rollback_source, attestation["run"])
  validate_macos_install!(macos_install,
    candidate_sha: attestation["candidate_sha"],
    release_version: attestation["release_version"],
    run: attestation["run"])

  puts "Release readiness attestation 验证通过：candidate=#{expected_candidate_sha} version=#{expected_release_version}"
end

begin
  action = ARGV.shift
  case action
  when "create" then create_attestation(ARGV)
  when "verify" then verify_attestation(ARGV)
  else reject("未知内部动作 #{action.inspect}")
  end
rescue ValidationError, Errno::EACCES, Errno::EEXIST, Errno::ENOENT => error
  warn "Release readiness 校验失败：#{error.message}"
  exit 1
end
RUBY
}

run_create() {
  local candidate_sha="" release_version="" previous_sha=""
  local bundle_id="" ios_version="" ios_build="" artifact_sha256=""
  local testflight_evidence="" testflight_source=""
  local rollback_evidence="" rollback_source="" macos_install_evidence=""
  local run_metadata="" output_path=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --candidate-sha) require_value "$1" "$#"; candidate_sha="$2"; shift 2 ;;
      --release-version) require_value "$1" "$#"; release_version="$2"; shift 2 ;;
      --previous-sha) require_value "$1" "$#"; previous_sha="$2"; shift 2 ;;
      --ios-bundle-id) require_value "$1" "$#"; bundle_id="$2"; shift 2 ;;
      --ios-version) require_value "$1" "$#"; ios_version="$2"; shift 2 ;;
      --ios-build) require_value "$1" "$#"; ios_build="$2"; shift 2 ;;
      --artifact-sha256) require_value "$1" "$#"; artifact_sha256="$2"; shift 2 ;;
      --testflight-evidence) require_value "$1" "$#"; testflight_evidence="$2"; shift 2 ;;
      --testflight-source) require_value "$1" "$#"; testflight_source="$2"; shift 2 ;;
      --rollback-evidence) require_value "$1" "$#"; rollback_evidence="$2"; shift 2 ;;
      --rollback-source) require_value "$1" "$#"; rollback_source="$2"; shift 2 ;;
      --macos-install-evidence) require_value "$1" "$#"; macos_install_evidence="$2"; shift 2 ;;
      --run-metadata) require_value "$1" "$#"; run_metadata="$2"; shift 2 ;;
      --output) require_value "$1" "$#"; output_path="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) usage >&2; fail "create 未知参数 $1。" ;;
    esac
  done

  local required_values=(
    "$candidate_sha" "$release_version" "$previous_sha" "$bundle_id" "$ios_version" "$ios_build"
    "$artifact_sha256" "$testflight_evidence" "$testflight_source" "$rollback_evidence"
    "$rollback_source" "$macos_install_evidence" "$run_metadata" "$output_path"
  )
  local value
  for value in "${required_values[@]}"; do
    [[ -n "$value" ]] || fail "create 缺少必需参数；请查看 --help。"
  done

  run_validator create \
    "$candidate_sha" "$release_version" "$previous_sha" "$bundle_id" "$ios_version" "$ios_build" \
    "$artifact_sha256" "$testflight_evidence" "$testflight_source" "$rollback_evidence" \
    "$rollback_source" "$macos_install_evidence" "$run_metadata" "$output_path"
}

run_verify() {
  local attestation="" candidate_sha="" release_version=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --attestation) require_value "$1" "$#"; attestation="$2"; shift 2 ;;
      --candidate-sha) require_value "$1" "$#"; candidate_sha="$2"; shift 2 ;;
      --release-version) require_value "$1" "$#"; release_version="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) usage >&2; fail "verify 未知参数 $1。" ;;
    esac
  done
  [[ -n "$attestation" && -n "$candidate_sha" && -n "$release_version" ]] \
    || fail "verify 缺少 --attestation、--candidate-sha 或 --release-version。"
  run_validator verify "$attestation" "$candidate_sha" "$release_version"
}

run_self_test() {
  command -v ruby >/dev/null 2>&1 || fail "自测缺少 ruby。"
  command -v mktemp >/dev/null 2>&1 || fail "自测缺少 mktemp。"
  local test_dir
  test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-release-readiness-test.XXXXXX")"
  trap 'rm -rf "$test_dir"' RETURN

  local candidate_sha="1111111111111111111111111111111111111111"
  local previous_sha="2222222222222222222222222222222222222222"
  local release_version="1.4.0"
  local bundle_id="com.gaixianggeng.mimi"
  local testflight_path="$test_dir/testflight.json"
  local testflight_source_path="$test_dir/testflight-source.json"
  local rollback_path="$test_dir/rollback.json"
  local rollback_source_path="$test_dir/rollback-source.json"
  local macos_install_path="$test_dir/macos-install.json"
  local run_path="$test_dir/run.json"
  local attestation_path="$test_dir/attestation.json"

  ruby -rjson - "$testflight_path" "$testflight_source_path" "$rollback_path" "$rollback_source_path" "$macos_install_path" "$run_path" <<'RUBY'
testflight_path, testflight_source_path, rollback_path, rollback_source_path, macos_install_path, run_path = ARGV
candidate_sha = "1111111111111111111111111111111111111111"
previous_sha = "2222222222222222222222222222222222222222"
repository = "gaixianggeng/codex-ipad-agent"
File.write(testflight_path, JSON.generate(
  "schema_version" => 1,
  "kind" => "internal_testflight_upload",
  "candidate_sha" => candidate_sha,
  "bundle_id" => "com.gaixianggeng.mimi",
  "version" => "1.4.0",
  "build" => "104",
  "ipa_sha256" => "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "run_id" => "8999",
  "run_attempt" => 1,
  "repository" => repository,
  "workflow" => "iOS CI",
  "event" => "workflow_dispatch",
  "uploaded" => true,
  "generated_at" => "2026-08-01T08:05:00Z",
  "asc_receipt" => {
    "schema_version" => 2,
    "kind" => "app_store_connect_internal_distribution",
    "asc_build_id" => "500104",
    "asc_processing_state" => "VALID",
    "bundle_id" => "com.gaixianggeng.mimi",
    "ios_version" => "1.4.0",
    "ios_build" => "104",
    "internal_beta_group_id" => "6001",
    "internal_beta_group" => "Internal",
    "internal_group" => true,
    "tester_count" => 3,
    "what_to_test_verified" => true,
    "generated_at" => "2026-08-01T08:04:00Z"
  }
) << "\n")
File.write(testflight_source_path, JSON.generate(
  "schema_version" => 1,
  "repository" => repository,
  "workflow_path" => ".github/workflows/ios-ci.yml",
  "run_id" => "8999",
  "run_attempt" => 1,
  "event" => "workflow_dispatch",
  "head_branch" => "main",
  "head_sha" => candidate_sha,
  "conclusion" => "success",
  "artifact_id" => 101,
  "artifact_name" => "internal-testflight-evidence-#{candidate_sha}",
  "artifact_digest" => "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  "artifact_created_at" => "2026-08-01T08:06:00Z"
) << "\n")
File.write(rollback_path, JSON.generate(
  "schema_version" => 2,
  "kind" => "agentd_binary_rollback_drill",
  "status" => "success",
  "candidate_sha" => candidate_sha,
  "release_version" => "1.4.0",
  "previous" => {
    "tag" => "v1.3.0",
    "sha" => previous_sha,
    "version" => "1.3.0"
  },
  "artifact" => {
    "platform" => "linux-amd64",
    "release_asset_url" => "https://github.com/#{repository}/releases/download/v1.3.0/mimi-remote_1.3.0_linux_amd64.tar.gz",
    "sha256" => "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "binary_sha256" => "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "checksum_verified" => true
  },
  "observed" => {
    "candidate_version" => "1.4.0",
    "candidate_build_commit" => candidate_sha,
    "restored_version" => "1.3.0",
    "readyz_http_status" => 200,
    "readyz_body_sha256" => "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "doctor_ok" => true
  },
  "drill" => {
    "mode" => "in-place-shared-state",
    "rollback_exit_code" => 0,
    "candidate_deployed_sha256" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "restored_deployed_sha256" => "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "shared_config_sha256" => "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "started_at" => "2026-08-01T08:10:00Z",
    "completed_at" => "2026-08-01T08:11:00Z"
  },
  "source_run" => {
    "repository" => repository,
    "workflow_path" => ".github/workflows/release-rollback-drill.yml",
    "run_id" => "8998",
    "run_attempt" => 1,
    "event" => "workflow_dispatch",
    "head_sha" => candidate_sha
  }
) << "\n")
File.write(rollback_source_path, JSON.generate(
  "schema_version" => 1,
  "repository" => repository,
  "workflow_path" => ".github/workflows/release-rollback-drill.yml",
  "run_id" => "8998",
  "run_attempt" => 1,
  "event" => "workflow_dispatch",
  "head_branch" => "main",
  "head_sha" => candidate_sha,
  "conclusion" => "success",
  "artifact_id" => 102,
  "artifact_name" => "rollback-drill-evidence-#{candidate_sha}",
  "artifact_digest" => "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "artifact_created_at" => "2026-08-01T08:12:00Z"
) << "\n")
File.write(macos_install_path, JSON.generate(
  "schema_version" => 1,
  "kind" => "macos_dmg_drag_install_runtime",
  "status" => "success",
  "candidate_sha" => candidate_sha,
  "version" => "1.4.0",
  "build" => 311,
  "runtime_version" => "1.4.0+mac.311",
  "install_method" => "dmg-drag-copy",
  "dmg_sha256" => "ab" * 32,
  "installed_agentd_sha256" => "cd" * 32,
  "readyz_http_status" => 200,
  "readyz_body_sha256" => "ef" * 32,
  "doctor_ok" => true,
  "started_at" => "2026-08-01T08:15:00Z",
  "completed_at" => "2026-08-01T08:16:00Z"
) << "\n")
File.write(run_path, JSON.generate(
  "schema_version" => 1,
  "run_id" => "9001",
  "run_attempt" => 2,
  "repository" => "gaixianggeng/codex-ipad-agent",
  "workflow" => ".github/workflows/release-validation.yml",
  "url" => "https://github.com/gaixianggeng/codex-ipad-agent/actions/runs/9001",
  "verified_at" => "2026-08-02T08:30:00Z"
) << "\n")
RUBY

  # 本次 validate-app build=105/digest=a...，已存在 TF build=104/digest=b...；正向用例证明二者不被误绑。
  local create_args=(
    create
    --candidate-sha "$candidate_sha"
    --release-version "$release_version"
    --previous-sha "$previous_sha"
    --ios-bundle-id "$bundle_id"
    --ios-version "1.4.0"
    --ios-build "105"
    --artifact-sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    --testflight-evidence "$testflight_path"
    --testflight-source "$testflight_source_path"
    --rollback-evidence "$rollback_path"
    --rollback-source "$rollback_source_path"
    --macos-install-evidence "$macos_install_path"
    --run-metadata "$run_path"
    --output "$attestation_path"
  )
  bash "$SCRIPT_PATH" "${create_args[@]}"
  bash "$SCRIPT_PATH" verify --attestation "$attestation_path" \
    --candidate-sha "$candidate_sha" --release-version "$release_version" >/dev/null

  expect_failure() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      echo "自测失败：${label} 应被拒绝。" >&2
      return 1
    fi
  }

  expect_failure "verify candidate mismatch" bash "$SCRIPT_PATH" verify \
    --attestation "$attestation_path" --candidate-sha "3333333333333333333333333333333333333333" \
    --release-version "$release_version"

  local invalid_path="$test_dir/invalid.json"
  mutate_json_path() {
    ruby -rjson - "$1" "$2" "$3" "$4" <<'RUBY'
source, target, path, raw_value = ARGV
value = JSON.parse(File.read(source))
keys = path.split(".")
container = keys[0...-1].reduce(value) { |current, key| current.fetch(key) }
key = keys.last
if raw_value == "__DELETE__"
  container.delete(key)
elsif raw_value.start_with?("__INT__:")
  container[key] = Integer(raw_value.delete_prefix("__INT__:"), 10)
elsif raw_value.start_with?("__BOOL__:")
  container[key] = raw_value.delete_prefix("__BOOL__:") == "true"
else
  container[key] = raw_value
end
File.write(target, JSON.generate(value) << "\n")
RUBY
  }

  # create_args 中两份 evidence/source 的 path 下标固定，便于逐项替换后恢复。
  mutate_json_path "$testflight_path" "$invalid_path" candidate_sha "3333333333333333333333333333333333333333"
  create_args[16]="$invalid_path"
  expect_failure "evidence candidate mismatch" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[16]="$testflight_path"

  mutate_json_path "$testflight_source_path" "$invalid_path" run_id "7777"
  create_args[18]="$invalid_path"
  expect_failure "forged source run" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[18]="$testflight_source_path"

  mutate_json_path "$testflight_source_path" "$invalid_path" artifact_digest "sha256:abc"
  create_args[18]="$invalid_path"
  expect_failure "invalid artifact digest" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[18]="$testflight_source_path"

  mutate_json_path "$testflight_path" "$invalid_path" asc_receipt.asc_processing_state "PROCESSING"
  create_args[16]="$invalid_path"
  expect_failure "non-VALID ASC state" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[16]="$testflight_path"

  mutate_json_path "$rollback_path" "$invalid_path" observed.readyz_http_status "__INT__:503"
  create_args[20]="$invalid_path"
  expect_failure "rollback readyz failure" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[20]="$rollback_path"

  mutate_json_path "$rollback_source_path" "$invalid_path" workflow_path ".github/workflows/ios-ci.yml"
  create_args[22]="$invalid_path"
  expect_failure "rollback source path mismatch" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[22]="$rollback_source_path"

  mutate_json_path "$rollback_path" "$invalid_path" artifact.release_asset_url "https://example.com/fake.tar.gz"
  create_args[20]="$invalid_path"
  expect_failure "non-official rollback asset URL" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[20]="$rollback_path"

  mutate_json_path "$macos_install_path" "$invalid_path" readyz_http_status "__INT__:503"
  create_args[24]="$invalid_path"
  expect_failure "macOS installed readyz failure" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[24]="$macos_install_path"

  mutate_json_path "$testflight_path" "$invalid_path" asc_receipt "__DELETE__"
  create_args[16]="$invalid_path"
  expect_failure "missing evidence field" bash "$SCRIPT_PATH" "${create_args[@]}"
  create_args[16]="$testflight_path"

  local invalid_attestation="$test_dir/invalid-attestation.json"
  ruby -rjson - "$attestation_path" "$invalid_attestation" <<'RUBY'
source, target = ARGV
value = JSON.parse(File.read(source))
value.fetch("checks").fetch(1)["status"] = "failure"
File.write(target, JSON.generate(value) << "\n")
RUBY
  expect_failure "non-success check" bash "$SCRIPT_PATH" verify \
    --attestation "$invalid_attestation" --candidate-sha "$candidate_sha" --release-version "$release_version"

  rm -rf "$test_dir"
  trap - RETURN
  echo "Release readiness v3 自测通过（受信 run/artifact/ASC/rollback/Mac 安装证据及反向用例）。"
}

case "${1:-}" in
  create) shift; run_create "$@" ;;
  verify) shift; run_verify "$@" ;;
  --self-test)
    [[ "$#" -eq 1 ]] || fail "--self-test 不接受其他参数。"
    run_self_test
    ;;
  -h|--help) usage ;;
  "") usage >&2; exit 2 ;;
  *) usage >&2; fail "未知动作 $1。" ;;
esac
