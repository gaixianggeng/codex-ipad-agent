## Context

当前 iOS 客户端已经存在 `ThemeStore`、`ThemeMode`、`ThemeAccent` 和外观设置页雏形，但 `SettingsView` 内部用 `@StateObject` 创建局部 `ThemeStore`，导致主题选择主要影响设置页和预览，主工作台仍使用系统默认颜色、`Color.accentColor`、`.primary/.secondary` 和硬编码字体。

这次变更属于跨视图的 UI 状态能力，影响 Root、设置、聊天、输入、侧栏、会话列表、日志和 Inspector。实现必须轻量，不能引入新依赖，也不能影响 agentd、app-server、会话状态和消息数据流。

## Goals / Non-Goals

**Goals:**

- 将主题状态提升为 App 级共享状态，所有核心 SwiftUI 视图可以读取同一份外观偏好。
- 支持跟随系统、浅色、深色三种外观模式。
- 支持少量内置主题预设，先覆盖 Codex、Xcode、Gruvbox。
- 支持 UI 字体、代码字体和字体缩放，并持久化到 `UserDefaults`。
- 让主题变更实时影响高频工作台界面，不需要重启 App。
- 用单元测试覆盖主题偏好读写、非法值回退和缩放边界。

**Non-Goals:**

- 不做 Mac 端完整主题列表，也不实现主题导入、复制、自定义颜色编辑器。
- 不接入远端同步，主题偏好只保存在本机。
- 不改变后端 API、WebSocket、app-server runtime 或消息模型。
- 不重写整个 UI 设计系统，只在现有 SwiftUI 结构上渐进接入 token。

## Decisions

### 1. 使用 App 级 `ThemeStore`，不放入 `AppStore`

`CodexAgentPadApp` 创建一个 `@StateObject ThemeStore` 并通过 `.environmentObject(themeStore)` 注入。`RootView` 和所有子视图直接通过环境读取主题。

选择原因：

- 主题是纯本地视觉偏好，不属于连接配置、Token 或会话状态。
- 独立 store 可以避免外观切换触发网络/会话 store 的副作用。
- 现有 `SettingsView` 已经有 `ThemeStore` 骨架，迁移成本低。

备选方案：

- 放入 `AppStore`：会让 AppStore 同时承担连接和视觉职责，后续维护成本更高。
- 用全局 singleton：测试隔离差，也不符合现有 SwiftUI `EnvironmentObject` 风格。

### 2. 主题预设产出 token，不让视图直接判断主题名

`ThemePreset` 负责按浅色/深色产出 `ThemeTokens`。视图只消费 `ThemeTokens` 和字体 API，不写 `if preset == ...`。

选择原因：

- 主题扩展时只改模型，不需要逐个视图加分支。
- 保持 MVP 简单，避免完整设计系统和 JSON schema。
- 测试可以直接验证 token 和偏好状态。

### 3. 字体用枚举 + helper API，不引入自定义字体文件

第一版只使用系统内置字体设计：默认、圆体、衬线、等宽。`ThemeStore` 提供 `uiFont(...)`、`codeFont(...)` 和 `scaledFontSize(...)`。

选择原因：

- 不需要打包字体资源，不增加 App 体积和授权风险。
- iPadOS 动态类型和系统字体渲染更稳定。
- 可以覆盖“字体切换”的真实需求，后续再决定是否加入外部字体。

### 4. 先覆盖主链路视图，边角页面渐进接入

优先接入：

- Root/导航 tint 和 preferred color scheme
- Settings 外观页
- Project sidebar、Session list
- Conversation timeline、Message bubble、Composer
- Log panel、Inspector、Diff/Approval/Context 卡片

选择原因：

- 用户每天使用的是工作台主链路，先让这些界面一致。
- 诊断页等低频页面可以继续使用系统 Form 样式，不阻塞 MVP。

## Risks / Trade-offs

- [Risk] 主题 token 没有覆盖所有系统控件，局部页面仍有系统默认背景。  
  Mitigation: 先覆盖高频工作台，低频 Form 页保留系统适配，后续按用户反馈补齐。

- [Risk] SwiftUI `Form` 在不同 iPadOS 版本下背景控制不完全一致。  
  Mitigation: 外观页主要依赖 `preferredColorScheme`、`tint` 和预览组件，避免强行重写所有 Form 样式。

- [Risk] 字体缩放过大导致按钮或侧栏文本溢出。  
  Mitigation: 缩放限制在 85%-135%，现有关键文本继续使用 `lineLimit` 和 `minimumScaleFactor`。

- [Risk] 主题变更引起大量视图重绘。  
  Mitigation: `ThemeStore` 只保存轻量枚举和数值；消息列表继续依赖现有 `MessageRow.equatable()` 降低流式输出成本。

## Migration Plan

1. 在新 worktree 分支实现并验证，不影响当前 direct 分支脏改动。
2. 保留旧 UserDefaults key 的兼容读取；缺失或非法值使用默认主题。
3. 构建和测试通过后，真机/模拟器手工验收主界面外观切换。
4. 回滚方式：撤回该分支即可，不涉及数据迁移和后端变更。

## Open Questions

- 后续是否需要与 Mac 端主题名称完全对齐。
- 后续是否要支持自定义主题导入/导出。
- 是否需要让主题偏好跟随用户账户跨设备同步。
