#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Keep the English smoke test on the same destination and DerivedData as the core suite.
resolved_destination="$(bash "$ROOT_DIR/scripts/ios-dev.sh" prepare)"
derived_data_path="$(bash "$ROOT_DIR/scripts/ios-dev.sh" derived-data-path)"

echo "==> iOS English localization smoke"
xcodebuild test -quiet \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -configuration Debug \
  -destination "$resolved_destination" \
  -derivedDataPath "$derived_data_path" \
  -testLanguage en \
  -testRegion US \
  -only-testing:MimiRemoteTests/LocalizationTests
