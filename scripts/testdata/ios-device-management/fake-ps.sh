#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "-axo pid=,command=" ]]; then
  if [[ -n "${IOS_TEST_PS_OUTPUT_FILE:-}" && -f "$IOS_TEST_PS_OUTPUT_FILE" ]]; then
    /bin/cat "$IOS_TEST_PS_OUTPUT_FILE"
  fi
  exit 0
fi

exec /bin/ps "$@"
