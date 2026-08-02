#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CANDIDATE_REF="HEAD"
PREVIOUS_REF=""
OUTPUT_PATH=""

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-rollback-readiness.sh \
    --candidate-ref <commit-or-tag> \
    --previous-ref <known-good-commit-or-tag> \
    [--output <report.md>]

只读取 Git 历史并生成发布前回滚报告，不安装、停止、回滚或发布任何真实服务。
previous 必须是 candidate 的祖先；缺少上一已知版本或兼容证据时脚本会失败关闭。
EOF
}

fail() {
  echo "回滚就绪检查失败：$1" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --candidate-ref)
      [[ "$#" -ge 2 ]] || fail "--candidate-ref 缺少值。"
      CANDIDATE_REF="$2"
      shift 2
      ;;
    --previous-ref)
      [[ "$#" -ge 2 ]] || fail "--previous-ref 缺少值。"
      PREVIOUS_REF="$2"
      shift 2
      ;;
    --output)
      [[ "$#" -ge 2 ]] || fail "--output 缺少值。"
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "未知参数 $1。"
      ;;
  esac
done

[[ -n "$PREVIOUS_REF" ]] || fail "必须显式提供 --previous-ref，不能猜测上一已知版本。"

for command_name in cat git go grep mkdir mktemp ruby sed tar tr; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令 ${command_name}。"
done

candidate_sha="$(git rev-parse --verify "${CANDIDATE_REF}^{commit}" 2>/dev/null)" \
  || fail "candidate 不是可读取的 commit：${CANDIDATE_REF}"
previous_sha="$(git rev-parse --verify "${PREVIOUS_REF}^{commit}" 2>/dev/null)" \
  || fail "previous 不是可读取的 commit：${PREVIOUS_REF}"
[[ "$candidate_sha" != "$previous_sha" ]] \
  || fail "candidate 与 previous 指向同一 commit，无法证明降级路径。"
git merge-base --is-ancestor "$previous_sha" "$candidate_sha" \
  || fail "previous 不是 candidate 的祖先；拒绝对不明确的历史关系给出发布结论。"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-rollback-readiness.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
candidate_contract="$work_dir/candidate-contract.json"
previous_contract="$work_dir/previous-contract.json"
contract_report="$work_dir/contract-report.md"
contract_errors="$work_dir/contract-errors.txt"
fixture_report="$work_dir/fixture-report.md"
fixture_errors="$work_dir/fixture-errors.txt"
runtime_contract_log="$work_dir/runtime-contract.log"
current_fixture="$work_dir/version-current.json"
previous_fixture="$work_dir/version-previous.json"
unknown_fixture="$work_dir/version-unknown-capability.json"
generated_go="$work_dir/protocol-contract.generated.go"
generated_swift="$work_dir/ProtocolContract.generated.swift"

git show "${candidate_sha}:contracts/mimi-protocol/contract.json" >"$candidate_contract" \
  || fail "candidate 缺少 Mimi 协议契约。"
git show "${candidate_sha}:contracts/mimi-protocol/fixtures/version-current.json" >"$current_fixture" \
  || fail "candidate 缺少当前版本协议 fixture。"
git show "${candidate_sha}:contracts/mimi-protocol/fixtures/version-previous.json" >"$previous_fixture" \
  || fail "candidate 缺少 revision-1 fixture。"
git show "${candidate_sha}:contracts/mimi-protocol/fixtures/version-unknown-capability.json" >"$unknown_fixture" \
  || fail "candidate 缺少未知 capability fixture。"
git show "${candidate_sha}:internal/protocolcontract/generated.go" >"$generated_go" \
  || fail "candidate 缺少 Go 协议生成文件。"
git show "${candidate_sha}:ios/MimiRemote/Sources/Core/Models/ProtocolContract.generated.swift" >"$generated_swift" \
  || fail "candidate 缺少 iOS 协议生成文件。"

# legacy fixture 是 N-1 缺少协议字段时的唯一 golden；它必须保持首次引入时的语义，
# 不能随 candidate 的 legacy revision 字段被重写后再反过来“证明”兼容。
legacy_fixture_origin="$(
  git log --reverse --diff-filter=A --format='%H' "$candidate_sha" \
    -- contracts/mimi-protocol/fixtures/version-previous.json | sed -n '1p'
)"
[[ -n "$legacy_fixture_origin" ]] || fail "无法定位 revision-1 fixture 的首次引入 commit。"
git diff --quiet "$legacy_fixture_origin" "$candidate_sha" \
  -- contracts/mimi-protocol/fixtures/version-previous.json \
  || fail "revision-1 fixture 自首次引入后发生漂移；必须提供独立迁移证据，不能重写回滚基线。"

previous_contract_source="previous commit contract.json"
if ! git show "${previous_sha}:contracts/mimi-protocol/contract.json" >"$previous_contract" 2>/dev/null; then
  # 第一次引入正式协议 manifest 时，上一正式版本没有 contract.json。
  # 使用固定的 revision-1 协议窗口，并要求 frozen fixture 精确匹配；禁止再从 candidate
  # 的 legacy_client_revision / legacy_server_revision 构造上一版基线。
  ruby -rjson - "$previous_fixture" >"$previous_contract" <<'RUBY'
fixture_path = ARGV.fetch(0)
fixture = JSON.parse(File.read(fixture_path))
expected = {
  "name" => "agentd",
  "version" => "previous",
  "installation_id" => "00112233-4455-4677-8899-aabbccddeeff",
}
abort("legacy fixture 与冻结的 revision-1 语义不一致") unless fixture == expected
puts JSON.pretty_generate(
  "schema_version" => 1,
  "protocol_name" => "mimi-agent-api",
  "current_revision" => 1,
  "minimum_supported_client_revision" => 1,
  "minimum_supported_server_revision" => 1,
  "headers" => {
    "client_revision" => "X-Mimi-Protocol-Revision",
    "minimum_server_revision" => "X-Mimi-Minimum-Server-Protocol-Revision",
    "server_revision" => "X-Mimi-Server-Protocol-Revision",
    "minimum_client_revision" => "X-Mimi-Minimum-Client-Protocol-Revision",
  },
  "capabilities" => [],
)
RUBY
  previous_contract_source="冻结的 revision-1 fixture（首次引入：${legacy_fixture_origin}；previous 无 manifest）"
fi

set +e
ruby -rjson - "$candidate_contract" "$previous_contract" >"$contract_report" 2>"$contract_errors" <<'RUBY'
candidate_path, previous_path = ARGV
candidate = JSON.parse(File.read(candidate_path))
previous = JSON.parse(File.read(previous_path))
errors = []

expected_headers = {
  "client_revision" => "X-Mimi-Protocol-Revision",
  "minimum_server_revision" => "X-Mimi-Minimum-Server-Protocol-Revision",
  "server_revision" => "X-Mimi-Server-Protocol-Revision",
  "minimum_client_revision" => "X-Mimi-Minimum-Client-Protocol-Revision",
}

required_integer_keys = %w[
  current_revision
  minimum_supported_client_revision
  minimum_supported_server_revision
]
[["candidate", candidate], ["previous", previous]].each do |label, contract|
  required_integer_keys.each do |key|
    errors << "#{label}.#{key} 必须是正整数" unless contract[key].is_a?(Integer) && contract[key].positive?
  end
  errors << "#{label}.capabilities 必须是字符串数组" unless
    contract["capabilities"].is_a?(Array) && contract["capabilities"].all? { |item| item.is_a?(String) }
  errors << "#{label}.headers 必须完整匹配冻结的四项 header map" unless
    contract["headers"] == expected_headers
  capabilities = contract["capabilities"]
  if capabilities.is_a?(Array)
    errors << "#{label}.capabilities 不能包含空值" if
      capabilities.any? { |item| !item.is_a?(String) || item.strip.empty? }
    errors << "#{label}.capabilities 不能包含重复值" unless capabilities.uniq == capabilities
  end
end

if errors.empty?
  errors << "schema_version 改变，缺少显式迁移证据" unless candidate["schema_version"] == previous["schema_version"]
  errors << "protocol_name 改变，不能视为同一兼容窗口" unless candidate["protocol_name"] == previous["protocol_name"]
  errors << "协议 header map 改变，上一版与 candidate 不能共用同一握手窗口" unless
    candidate["headers"] == previous["headers"]
  errors << "candidate revision 不能低于 previous revision" if
    candidate["current_revision"] < previous["current_revision"]
  errors << "previous 客户端不能连接 candidate agentd" if
    candidate["minimum_supported_client_revision"] > previous["current_revision"]
  errors << "candidate 客户端不能连接 previous agentd" if
    candidate["minimum_supported_server_revision"] > previous["current_revision"]
  errors << "candidate revision 不满足 previous 声明的最低客户端要求" if
    previous["minimum_supported_client_revision"] > candidate["current_revision"]
  errors << "candidate revision 不满足 previous 声明的最低服务端要求" if
    previous["minimum_supported_server_revision"] > candidate["current_revision"]

  # capability 缺失本身表示服务端停止声明/安全降级，不是协议不兼容。
  # 是否误授权、未知 state 或生成代码漂移由下方真实契约入口与负向 fixture 判定。
end

puts "| 项目 | 上一已知版本 | 当前候选 |"
puts "| --- | --- | --- |"
puts "| protocol revision | `#{previous["current_revision"]}` | `#{candidate["current_revision"]}` |"
puts "| minimum client revision | `#{previous["minimum_supported_client_revision"]}` | `#{candidate["minimum_supported_client_revision"]}` |"
puts "| minimum server revision | `#{previous["minimum_supported_server_revision"]}` | `#{candidate["minimum_supported_server_revision"]}` |"
puts "| protocol headers | `#{previous.fetch("headers", {}).values.join(", ")}` | `#{candidate.fetch("headers", {}).values.join(", ")}` |"
puts "| capabilities | `#{previous.fetch("capabilities", []).join(", ")}` | `#{candidate.fetch("capabilities", []).join(", ")}` |"

unless errors.empty?
  warn errors.map { |item| "- #{item}" }.join("\n")
  exit 1
end
RUBY
contract_status=$?
set -e

set +e
ruby -rjson -rdigest - \
  "$candidate_contract" \
  "$current_fixture" \
  "$previous_fixture" \
  "$unknown_fixture" \
  "$generated_go" \
  "$generated_swift" \
  >"$fixture_report" 2>"$fixture_errors" <<'RUBY'
contract_path, current_path, previous_path, unknown_path, go_path, swift_path = ARGV
contract = JSON.parse(File.read(contract_path))
current = JSON.parse(File.read(current_path))
legacy = JSON.parse(File.read(previous_path))
unknown = JSON.parse(File.read(unknown_path))
go_source = File.read(go_path)
swift_source = File.read(swift_path)
errors = []

expected_legacy = {
  "name" => "agentd",
  "version" => "previous",
  "installation_id" => "00112233-4455-4677-8899-aabbccddeeff",
}
errors << "revision-1 fixture 不再等于冻结的 legacy payload" unless legacy == expected_legacy

capabilities = contract["capabilities"]
unless capabilities.is_a?(Array) && capabilities.all? { |item| item.is_a?(String) && !item.strip.empty? }
  errors << "contract.capabilities 必须是非空字符串数组"
  capabilities = []
end

def statuses_by_name(fixture, errors, label)
  raw = fixture["capability_statuses"]
  unless raw.is_a?(Array)
    errors << "#{label}.capability_statuses 必须是数组"
    return {}
  end
  grouped = raw.group_by { |item| item.is_a?(Hash) ? item["name"] : nil }
  errors << "#{label}.capability_statuses 不能包含重复或无名项" if
    grouped.key?(nil) || grouped.any? { |_name, items| items.length != 1 }
  raw.each do |item|
    unless item.is_a?(Hash) &&
           item["name"].is_a?(String) && !item["name"].strip.empty? &&
           item["state"].is_a?(String) && !item["state"].strip.empty? &&
           item["reason"].is_a?(String) && !item["reason"].strip.empty?
      errors << "#{label}.capability_statuses 的 name/state/reason 必须是非空字符串"
    end
  end
  grouped.transform_values(&:first)
end

# 与 iOS HostCapabilityNegotiation 相同的安全决策：重复、未知 state、
# enabled 但未声明均不能授权新能力。
def capability_decision(fixture, capability)
  declared = Array(fixture["capabilities"]).include?(capability)
  statuses = Array(fixture["capability_statuses"]).select do |status|
    status.is_a?(Hash) && status["name"] == capability
  end
  return "negotiation_failed" if statuses.length > 1
  return declared ? "enabled" : "server_unsupported" if statuses.empty?

  state = statuses.first["state"]
  if declared
    return state == "enabled" ? "enabled" : "negotiation_failed"
  end
  return "locally_disabled" if state == "locally_disabled"
  return "dependency_unavailable" if state == "dependency_unavailable"

  "negotiation_failed"
end

errors << "version-current.protocol_revision 未对齐 contract.current_revision" unless
  current["protocol_revision"] == contract["current_revision"]
errors << "version-current.minimum_client_protocol_revision 未对齐 contract" unless
  current["minimum_client_protocol_revision"] == contract["minimum_supported_client_revision"]
errors << "version-current.capabilities 未精确覆盖 contract.capabilities" unless
  Array(current["capabilities"]).sort == capabilities.sort

current_statuses = statuses_by_name(current, errors, "version-current")
errors << "version-current 的状态项必须与已知 capability 一一对应" unless
  current_statuses.keys.compact.sort == capabilities.sort
capabilities.each do |capability|
  status = current_statuses[capability]
  errors << "version-current #{capability} 必须声明 enabled/available" unless
    status.is_a?(Hash) && status["state"] == "enabled" && status["reason"] == "available"
  errors << "已知 capability #{capability} 未得到 enabled 决策" unless
    capability_decision(current, capability) == "enabled"
end

errors << "version-unknown-capability.protocol_revision 必须保持在当前兼容窗口" unless
  unknown["protocol_revision"] == contract["current_revision"] &&
    unknown["minimum_client_protocol_revision"] == contract["minimum_supported_client_revision"]
unknown_capabilities = Array(unknown["capabilities"])
errors << "未知 capability fixture 至少需要一个未来能力" if unknown_capabilities.empty?
errors << "未知 capability fixture 不能夹带当前已知能力" unless
  (unknown_capabilities & capabilities).empty?
unknown_statuses = statuses_by_name(unknown, errors, "version-unknown-capability")
errors << "未知 capability fixture 的状态项必须与未来能力一一对应" unless
  unknown_statuses.keys.compact.sort == unknown_capabilities.sort
capabilities.each do |capability|
  errors << "未知 capability fixture 意外授权已知能力 #{capability}" unless
    capability_decision(unknown, capability) == "server_unsupported"
end
unknown_capabilities.each do |capability|
  errors << "未来未知 state 必须 fail-closed：#{capability}" unless
    capability_decision(unknown, capability) == "negotiation_failed"
end

# 内建负向 fixture：即使 known capability 名称存在，未知 state、重复状态或
# “enabled 但未声明”都必须失败关闭，防止校验器本身退化为只看名称。
unless capabilities.empty?
  known = capabilities.first
  unknown_state = Marshal.load(Marshal.dump(current))
  unknown_state["capability_statuses"].find { |item| item["name"] == known }["state"] = "future_rollout_state"
  errors << "负向 fixture：未知 known-capability state 未 fail-closed" unless
    capability_decision(unknown_state, known) == "negotiation_failed"

  duplicate = Marshal.load(Marshal.dump(current))
  duplicate["capability_statuses"] << duplicate["capability_statuses"].find { |item| item["name"] == known }.dup
  errors << "负向 fixture：重复 capability status 未 fail-closed" unless
    capability_decision(duplicate, known) == "negotiation_failed"

  undeclared = Marshal.load(Marshal.dump(current))
  undeclared["capabilities"] = Array(undeclared["capabilities"]) - [known]
  errors << "负向 fixture：enabled 但未声明的 capability 未 fail-closed" unless
    capability_decision(undeclared, known) == "negotiation_failed"

  locally_disabled = Marshal.load(Marshal.dump(undeclared))
  locally_disabled_status = locally_disabled["capability_statuses"].find { |item| item["name"] == known }
  locally_disabled_status["state"] = "locally_disabled"
  locally_disabled_status["reason"] = "disabled_by_local_config"
  errors << "负向 fixture：本地禁用 capability 未保持 fail-closed 诊断" unless
    capability_decision(locally_disabled, known) == "locally_disabled"

  dependency_unavailable = Marshal.load(Marshal.dump(undeclared))
  dependency_status = dependency_unavailable["capability_statuses"].find { |item| item["name"] == known }
  dependency_status["state"] = "dependency_unavailable"
  dependency_status["reason"] = "storage_unavailable"
  errors << "负向 fixture：依赖不可用 capability 未保持 fail-closed 诊断" unless
    capability_decision(dependency_unavailable, known) == "dependency_unavailable"
end

header_constants = {
  "client_revision" => ["ClientRevisionHeader", "clientRevisionHeader"],
  "minimum_server_revision" => ["MinimumServerRevisionHeader", "minimumServerRevisionHeader"],
  "server_revision" => ["ServerRevisionHeader", "serverRevisionHeader"],
  "minimum_client_revision" => ["MinimumClientRevisionHeader", "minimumClientRevisionHeader"],
}
headers = contract["headers"]
unless headers.is_a?(Hash)
  errors << "contract.headers 必须是 object"
  headers = {}
end
header_constants.each do |key, (go_name, swift_name)|
  value = headers[key]
  next errors << "contract.headers.#{key} 缺失" unless value.is_a?(String)

  errors << "Go 生成文件未精确消费 headers.#{key}" unless
    go_source.match?(/#{Regexp.escape(go_name)}\s*=\s*#{Regexp.escape(value.dump)}/)
  errors << "iOS 生成文件未精确消费 headers.#{key}" unless
    swift_source.match?(/static let #{Regexp.escape(swift_name)}\s*=\s*#{Regexp.escape(value.dump)}/)
end

normalized_contract = File.binread(contract_path).gsub("\r\n", "\n").gsub("\r", "\n")
contract_hash = Digest::SHA256.hexdigest(normalized_contract)
errors << "Go 生成文件的 contract hash 已漂移" unless
  go_source.match?(/SpecSHA256\s*=\s*#{Regexp.escape(contract_hash.dump)}/)
errors << "iOS 生成文件的 contract hash 已漂移" unless
  swift_source.match?(/static let specSHA256\s*=\s*#{Regexp.escape(contract_hash.dump)}/)

puts "| 语义证据 | 预期结果 |"
puts "| --- | --- |"
puts "| revision-1 fixture | 冻结 payload，无协议/capability 字段 |"
puts "| version-current | 每个已知 capability 均为 `enabled / available` |"
puts "| version-unknown-capability | 未来 state 保留可解码，但决策为 `negotiation_failed` |"
puts "| 内建负向 fixture | 未知/重复/未声明及本地禁用、依赖不可用均 fail-closed |"
puts "| 四项 header map | Go 与 iOS 生成常量及 contract hash 精确一致 |"

unless errors.empty?
  warn errors.map { |item| "- #{item}" }.join("\n")
  exit 1
end
RUBY
fixture_status=$?
set -e

# 在 candidate 自己的干净归档中运行真实协议入口，避免用当前工作树脚本
# “解释”历史 commit，也避免复制一套会与生产解析路径漂移的伪校验。
candidate_runtime_dir="$work_dir/candidate-runtime-contract"
mkdir -p "$candidate_runtime_dir"
git archive "$candidate_sha" | tar -x -C "$candidate_runtime_dir"
set +e
(
  cd "$candidate_runtime_dir"
  bash ./scripts/check-mimi-protocol-contract.sh
) >"$runtime_contract_log" 2>&1
runtime_contract_status=$?
set -e

checks=()
failures=()

record_check() {
  local label="$1"
  local status="$2"
  local detail="$3"
  checks+=("| ${label} | ${status} | ${detail} |")
  [[ "$status" == "PASS" ]] || failures+=("$label")
}

if [[ "$contract_status" == "0" ]]; then
  record_check "MIM-28 N/N-1 协议窗口" "PASS" "双方最低修订可互连，四项 header map 固定，capability 未从上一窗口删除"
else
  detail="$(tr '\n' ' ' <"$contract_errors" | sed -E 's/[[:space:]]+/ /g')"
  record_check "MIM-28 N/N-1 协议窗口" "FAIL" "${detail:-协议 JSON 不满足兼容约束}"
fi

if [[ "$fixture_status" == "0" ]]; then
  record_check "MIM-30 capability fail-closed" "PASS" "当前状态/原因、未知能力和五组负向 fixture 均按语义求值；Go/iOS 生成常量对齐"
else
  detail="$(tr '\n' ' ' <"$fixture_errors" | sed -E 's/[[:space:]]+/ /g')"
  record_check "MIM-30 capability fail-closed" "FAIL" "${detail:-协议 fixture 或生成文件不满足失败关闭约束}"
fi

if [[ "$runtime_contract_status" == "0" ]]; then
  record_check "候选真实协议执行入口" "PASS" "candidate 干净归档已执行 scripts/check-mimi-protocol-contract.sh"
else
  detail="$(tr '\n' ' ' <"$runtime_contract_log" | sed -E 's/[[:space:]]+/ /g')"
  record_check "候选真实协议执行入口" "FAIL" "${detail:-真实协议检查执行失败}"
fi

required_release_paths=(
  .goreleaser.yml
  scripts/install-linux.sh
  scripts/build-macos-installer.sh
  scripts/build-windows-installer.ps1
  docs/install-upgrade-rollback.md
)
for ref_label in candidate previous; do
  ref_sha="$candidate_sha"
  [[ "$ref_label" == "candidate" ]] || ref_sha="$previous_sha"
  missing_paths=()
  for path in "${required_release_paths[@]}"; do
    git cat-file -e "${ref_sha}:${path}" 2>/dev/null || missing_paths+=("$path")
  done
  if [[ "${#missing_paths[@]}" == "0" ]]; then
    record_check "${ref_label} 可恢复发布源" "PASS" "GoReleaser、Mac/Windows 构建与 Linux rollback 入口完整"
  else
    record_check "${ref_label} 可恢复发布源" "FAIL" "缺少：${missing_paths[*]}"
  fi
done

if git grep -Fq "rollback" "$candidate_sha" -- scripts/install-linux.sh \
  && git grep -Fq "上一版" "$candidate_sha" -- docs/install-upgrade-rollback.md; then
  record_check "降级操作入口" "PASS" "Linux 可执行 rollback；Mac/Windows 明确使用上一签名正式产物"
else
  record_check "降级操作入口" "FAIL" "缺少可执行 rollback 或上一签名产物说明"
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$work_dir/rollback-readiness.md"
else
  mkdir -p "$(dirname "$OUTPUT_PATH")"
fi

{
  echo "# Mimi Release 回滚就绪报告"
  echo
  echo "- Candidate：\`${candidate_sha}\`（输入：\`${CANDIDATE_REF}\`）"
  echo "- Previous known-good：\`${previous_sha}\`（输入：\`${PREVIOUS_REF}\`）"
  echo "- 历史关系：previous 是 candidate 的祖先"
  echo "- Previous 协议证据：${previous_contract_source}"
  echo "- 执行边界：只读检查；未安装、未停止、未回滚、未发布任何真实服务"
  echo
  echo "## 协议窗口"
  echo
  cat "$contract_report"
  echo
  echo "## Fixture 与生成代码语义"
  echo
  cat "$fixture_report"
  echo
  echo "## 结果"
  echo
  echo "| 检查 | 状态 | 证据 |"
  echo "| --- | --- | --- |"
  printf '%s\n' "${checks[@]}"
  echo
  echo "## 发布结论"
  echo
  if [[ "${#failures[@]}" == "0" ]]; then
    echo "静态回滚检查与候选真实协议入口通过。此结果不等于已执行真实安装回滚；正式发布仍必须附上受保护 workflow 生成的上一签名产物恢复演练和 Internal TestFlight 证据。"
  else
    echo "FAIL-CLOSED：证据不足，禁止继续发布。失败项：${failures[*]}。"
  fi
} >"$OUTPUT_PATH"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$OUTPUT_PATH" >>"$GITHUB_STEP_SUMMARY"
fi

if [[ "${#failures[@]}" != "0" ]]; then
  echo "回滚就绪检查失败，报告：$OUTPUT_PATH" >&2
  exit 1
fi

echo "回滚就绪检查通过，报告：$OUTPUT_PATH"
