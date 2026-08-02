#!/usr/bin/env bash
set -euo pipefail

RUN_ID=""
WORKFLOW_PATH=""
ARTIFACT_NAME=""
CANDIDATE_SHA=""
OUTPUT_DIR=""

fail() {
  echo "Release evidence 获取失败：$1" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --workflow-path) WORKFLOW_PATH="$2"; shift 2 ;;
    --artifact-name) ARTIFACT_NAME="$2"; shift 2 ;;
    --candidate-sha) CANDIDATE_SHA="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) fail "未知参数 $1" ;;
  esac
done

for command_name in find gh ruby unzip; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令 $command_name"
done
[[ -n "${GH_TOKEN:-}" ]] || fail "缺少只读 GH_TOKEN"
[[ "${GITHUB_REPOSITORY:-}" == "gaixianggeng/codex-ipad-agent" ]] || fail "只允许正式仓库"
[[ "$RUN_ID" =~ ^[1-9][0-9]*$ ]] || fail "run ID 必须是十进制正整数"
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "candidate SHA 必须为完整 40 位"
case "$WORKFLOW_PATH" in
  .github/workflows/ios-ci.yml|.github/workflows/release-rollback-drill.yml) ;;
  *) fail "workflow path 不在 evidence allowlist：$WORKFLOW_PATH" ;;
esac
[[ "$ARTIFACT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "artifact name 非法"
[[ -n "$OUTPUT_DIR" ]] || fail "缺少 output dir"
mkdir -p "$OUTPUT_DIR"
[[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || fail "output dir 必须为空：$OUTPUT_DIR"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

export RUN_ID ARTIFACT_NAME
run_json="$OUTPUT_DIR/run.json"
artifacts_json="$OUTPUT_DIR/artifacts.json"
archive="$OUTPUT_DIR/artifact.zip"
extracted="$OUTPUT_DIR/artifact"
source_json="$OUTPUT_DIR/source.json"

gh api "repos/$GITHUB_REPOSITORY/actions/runs/$RUN_ID" >"$run_json"
export EXPECTED_WORKFLOW_PATH="$WORKFLOW_PATH" EXPECTED_CANDIDATE_SHA="$CANDIDATE_SHA"
ruby -rjson -e '
  run = JSON.parse(File.read(ARGV.fetch(0)))
  expected = {
    "event" => "workflow_dispatch",
    "status" => "completed",
    "conclusion" => "success",
    "head_branch" => "main",
    "head_sha" => ENV.fetch("EXPECTED_CANDIDATE_SHA"),
    "path" => ENV.fetch("EXPECTED_WORKFLOW_PATH")
  }
  expected.each { |key, value| abort "run #{key} mismatch" unless run[key] == value }
  abort "repository mismatch" unless run.dig("repository", "full_name") == ENV.fetch("GITHUB_REPOSITORY")
  abort "run id mismatch" unless run.fetch("id").to_s == ENV.fetch("RUN_ID")
' "$run_json"

gh api \
  "repos/$GITHUB_REPOSITORY/actions/runs/$RUN_ID/artifacts?name=$ARTIFACT_NAME&per_page=100" \
  >"$artifacts_json"
export EXPECTED_ARTIFACT_NAME="$ARTIFACT_NAME"
read -r artifact_id artifact_digest artifact_created_at < <(ruby -rjson -e '
  artifacts = JSON.parse(File.read(ARGV.fetch(0))).fetch("artifacts")
  matches = artifacts.select { |item| item["name"] == ENV.fetch("EXPECTED_ARTIFACT_NAME") && item["expired"] == false }
  abort "expected exactly one unexpired artifact, found #{matches.length}" unless matches.length == 1
  artifact = matches.first
  digest = artifact["digest"]
  abort "artifact digest missing" unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)
  puts [artifact.fetch("id"), digest, artifact.fetch("created_at")].join(" ")
' "$artifacts_json")
[[ "$artifact_id" =~ ^[1-9][0-9]*$ ]]

gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$artifact_id/zip" >"$archive"
actual_digest="sha256:$(sha256_file "$archive")"
[[ "$actual_digest" == "$artifact_digest" ]] \
  || fail "artifact ZIP digest 不匹配：expected=$artifact_digest actual=$actual_digest"
mkdir -p "$extracted"
unzip -q "$archive" -d "$extracted"
evidence_files=()
while IFS= read -r evidence_file; do
  evidence_files+=("$evidence_file")
done < <(find "$extracted" -name '*.json' -type f -print)
[[ "${#evidence_files[@]}" == "1" ]] \
  || fail "evidence artifact 必须恰好包含一个 JSON，实际 ${#evidence_files[@]}"

export ARTIFACT_ID="$artifact_id" ARTIFACT_DIGEST="$artifact_digest"
export ARTIFACT_CREATED_AT="$artifact_created_at" ARTIFACT_NAME
ruby -rjson -e '
  run = JSON.parse(File.read(ARGV.fetch(0)))
  source = {
    "schema_version" => 1,
    "repository" => run.dig("repository", "full_name"),
    "workflow_path" => run.fetch("path"),
    "run_id" => run.fetch("id").to_s,
    "run_attempt" => run.fetch("run_attempt"),
    "event" => run.fetch("event"),
    "head_branch" => run.fetch("head_branch"),
    "head_sha" => run.fetch("head_sha"),
    "conclusion" => run.fetch("conclusion"),
    "artifact_id" => Integer(ENV.fetch("ARTIFACT_ID"), 10),
    "artifact_name" => ENV.fetch("ARTIFACT_NAME"),
    "artifact_digest" => ENV.fetch("ARTIFACT_DIGEST"),
    "artifact_created_at" => ENV.fetch("ARTIFACT_CREATED_AT")
  }
  File.write(ARGV.fetch(1), JSON.generate(source) + "\n", mode: "w", perm: 0o600)
' "$run_json" "$source_json"

printf '%s\n' "${evidence_files[0]}"
