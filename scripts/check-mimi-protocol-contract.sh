#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v go >/dev/null 2>&1; then
  echo "Mimi 协议检查失败：未找到 Go。" >&2
  exit 1
fi

go run ./internal/protocolcontract/cmd/generate --check
go test ./internal/httpapi \
  -run 'Test(VersionResponseMatchesSharedCurrentGoldenFixture|CurrentAgentDRemainsDecodableByPreviousClient|ClientCompatibilityMatrixAgainstCurrentAgentD|WebSocketHandshakeRejectsIncompatibleClientBeforeUpgrade|ProtocolMetadataDoesNotBypassAuthentication)$' \
  -count=1

echo "Mimi iOS/agentd 版本化契约检查通过。"
