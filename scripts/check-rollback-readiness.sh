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

for command_name in cat git grep mkdir mktemp ruby sed tr; do
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

git show "${candidate_sha}:contracts/mimi-protocol/contract.json" >"$candidate_contract" \
  || fail "candidate 缺少 Mimi 协议契约。"
previous_contract_source="previous commit contract.json"
if ! git show "${previous_sha}:contracts/mimi-protocol/contract.json" >"$previous_contract" 2>/dev/null; then
  # 第一次引入正式协议 manifest 时，上一正式版本没有 contract.json。
  # 只能使用 MIM-28 中由两端共同消费的 revision-1 fixture 作为 legacy 基线；
  # fixture 缺失或已经带入新字段时失败关闭，不能凭版本字符串猜测。
  previous_fixture="$work_dir/version-previous.json"
  git show "${candidate_sha}:contracts/mimi-protocol/fixtures/version-previous.json" >"$previous_fixture" \
    || fail "previous 没有协议 manifest，candidate 也缺少 revision-1 fixture。"
  ruby -rjson - "$candidate_contract" "$previous_fixture" >"$previous_contract" <<'RUBY'
candidate_path, fixture_path = ARGV
candidate = JSON.parse(File.read(candidate_path))
fixture = JSON.parse(File.read(fixture_path))
abort("legacy fixture 必须是 JSON object") unless fixture.is_a?(Hash)
forbidden = %w[protocol_revision minimum_client_protocol_revision minimum_server_protocol_revision]
abort("legacy fixture 意外包含新协议字段") unless forbidden.none? { |key| fixture.key?(key) }
legacy_client = candidate["legacy_client_revision"]
legacy_server = candidate["legacy_server_revision"]
abort("candidate 缺少 legacy revision") unless
  legacy_client.is_a?(Integer) && legacy_client.positive? &&
  legacy_server.is_a?(Integer) && legacy_server.positive?
puts JSON.pretty_generate(
  "schema_version" => candidate["schema_version"],
  "protocol_name" => candidate["protocol_name"],
  "current_revision" => legacy_server,
  "minimum_supported_client_revision" => legacy_client,
  "minimum_supported_server_revision" => legacy_server,
  "capabilities" => []
)
RUBY
  previous_contract_source="candidate revision-1 golden fixture（previous 无 manifest）"
fi

set +e
ruby -rjson - "$candidate_contract" "$previous_contract" >"$contract_report" 2>"$contract_errors" <<'RUBY'
candidate_path, previous_path = ARGV
candidate = JSON.parse(File.read(candidate_path))
previous = JSON.parse(File.read(previous_path))
errors = []

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
end

if errors.empty?
  errors << "schema_version 改变，缺少显式迁移证据" unless candidate["schema_version"] == previous["schema_version"]
  errors << "protocol_name 改变，不能视为同一兼容窗口" unless candidate["protocol_name"] == previous["protocol_name"]
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

  removed = previous.fetch("capabilities", []) - candidate.fetch("capabilities", [])
  errors << "candidate 删除了上一窗口 capability：#{removed.join(', ')}" unless removed.empty?
end

puts "| 项目 | 上一已知版本 | 当前候选 |"
puts "| --- | --- | --- |"
puts "| protocol revision | `#{previous["current_revision"]}` | `#{candidate["current_revision"]}` |"
puts "| minimum client revision | `#{previous["minimum_supported_client_revision"]}` | `#{candidate["minimum_supported_client_revision"]}` |"
puts "| minimum server revision | `#{previous["minimum_supported_server_revision"]}` | `#{candidate["minimum_supported_server_revision"]}` |"
puts "| capabilities | `#{previous.fetch("capabilities", []).join(", ")}` | `#{candidate.fetch("capabilities", []).join(", ")}` |"

unless errors.empty?
  warn errors.map { |item| "- #{item}" }.join("\n")
  exit 1
end
RUBY
contract_status=$?
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
  record_check "MIM-28 N/N-1 协议窗口" "PASS" "双方最低修订可互连，capability 未从上一窗口删除"
else
  detail="$(tr '\n' ' ' <"$contract_errors" | sed -E 's/[[:space:]]+/ /g')"
  record_check "MIM-28 N/N-1 协议窗口" "FAIL" "${detail:-协议 JSON 不满足兼容约束}"
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

if git grep -Fq "file_upload_v1" "$candidate_sha" -- contracts/mimi-protocol/contract.json \
  && git grep -Fq "capabilities.disabled" "$candidate_sha" -- docs/capability-rollout.md \
  && git grep -Fq "TestFileUploadCapabilityRolloutMatrix" "$candidate_sha" -- internal/httpapi \
  && git grep -Fq "testFileUploadCapabilityDecisionMatrixFailsClosed" "$candidate_sha" -- ios/MimiRemote/Tests; then
  record_check "MIM-30 capability kill switch" "PASS" "配置禁用、服务端拒绝、iOS fail-closed 与回归证据齐全"
else
  record_check "MIM-30 capability kill switch" "FAIL" "缺少 file_upload_v1 禁用、服务端或 iOS fail-closed 证据"
fi

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
  echo "## 结果"
  echo
  echo "| 检查 | 状态 | 证据 |"
  echo "| --- | --- | --- |"
  printf '%s\n' "${checks[@]}"
  echo
  echo "## 发布结论"
  echo
  if [[ "${#failures[@]}" == "0" ]]; then
    echo "静态回滚检查通过。此结果不等于已执行真实安装回滚；正式发布仍必须附上一签名产物恢复演练和 Internal TestFlight 证据。"
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
