## Why

iPad 客户端当前已有外观设置雏形，但主题状态只在设置页局部生效，主工作台仍大量依赖系统默认颜色和字体，用户无法稳定切换浅色、深色、主题预设和字体偏好。

这次变更先做一个小而完整的 MVP，让 iOS 客户端具备可持久化、可实时生效的外观自定义能力，优先覆盖聊天、输入、侧栏、日志和 Inspector 等高频工作流。

## What Changes

- 新增 App 级 `ThemeStore` 注入，外观模式、主题预设和字体设置在全局共享并持久化。
- 支持外观模式：跟随系统、浅色、深色。
- 支持少量主题预设：Codex、Xcode、Gruvbox，后续可渐进增加。
- 支持字体设置：UI 字体、代码字体、字体缩放。
- 设置页外观面板改为面向 iPad 的完整控制面板，并保留聊天/代码预览。
- 主工作台核心视图改为读取主题 token，覆盖侧栏、会话列表、聊天时间线、输入框、日志和 Inspector 常见卡片。
- 新增主题状态单元测试，验证默认值、持久化、非法值回退和字体缩放边界。

## Capabilities

### New Capabilities

- `ios-appearance-customization`: iOS 客户端外观自定义能力，包括外观模式、主题预设、字体设置、持久化和主界面实时生效。

### Modified Capabilities

- 无。

## Impact

- 影响 SwiftUI iOS 客户端：
  - `ios/CodexAgentPad/Sources/CodexAgentPadApp.swift`
  - `ios/CodexAgentPad/Sources/State/ThemeStore.swift`
  - `ios/CodexAgentPad/Sources/Features/Settings/SettingsView.swift`
  - `ios/CodexAgentPad/Sources/RootView.swift`
  - `ios/CodexAgentPad/Sources/Features/Conversation/*`
  - `ios/CodexAgentPad/Sources/Features/Projects/*`
  - `ios/CodexAgentPad/Sources/Features/Sessions/*`
  - `ios/CodexAgentPad/Sources/Features/Logs/*`
  - `ios/CodexAgentPad/Sources/Features/Inspector/*`
- 不影响后端、网络协议、会话数据模型、鉴权和 app-server JSON-RPC 链路。
- 不引入新的第三方依赖。
