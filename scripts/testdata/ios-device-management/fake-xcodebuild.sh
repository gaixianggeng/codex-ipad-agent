#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${IOS_TEST_XCODEBUILD_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$IOS_TEST_XCODEBUILD_LOG"
fi
if [[ -n "${IOS_TEST_XCODEBUILD_STARTED:-}" ]]; then
  printf '%s\n' "$$" > "$IOS_TEST_XCODEBUILD_STARTED"
fi
if [[ "${IOS_TEST_XCODEBUILD_SLEEP_SECONDS:-0}" != "0" ]]; then
  sleep "$IOS_TEST_XCODEBUILD_SLEEP_SECONDS"
fi
