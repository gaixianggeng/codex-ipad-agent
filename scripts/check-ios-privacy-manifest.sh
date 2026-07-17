#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/ios/MimiRemote/Resources/PrivacyInfo.xcprivacy"
PROJECT="$ROOT_DIR/ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj"
SPEC="$ROOT_DIR/ios/MimiRemote/project.yml"

if ! command -v plutil >/dev/null 2>&1; then
  echo "隐私清单门禁失败：当前环境缺少 plutil。" >&2
  exit 127
fi

plutil -lint "$MANIFEST" >/dev/null

expect_raw() {
  local key_path="$1"
  local expected="$2"
  local actual
  actual="$(plutil -extract "$key_path" raw -o - "$MANIFEST")"
  if [[ "$actual" != "$expected" ]]; then
    echo "隐私清单门禁失败：$key_path = ${actual}，期望 ${expected}。" >&2
    exit 1
  fi
}

expect_raw "NSPrivacyTracking" "false"
expect_raw "NSPrivacyTrackingDomains" "0"
expect_raw "NSPrivacyCollectedDataTypes" "0"
expect_raw "NSPrivacyAccessedAPITypes" "1"
expect_raw "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategoryUserDefaults"
expect_raw "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons" "1"
expect_raw "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0" "CA92.1"

grep -Fq "PrivacyInfo.xcprivacy in Resources" "$PROJECT" || {
  echo "隐私清单门禁失败：Xcode App target 未打包 PrivacyInfo.xcprivacy。" >&2
  exit 1
}

grep -Fq "Resources/PrivacyInfo.xcprivacy" "$SPEC" || {
  echo "隐私清单门禁失败：project.yml 未声明 PrivacyInfo.xcprivacy，重新生成工程后会丢失。" >&2
  exit 1
}

echo "iOS 隐私清单门禁通过。"
