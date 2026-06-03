## 目标

记录 `adopt-codex-app-server-ios26` 在 iOS/iPadOS 26 客户端性能侧的最终验收结果，覆盖 XCTest、snapshot/UI、SwiftUI Instrument 可用性和当前环境限制。

## 自动化验证

- `xcodebuild test -project ios/CodexAgentPad/CodexAgentPad.xcodeproj -scheme CodexAgentPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=26.5'`
  - 结果：通过。
  - 覆盖：118 个 XCTest，包含数据流、WebSocket actor、日志窗口、diff 折叠、streaming assistant、主题切换、snapshot/UI。
- `openspec validate adopt-codex-app-server-ios26 --strict`
  - 结果：通过。
- `go test ./...`
  - 结果：通过。
- `go build -o /tmp/agentd-test ./cmd/agentd`
  - 结果：通过。

## SwiftUI Instrument 记录

- 已确认 `xcrun xctrace list templates` 存在 `SwiftUI` 模板。
- 模拟器执行：

```bash
xcrun xctrace record \
  --template 'SwiftUI' \
  --device F95781BB-4762-4C20-A608-0F1CE47E1BEB \
  --time-limit 5s \
  --output /tmp/codex-ipad-agent-instruments/CodexAgentPad-SwiftUI.trace \
  --launch -- /Users/gaixiaotongxue/Library/Developer/Xcode/DerivedData/CodexAgentPad-fjrmdsmecxmasfanmeuflnwluzeg/Build/Products/Debug-iphonesimulator/CodexAgentPad.app
```

结果：Xcode 返回 `SwiftUI instrument is not supported on the Simulator`，并保存 trace 包到 `/tmp/codex-ipad-agent-instruments/CodexAgentPad-SwiftUI.trace`。这说明 SwiftUI Instrument 不能用于当前 simulator 目标。

- 真机 all-processes 执行：

```bash
xcrun xctrace record \
  --template 'SwiftUI' \
  --device 00008103-000125C00ED3401E \
  --all-processes \
  --time-limit 5s \
  --output /tmp/codex-ipad-agent-instruments/Device-SwiftUI-AllProcesses.trace \
  --no-prompt
```

结果：命令成功退出并生成 `/tmp/codex-ipad-agent-instruments/Device-SwiftUI-AllProcesses.trace`。录制结束时设备报告过一次 disconnect，因此该 trace 只作为 SwiftUI Instrument 真机链路可用性证据。

## 当前限制

本项目当前没有配置 Apple development team，真机 app build 被 Xcode 签名拦截：

```text
Signing for "CodexAgentPad" requires a development team.
```

因此本轮无法完成“安装本 app 到真机并针对 app 进程录制 SwiftUI trace”的专项 profiling。MVP 验收采用自动化性能 XCTest + snapshot/UI + SwiftUI Instrument 可用性记录；进入 TestFlight/真机发布前，需要补一次带签名配置的 app-specific SwiftUI trace。

## 结论

当前重构的性能风险已经通过自动化测试覆盖主路径：输入不触发全局 Store、WebSocket/事件 reducer actor 化、assistant delta 节流、日志尾窗、diff 折叠、消息渲染缓存和主题切换不重建会话数据。SwiftUI Instrument 的工具链已验证可用，但 app-specific 真机 trace 受签名配置限制，作为发布前复核项保留。
