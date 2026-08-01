# MIM-73 Presentation Source 设计门禁

## 目标

让 New Session 与 Inspector 只在存在稳定、可见的点击来源时使用系统源点转场；键盘、Deep Link、恢复、菜单项和自动弹出继续使用普通系统 Presentation。状态必须记录“展示什么”和“从哪里展示”，避免同屏多个按钮匹配到错误来源。

## 方案

项目最低系统版本为 iOS / iPadOS 26，直接使用 SwiftUI 公共 API：

- 工具栏来源：[`ToolbarContent.matchedTransitionSource(id:in:)`](https://developer.apple.com/documentation/swiftui/toolbarcontent/matchedtransitionsource%28id%3Ain%3A%29)
- 普通 View 来源：[`View.matchedTransitionSource(id:in:)`](https://developer.apple.com/documentation/swiftui/view/matchedtransitionsource%28id%3Ain%3A%29)
- Sheet 目标：[`navigationTransition(.zoom(sourceID:in:))`](https://developer.apple.com/documentation/swiftui/zoomnavigationtransition)

不使用 `matchedGeometryEffect` 伪造跨 Sheet 动画，不引入第三方动画库，也不改变现有 `sheet(item:)`、`NavigationSplitView` 或业务状态机。

### Source / Fallback 矩阵

| 目标 | 触发路径 | Presentation | 原因 |
| --- | --- | --- | --- |
| New Session | 会话列表右上角加号 | `sessionsToolbarNewSession` → system zoom | 工具栏按钮稳定可见，来源明确 |
| New Session | 宽 iPad 浮动侧栏底部加号 | `sidebarNewSession` → system zoom | 侧栏按钮稳定可见，且与工具栏来源必须区分 |
| New Session | 空态按钮、键盘、Deep Link、恢复 | 普通 Sheet | 没有本 Issue 已确认的稳定 source，先 fail closed |
| Inspector | 中等宽度会话详情的独立工具栏按钮 | `sessionToolbarInspector` → system zoom | 仅 sheet 形态且按钮稳定可见时启用 |
| Inspector | 宽 iPad attached inspector | 原生 `.inspector` | 不是 Sheet，不附加 zoom |
| Inspector | iPhone 更多菜单、键盘、Deep Link、恢复、子 Agent 自动打开 | 普通 Sheet / 原生 push | 菜单项生命周期短或没有可见来源，禁止伪匹配 |

### 状态与身份

1. `UnifiedWorkbenchShell` 持有单一 `@Namespace`。
2. Presentation 状态同时保存 destination 与可选 source kind；source ID 由固定枚举映射，不使用随机 UUID。
3. 两个 New Session 按钮始终使用不同 source ID。目标 Sheet 只读取本次状态中的 source；没有 source 时不附加 zoom。
4. Inspector 的 source 只由明确点击入口设置。外部 `showingInspector` 变为 `true` 时若没有 source，必须普通呈现。
5. Sheet / Inspector 关闭后清空 source；不能让下一次键盘或恢复路径复用上一次点击来源。

### 动效与辅助功能

- 源点与目标只使用系统 zoom，进入和退出沿同一空间路径返回。
- Reduce Motion 下不附加 zoom，保留普通系统 Sheet、标题、关闭动作和焦点语义。
- 每次打开时读取 Reduce Motion 并锁定本次转场；设置在 Sheet 展示期间变化时不重建表单，下一次打开再应用新值。
- 动画不能拥有业务状态；会话选择、流式消息、Composer 焦点与 Inspector 内容更新继续独立运行。
- VoiceOver 通过真实 Button、现有可访问标签和 Sheet 标题理解流程，不依赖虚线、缩放或颜色。
- 关闭后优先依赖系统恢复到仍存在的来源控件；运行态验收若发现焦点不稳定，再做最小、目标明确的 FocusState 修正。

## 实现

ChatGPT Pro 实施前门禁结论为 `GO`（Blocker 0 / High 0 / Medium 3）。本轮先只完成 New Session Prototype Gate；Inspector 保留在 MIM-73 内作为第二阶段，但不与原型混入同一 PR：

1. 建立 source kind / presentation state 和单一 Namespace。
2. 为会话列表 toolbar 与 iPad sidebar 两个入口绑定不同 source ID。
3. 目标 `NewSessionSheet` 只在 source 存在且未启用 Reduce Motion 时使用 system zoom。
4. 在 iPhone 17 Pro、iPhone 17e、iPad Pro 13-inch (M5) 和窄窗口验证 source identity、关闭返回、普通 fallback 与 Reduce Motion。
5. Prototype 通过后才把同一模型扩展到 sheet 形态的 Inspector；attached inspector 和程序化路径保持原行为。

Prototype Gate 的状态职责进一步收敛为：source 是一次 Presentation identity 的组成部分，不是按钮级 UI flag；Reduce Motion 由展示入口读取并锁定到本次 Presentation，避免设置在表单打开时变化导致 SwiftUI 分支重建和本地状态丢失。关闭后必须清空整次 Presentation，下一次打开重新读取设置，并验证 `toolbar -> dismiss -> sidebar` 与反向顺序均不会复用旧 source。

### Prototype 运行态证据

- iPad Pro 13-inch (M5)：侧栏加号沿自身源点 zoom 展开并原路关闭；普通系统 Sheet fallback、旋转期间表单持续存在、工作区与 Runtime 选择保持。
- Reduce Motion：开启后从侧栏打开为普通系统 Sheet；展示期间切换设置，当前表单不重建，下一次 Presentation 才采用新设置。
- iPhone 17 Pro：会话列表工具栏加号沿右上角源点 zoom 展开并原路关闭，来源未误匹配刷新按钮。
- iPhone 17e：小屏半高 Sheet 的标题、取消、创建、工作区和 Runtime 控件完整可见，工具栏入口可正常展开与关闭。
- 定向测试：`NewSessionPresentationSourceTests` 8/8、侧栏导航快照 1/1 通过。

实施前评审记录：[MIM-73 ChatGPT Pro 会话](https://chatgpt.com/c/6a6e6fb1-afa8-83ea-b56d-e6e9e60b9968)。

同一会话的 Prototype 合并前终审结论为 `GO`（Blocker 0 / High 0 / Medium 0 / Low 2，合并前必须修改项：无）。终审明确接受“打开时锁定 Reduce Motion 转场、下一次打开应用新值”的取舍，认为它比展示期间动态切换 View 结构更适合当前含本地表单状态的架构。

## 风险与优化

- `SessionListView` 当前把 toolbar 与空态入口汇总到同一个无参数回调；实现必须区分触发来源，不能把空态错误标记成 toolbar source。
- 工具栏加号当前与刷新按钮位于同一个 `ToolbarItemGroup`。Prototype 必须确认 source 只绑定加号，不把整个工具组当作来源。
- `showingInspector` 由 `RootView` 绑定并存在多条程序化写入路径；source 不能并入业务布尔值，也不能在外部打开时猜测来源。
- 如果任一入口在 public API 下不能稳定匹配，记录设备、系统、布局与证据，并降级为普通 Presentation；不扩大 source 命中范围，不重写导航架构。
