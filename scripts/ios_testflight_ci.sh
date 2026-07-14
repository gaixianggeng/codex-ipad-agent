#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/MimiRemote/MimiRemote.xcodeproj"
SCHEME="MimiRemote"
IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-com.gaixianggeng.mimi}"
IOS_TESTFLIGHT_UPLOAD="${IOS_TESTFLIGHT_UPLOAD:-1}"
IOS_TESTFLIGHT_VALIDATE="${IOS_TESTFLIGHT_VALIDATE:-0}"
TESTFLIGHT_WHATS_NEW="${TESTFLIGHT_WHATS_NEW:-}"

fail() {
  echo "ios-testflight-ci: $1" >&2
  exit 1
}

require_env() {
  [[ -n "${!1:-}" ]] || fail "$1 is required"
}

for command in git ruby bash xcodebuild xcrun plutil find; do
  command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done
for key in RUNNER_TEMP DEVELOPMENT_TEAM APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH IOS_SIGNING_KEYCHAIN_PATH IOS_CODE_SIGN_IDENTITY IOS_PROVISIONING_PROFILE_SPECIFIER; do
  require_env "$key"
done
case "$IOS_TESTFLIGHT_UPLOAD:$IOS_TESTFLIGHT_VALIDATE" in
  1:0|0:1) ;;
  *) fail "choose exactly one mode: upload or validate" ;;
esac
if [[ "$IOS_TESTFLIGHT_UPLOAD" == "1" ]]; then
  require_env TESTFLIGHT_BETA_GROUP_ID
  [[ -n "$TESTFLIGHT_WHATS_NEW" ]] || fail "TESTFLIGHT_WHATS_NEW is required"
fi
[[ -f "$PROJECT/project.pbxproj" ]] || fail "Xcode project not found: $PROJECT"
[[ -f "$ROOT_DIR/scripts/ios_asc_build_number_preflight.rb" ]] || fail "missing build-number preflight"
[[ -f "$ROOT_DIR/scripts/distribute_internal_build.rb" ]] || fail "missing distribution script"

# 本地执行器会提供干净 worktree；入口再检查一次，避免发布时混入临时改动。
git -C "$ROOT_DIR" diff --quiet
git -C "$ROOT_DIR" diff --cached --quiet
bash "$ROOT_DIR/scripts/check-ios-privacy-manifest.sh"

settings="$(
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -showBuildSettings
)"
marketing_version="$(printf '%s\n' "$settings" | awk -F= '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
current_build="$(printf '%s\n' "$settings" | awk -F= '/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
[[ -n "$marketing_version" ]] || fail "MARKETING_VERSION not found"
[[ "$current_build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION must be an integer"

# 构建前先问 ASC，避免沿用 GitHub run number 号段或归档后才发现重复号。
preflight="$(
  ruby "$ROOT_DIR/scripts/ios_asc_build_number_preflight.rb" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --version "$marketing_version" \
    --build "$current_build"
)"
printf '%s\n' "$preflight"
build_number="$(printf '%s\n' "$preflight" | awk -F= '/^ASC_SUGGESTED_BUILD_NUMBER=/{print $2; exit}')"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "suggested build number must be an integer"

output="$RUNNER_TEMP/mimi-testflight/$marketing_version-$build_number"
archive="$output/MimiRemote.xcarchive"
export_path="$output/export"
export_options="$output/ExportOptions.plist"
rm -rf "$output"
mkdir -p "$output"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>provisioningProfiles</key>
  <dict><key>$IOS_BUNDLE_ID</key><string>$IOS_PROVISIONING_PROFILE_SPECIFIER</string></dict>
</dict>
</plist>
PLIST

echo "ios-testflight-ci: archive $IOS_BUNDLE_ID $marketing_version ($build_number)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$IOS_BUNDLE_ID" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IOS_CODE_SIGN_IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$IOS_PROVISIONING_PROFILE_SPECIFIER" \
  OTHER_CODE_SIGN_FLAGS="--keychain $IOS_SIGNING_KEYCHAIN_PATH" \
  -quiet

archive_info="$archive/Products/Applications/MimiRemote.app/Info.plist"
[[ -f "$archive_info" ]] || fail "archive app Info.plist not found"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$archive_info")" == "$IOS_BUNDLE_ID" ]] || fail "archive bundle id mismatch"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$archive_info")" == "$marketing_version" ]] || fail "archive version mismatch"
[[ "$(plutil -extract CFBundleVersion raw -o - "$archive_info")" == "$build_number" ]] || fail "archive build mismatch"
[[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$archive_info")" == "false" ]] || fail "encryption declaration must be false"
echo "ios-testflight-ci: archive toolchain DTXcodeBuild=$(plutil -extract DTXcodeBuild raw -o - "$archive_info") DTSDKName=$(plutil -extract DTSDKName raw -o - "$archive_info")"

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  -quiet

ipa_candidates=()
while IFS= read -r ipa; do
  ipa_candidates+=("$ipa")
done < <(find "$export_path" -maxdepth 1 -name '*.ipa' -type f -print)
[[ "${#ipa_candidates[@]}" == "1" ]] || fail "expected exactly one IPA"
ipa="${ipa_candidates[0]}"

# 上传前再次检查远端 build，发现竞争发布就停止并要求重新归档。
final_preflight="$(
  ruby "$ROOT_DIR/scripts/ios_asc_build_number_preflight.rb" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --version "$marketing_version" \
    --build "$build_number"
)"
final_suggested="$(printf '%s\n' "$final_preflight" | awk -F= '/^ASC_SUGGESTED_BUILD_NUMBER=/{print $2; exit}')"
[[ "$final_suggested" == "$build_number" ]] || fail "remote build number changed during archive; rebuild with $final_suggested"

if [[ "$IOS_TESTFLIGHT_VALIDATE" == "1" ]]; then
  echo "ios-testflight-ci: validate $IOS_BUNDLE_ID $marketing_version ($build_number)"
  xcrun altool --validate-app \
    --file "$ipa" \
    --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
    --p8-file-path "$APP_STORE_CONNECT_API_KEY_PATH"
else
  echo "ios-testflight-ci: upload $IOS_BUNDLE_ID $marketing_version ($build_number)"
  xcrun altool --upload-app \
    --file "$ipa" \
    --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
    --p8-file-path "$APP_STORE_CONNECT_API_KEY_PATH"
  IOS_BUNDLE_ID="$IOS_BUNDLE_ID" \
  TESTFLIGHT_BETA_GROUP_ID="$TESTFLIGHT_BETA_GROUP_ID" \
  TESTFLIGHT_WHATS_NEW="$TESTFLIGHT_WHATS_NEW" \
    ruby "$ROOT_DIR/scripts/distribute_internal_build.rb" "$ipa"
fi

echo "ios-testflight-ci ok: mode=$([[ "$IOS_TESTFLIGHT_UPLOAD" == "1" ]] && printf upload || printf validate) version=$marketing_version build=$build_number ipa=$ipa"
