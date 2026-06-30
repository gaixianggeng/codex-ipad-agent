#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_TEST_DESTINATION="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0}"

echo "==> Go gateway conversation regressions"
go test ./internal/httpapi

echo "==> iOS conversation regressions"
# 这三组覆盖 Mimi Remote 对话请求链路的核心回归面：
# - CodexAppServerProtocolTests：JSON-RPC payload、collaborationMode、目标/steer 协议。
# - ConversationDataFlowTests：Composer、SessionStore、direct app-server、断线/重试/滚动状态。
# - MarkdownRenderingTests：proposed_plan 流式和完整渲染。
xcodebuild test \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -destination "$IOS_TEST_DESTINATION" \
  -only-testing:MimiRemoteTests/CodexAppServerProtocolTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests \
  -only-testing:MimiRemoteTests/MarkdownRenderingTests
