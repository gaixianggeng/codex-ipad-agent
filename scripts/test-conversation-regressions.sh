#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 本地固定到项目默认 iPad；CI 在任务开始时只解析一次 UDID，再由两个测试脚本复用。
resolved_destination="$(bash "$ROOT_DIR/scripts/ios-dev.sh" prepare)"
derived_data_path="$(bash "$ROOT_DIR/scripts/ios-dev.sh" derived-data-path)"

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
# - CameraAttachmentTests：相机可用性、权限恢复和现有图片压缩上限。
# - CodexAppServerProtocolTests：JSON-RPC payload、collaborationMode、目标/steer 协议。
# - ConversationDataFlowTests：Composer、SessionStore、direct app-server、断线/重试/滚动状态。
# - FileAttachmentModelsTests：文件上传、内部上下文编解码和旧服务端能力兼容。
# - ConversationProcessGrouperTests：过程组边界、commentary 前后保留和 source order。
# - ConversationSnapshotTests：用户气泡/助手文档流、复杂 Markdown、图片和过程组的关键视觉回归。
# - MarkdownRenderingTests：proposed_plan 流式和完整渲染。
# - PairingLinkTests：Endpoint allowlist、ATS 对应的 HTTP/HTTPS 传输策略。
# - DoctorDiagnosticsTests：结构化 Doctor 响应、HTTP 错误和向后兼容。
# - ProtocolContractTests：iOS/agentd 当前、上一版和明确不兼容的版本窗口。
xcodebuild test -quiet \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -configuration Debug \
  -destination "$resolved_destination" \
  -derivedDataPath "$derived_data_path" \
  -testLanguage zh-Hans \
  -testRegion CN \
  -only-testing:MimiRemoteTests/AgentAPIClientRequestTests \
  -only-testing:MimiRemoteTests/CameraAttachmentTests \
  -only-testing:MimiRemoteTests/CodexAppServerProtocolTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests \
  -only-testing:MimiRemoteTests/ConversationProcessGrouperTests \
  -only-testing:MimiRemoteTests/FileAttachmentModelsTests \
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
  -only-testing:MimiRemoteTests/DoctorDiagnosticsTests \
  -only-testing:MimiRemoteTests/ProtocolContractTests
