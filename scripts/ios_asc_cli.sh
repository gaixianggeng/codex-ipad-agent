#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PIN_CONFIG="${ASC_CLI_PIN_CONFIG:-$ROOT_DIR/config/release/ios-asc-cli.env}"

fail() {
  echo "ios-asc-cli: $1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ios_asc_cli.sh install [--destination PATH]
  ios_asc_cli.sh check [--binary PATH]
  ios_asc_cli.sh next-build-number --bundle-id ID --version VERSION --build BUILD [--binary PATH]

Commands:
  install            下载固定版本到 PATH；已存在不同文件时拒绝覆盖
  check              离线校验版本、SHA-256 和 Developer ID 签名
  next-build-number  只读查询已处理构建和进行中的上传，并输出影子建议

Environment:
  ASC_CLI_BIN         check/query 使用的 asc 路径；默认从 PATH 查找
  ASC_CLI_PIN_CONFIG  仅供离线测试覆盖固定版本配置
USAGE
}

[[ -f "$PIN_CONFIG" ]] || fail "pin config not found: $PIN_CONFIG"
# shellcheck disable=SC1090
source "$PIN_CONFIG"

for name in \
  ASC_CLI_VERSION \
  ASC_CLI_RELEASE_BASE_URL \
  ASC_CLI_MACOS_ARM64_ASSET \
  ASC_CLI_MACOS_ARM64_SHA256 \
  ASC_CLI_MACOS_AMD64_ASSET \
  ASC_CLI_MACOS_AMD64_SHA256 \
  ASC_CLI_SIGNING_TEAM_ID; do
  [[ -n "${!name:-}" ]] || fail "$name is required in $PIN_CONFIG"
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi
  fail "missing sha256sum or shasum"
}

asset_for_host() {
  local system
  local machine
  system="$(uname -s)"
  [[ "$system" == "Darwin" ]] || fail "unsupported operating system: $system"
  machine="$(uname -m)"
  case "$machine" in
    arm64|aarch64)
      printf '%s\t%s\n' "$ASC_CLI_MACOS_ARM64_ASSET" "$ASC_CLI_MACOS_ARM64_SHA256"
      ;;
    x86_64|amd64)
      printf '%s\t%s\n' "$ASC_CLI_MACOS_AMD64_ASSET" "$ASC_CLI_MACOS_AMD64_SHA256"
      ;;
    *)
      fail "unsupported macOS architecture: $machine"
      ;;
  esac
}

resolve_binary() {
  local requested="${1:-${ASC_CLI_BIN:-}}"
  local resolved
  if [[ -n "$requested" ]]; then
    if [[ "$requested" == */* ]]; then
      resolved="$requested"
    else
      resolved="$(command -v "$requested" 2>/dev/null || true)"
    fi
  else
    resolved="$(command -v asc 2>/dev/null || true)"
  fi
  [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]] \
    || fail "asc binary not found; run: bash ./scripts/ios_asc_cli.sh install"
  printf '%s\n' "$resolved"
}

verify_binary() {
  local binary="$1"
  local asset_name
  local expected_checksum
  local actual_checksum
  local signature_details
  local signing_team
  local version_output
  local actual_version

  require_command awk
  require_command codesign
  read -r asset_name expected_checksum < <(asset_for_host)
  actual_checksum="$(sha256_file "$binary")"
  [[ "$actual_checksum" == "$expected_checksum" ]] \
    || fail "SHA-256 mismatch for $binary: expected=$expected_checksum actual=$actual_checksum"

  # SHA 固定文件内容，Developer ID 再固定发布者身份；当前 3.4.1 未 notarize，
  # 因此不把会拒绝该产物的 spctl 当成通过条件。
  codesign --verify --strict --verbose=2 "$binary" >/dev/null 2>&1 \
    || fail "invalid Developer ID signature: $binary"
  signature_details="$(codesign -dv --verbose=4 "$binary" 2>&1)"
  signing_team="$(printf '%s\n' "$signature_details" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  [[ "$signing_team" == "$ASC_CLI_SIGNING_TEAM_ID" ]] \
    || fail "unexpected Developer ID team: expected=$ASC_CLI_SIGNING_TEAM_ID actual=${signing_team:-missing}"

  version_output="$("$binary" version)"
  actual_version="${version_output%% *}"
  [[ "$actual_version" == "$ASC_CLI_VERSION" ]] \
    || fail "version mismatch: expected=$ASC_CLI_VERSION actual=${actual_version:-missing}"

  printf 'ASC_CLI_CHECK=ok\n'
  printf 'ASC_CLI_VERSION=%s\n' "$actual_version"
  printf 'ASC_CLI_ASSET=%s\n' "$asset_name"
  printf 'ASC_CLI_SHA256=%s\n' "$actual_checksum"
  printf 'ASC_CLI_SIGNING_TEAM_ID=%s\n' "$signing_team"
}

install_binary() {
  local destination="$1"
  local asset_name
  local expected_checksum
  local destination_dir
  local temp_base
  local install_dir
  local downloaded_binary

  if [[ -e "$destination" ]]; then
    [[ -f "$destination" && -x "$destination" ]] \
      || fail "install destination exists but is not an executable file: $destination"
    verify_binary "$destination"
    echo "ios-asc-cli install ok: pinned binary already exists at $destination"
    return
  fi

  for command_name in curl install mkdir mktemp rm; do
    require_command "$command_name"
  done
  read -r asset_name expected_checksum < <(asset_for_host)
  destination_dir="$(dirname "$destination")"
  mkdir -p "$destination_dir"
  temp_base="${TMPDIR:-/tmp}"
  temp_base="${temp_base%/}"
  install_dir="$(mktemp -d "$temp_base/mimi-asc-install.XXXXXX")"
  downloaded_binary="$install_dir/$asset_name"
  cleanup_install() {
    rm -rf "$install_dir"
  }
  trap cleanup_install EXIT INT TERM

  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "$ASC_CLI_RELEASE_BASE_URL/$ASC_CLI_VERSION/$asset_name" \
    --output "$downloaded_binary"
  [[ "$(sha256_file "$downloaded_binary")" == "$expected_checksum" ]] \
    || fail "downloaded SHA-256 mismatch: $asset_name"
  chmod 700 "$downloaded_binary"
  verify_binary "$downloaded_binary"
  install -m 0755 "$downloaded_binary" "$destination"
  verify_binary "$destination"

  cleanup_install
  trap - EXIT INT TERM
  echo "ios-asc-cli install ok: $destination"
}

query_next_build_number() {
  local binary="$1"
  local bundle_id="$2"
  local short_version="$3"
  local current_build="$4"
  local asc_json
  local parsed
  local next_build
  local suggested_build

  [[ "$current_build" =~ ^[0-9]+$ ]] || fail "build must be an integer"
  for name in APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH; do
    [[ -n "${!name:-}" ]] || fail "$name is required"
  done
  [[ -f "$APP_STORE_CONNECT_API_KEY_PATH" ]] \
    || fail "APP_STORE_CONNECT_API_KEY_PATH not found: $APP_STORE_CONNECT_API_KEY_PATH"
  [[ ! -e "$ROOT_DIR/.asc/config.json" ]] \
    || fail "repo-local .asc/config.json is forbidden; use repository-external secrets"
  require_command ruby
  verify_binary "$binary"

  # 凭据只映射到单次只读命令；禁用遥测和 Keychain，并用 strict auth
  # 阻止本机 profile 与仓库外 Secrets 被意外混用。
  asc_json="$({
    cd "$ROOT_DIR"
    env \
      ASC_TELEMETRY_DISABLED=1 \
      ASC_BYPASS_KEYCHAIN=1 \
      ASC_STRICT_AUTH=1 \
      ASC_KEY_ID="$APP_STORE_CONNECT_API_KEY_ID" \
      ASC_ISSUER_ID="$APP_STORE_CONNECT_API_ISSUER_ID" \
      ASC_PRIVATE_KEY_PATH="$APP_STORE_CONNECT_API_KEY_PATH" \
      ASC_PRIVATE_KEY= \
      ASC_PRIVATE_KEY_B64= \
      "$binary" builds next-build-number \
        --app "$bundle_id" \
        --version "$short_version" \
        --platform IOS \
        --output json
  })"

  parsed="$(printf '%s' "$asc_json" | ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    next_build = data.fetch("nextBuildNumber").to_s
    abort("nextBuildNumber must be an integer") unless next_build.match?(/\A\d+\z/)
    processed = data["latestProcessedBuildNumber"].to_s
    upload = data["latestUploadBuildNumber"].to_s
    observed = data["latestObservedBuildNumber"].to_s
    sources = Array(data["sourcesConsidered"]).join(",")
    puts "ASC_CLI_LATEST_PROCESSED_BUILD_NUMBER=#{processed}"
    puts "ASC_CLI_LATEST_UPLOAD_BUILD_NUMBER=#{upload}"
    puts "ASC_CLI_LATEST_OBSERVED_BUILD_NUMBER=#{observed}"
    puts "ASC_CLI_NEXT_BUILD_NUMBER=#{next_build}"
    puts "ASC_CLI_SOURCES_CONSIDERED=#{sources}"
  ')" || fail "invalid asc next-build-number JSON"
  next_build="$(printf '%s\n' "$parsed" | awk -F= '/^ASC_CLI_NEXT_BUILD_NUMBER=/{print $2; exit}')"
  [[ "$next_build" =~ ^[0-9]+$ ]] || fail "asc next build number must be an integer"
  suggested_build="$(ruby -e 'puts ARGV.map { |value| Integer(value, 10) }.max' "$current_build" "$next_build")"

  printf '%s\n' "$parsed"
  printf 'ASC_CLI_CURRENT_BUILD=%s\n' "$current_build"
  printf 'ASC_CLI_SUGGESTED_BUILD_NUMBER=%s\n' "$suggested_build"
}

main() {
  local command_name="${1:-}"
  local requested_binary=""
  local destination="${ASC_CLI_INSTALL_PATH:-$HOME/.local/bin/asc}"
  local bundle_id=""
  local short_version=""
  local current_build=""

  [[ -n "$command_name" ]] || { usage >&2; exit 2; }
  shift
  case "$command_name" in
    install)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --destination)
            [[ $# -ge 2 ]] || fail "--destination requires a value"
            destination="$2"
            shift 2
            ;;
          -h|--help)
            usage
            return
            ;;
          *)
            fail "unknown install argument: $1"
            ;;
        esac
      done
      install_binary "$destination"
      ;;
    check)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --binary)
            [[ $# -ge 2 ]] || fail "--binary requires a value"
            requested_binary="$2"
            shift 2
            ;;
          -h|--help)
            usage
            return
            ;;
          *)
            fail "unknown check argument: $1"
            ;;
        esac
      done
      verify_binary "$(resolve_binary "$requested_binary")"
      ;;
    next-build-number)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --binary)
            [[ $# -ge 2 ]] || fail "--binary requires a value"
            requested_binary="$2"
            shift 2
            ;;
          --bundle-id)
            [[ $# -ge 2 ]] || fail "--bundle-id requires a value"
            bundle_id="$2"
            shift 2
            ;;
          --version)
            [[ $# -ge 2 ]] || fail "--version requires a value"
            short_version="$2"
            shift 2
            ;;
          --build)
            [[ $# -ge 2 ]] || fail "--build requires a value"
            current_build="$2"
            shift 2
            ;;
          -h|--help)
            usage
            return
            ;;
          *)
            fail "unknown next-build-number argument: $1"
            ;;
        esac
      done
      [[ -n "$bundle_id" ]] || fail "--bundle-id is required"
      [[ -n "$short_version" ]] || fail "--version is required"
      [[ -n "$current_build" ]] || fail "--build is required"
      query_next_build_number \
        "$(resolve_binary "$requested_binary")" \
        "$bundle_id" \
        "$short_version" \
        "$current_build"
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
