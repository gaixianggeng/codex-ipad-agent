#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  resolved_destination="$IOS_TEST_DESTINATION"
else
  # GitHub runner 和开发机安装的 Simulator 名称/OS 会变化。优先复用已启动设备，
  # 否则选择第一个可用 iPad/iPhone，避免把测试绑死到某个 beta runtime。
  simulator_id="$(xcrun simctl list devices available -j | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    candidates = devices.select { |item| item["isAvailable"] && item["name"].match?(/iPad|iPhone/) }
    chosen = candidates.find { |item| item["state"] == "Booted" } || candidates.first
    print chosen.fetch("udid", "") if chosen
  ')"
  if [[ -z "$simulator_id" ]]; then
    echo "没有可用的 iOS Simulator，请安装 iOS runtime 或设置 IOS_TEST_DESTINATION" >&2
    exit 1
  fi
  resolved_destination="platform=iOS Simulator,id=$simulator_id"
fi

echo "==> Go gateway conversation regressions"
if command -v go >/dev/null 2>&1; then
  go_bin="$(command -v go)"
elif [[ -x /usr/local/go/bin/go ]]; then
  # 从 Xcode/Codex 启动的非交互 shell 可能没有加载 /usr/local/go/bin。
  go_bin="/usr/local/go/bin/go"
else
  echo "未找到 Go，请安装 Go 或将 go 加入 PATH" >&2
  exit 1
fi
"$go_bin" test ./internal/httpapi

echo "==> iOS conversation regressions"
# 这些测试组覆盖 Mimi Remote 对话请求链路和发布安全边界：
# - AgentAPIClientRequestTests：全部 REST 调用的路径、方法、鉴权、JSON 字段和超时契约。
# - CodexAppServerProtocolTests：JSON-RPC payload、collaborationMode、目标/steer 协议。
# - ConversationDataFlowTests：Composer、SessionStore、direct app-server、断线/重试/滚动状态。
# - ConversationProcessGrouperTests：过程组边界、commentary 前后保留和 source order。
# - ConversationSnapshotTests：用户气泡/助手文档流、复杂 Markdown、图片和过程组的关键视觉回归。
# - MarkdownRenderingTests：proposed_plan 流式和完整渲染。
# - PairingLinkTests：Endpoint allowlist、ATS 对应的 HTTP/HTTPS 传输策略。
# - DoctorDiagnosticsTests：结构化 Doctor 响应、HTTP 错误和向后兼容。
xcodebuild test -quiet \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -destination "$resolved_destination" \
  -testLanguage zh-Hans \
  -testRegion CN \
  -only-testing:MimiRemoteTests/AgentAPIClientRequestTests \
  -only-testing:MimiRemoteTests/CodexAppServerProtocolTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests \
  -only-testing:MimiRemoteTests/ConversationProcessGrouperTests \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testConversationBubbleAlignment \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testDefaultDarkConversationPalette \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testRichMarkdownConversationRendering \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testMixedActivityAndImageConversationRendering \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testUnavailableUserImageGalleryRemainsLegibleInLightTheme \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testSessionRuntimeBadgesInConversationList \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testProjectSessionDashboard \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testCommentaryAndTrailingProcessRendering \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testExpandedProcessGroupRendering \
  -only-testing:MimiRemoteTests/MarkdownRenderingTests \
  -only-testing:MimiRemoteTests/PairingLinkTests \
  -only-testing:MimiRemoteTests/DoctorDiagnosticsTests
