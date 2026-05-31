# Litter iOS Reference

## 目标

把 Litter iOS 里体验好的部分转化为本项目的参考清单。只借鉴交互模式、页面组织和性能策略，不复制源码、资源、品牌，不引入 Android、Rust/UniFFI、Watch、CarPlay、语音、宠物、小游戏等非 MVP 范围。

参考来源：

- GitHub: https://github.com/dnakov/litter
- README 描述：Native iOS + Android client for Codex，平台 UI 较薄，session state、streaming、hydration 等在共享 Rust core。
- App Store 描述：支持连接本地/远程 Codex server、管理会话、查看 history/reasoning/code blocks/images 的 mobile-native UI。

## 借鉴点

### 1. Home / Sessions

参考文件：

- `apps/ios/Sources/Litter/Views/HomeDashboardView.swift`
- `apps/ios/Sources/Litter/Views/SessionsScreen.swift`
- `apps/ios/Sources/Litter/Views/HomeSessionsScrollView.swift`

可借鉴：

- 首屏是工作台，不是空白列表。
- 最近会话有预览、状态、更新时间和快速操作。
- 会话列表支持搜索/过滤/刷新。
- active turn 和 pending 状态在 row 上可见。

不借鉴：

- UIKit-backed pinch zoom 会话列表作为 MVP 功能。
- 多 server、多 runtime、多 provider 入口。

### 2. Conversation

参考文件：

- `apps/ios/Sources/Litter/Views/ConversationView.swift`
- `apps/ios/Sources/Litter/Views/ConversationScreenModel.swift`
- `apps/ios/Sources/Litter/Views/ConversationTimelineView.swift`
- `apps/ios/Sources/Litter/Views/MessageBubbleView.swift`

可借鉴：

- `ConversationScreenModel` 先把 runtime state 投影成 snapshot，View 不直接消费完整模型。
- timeline row 用稳定 id、render digest、Equatable row 降低重绘。
- 用户气泡、assistant 气泡、runtime detail card 分层展示。
- reasoning、command、tool、file change 默认摘要化，不让聊天主线变成日志。

不借鉴：

- 过多 agent/provider 类型。
- widget、小游戏、语音相关 row。

### 3. Composer

参考文件：

- `apps/ios/Sources/Litter/Views/ConversationComposerContentView.swift`
- `apps/ios/Sources/Litter/Views/ConversationComposerEntryRowView.swift`

可借鉴：

- bottom safe-area composer。
- send/stop 状态明确。
- 长 prompt 可展开。
- approval、task、rate limit、context 这类辅助状态放在 composer 上方。

MVP 简化：

- 先做文本输入、send、stop、approval/cost/context chips。
- attach、voice、plugin mention 后置。

### 4. Streaming Render Performance

参考文件：

- `apps/ios/Sources/Litter/Views/MessageRenderCache.swift`
- `apps/ios/Sources/Litter/Views/StreamingAssistantRenderCache.swift`
- `apps/ios/Tests/LitterTests/StreamingAssistantRenderCacheTests.swift`

可借鉴：

- Markdown/代码块解析按 message revision 缓存。
- append-only streaming 复用稳定前缀，只重算尾部。
- cache 有上限和 trim target。

### 5. Theme / Appearance

参考文件：

- `apps/ios/Sources/Litter/Models/ThemeManager.swift`
- `apps/ios/Sources/Litter/Models/ThemeDefinition.swift`
- `apps/ios/Sources/Litter/Models/LitterPalette.swift`
- `apps/ios/Sources/Litter/Views/AppearanceSettingsView.swift`

可借鉴：

- Appearance 页面包含 mode、字体大小、conversation preview、theme picker。
- 主题通过 semantic token 输出给 UI。
- `themeVersion` 只驱动样式刷新，不改 message/session 数据。
- theme manifest + preview badge 的选择体验很好。

MVP 简化：

- 内置少量主题，不一次性引入大量 VS Code 主题。
- 不做复杂 wallpaper/video wallpaper。

## 我们自己的落地原则

- Codex-only。
- iOS/iPadOS-only。
- Go `agentd` 仍是稳定网关。
- Swift UI 层保持轻量。
- 所有高频数据先经过 reducer/snapshot，再进入 View。
- 视觉体验参考 Litter 的“移动原生 + coding-agent 信息密度”，但不照搬它的多平台/多 provider 架构。
