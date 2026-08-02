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

ChatGPT Pro 实施前门禁结论为 `GO`（Blocker 0 / High 0 / Medium 3）。New Session Prototype Gate 已通过 PR #119 合并到 `main`（merge commit `91d8e9b3`）；Inspector 继续使用独立分支完成第二阶段，避免把原型与扩展实现混在同一审查批次：

1. 建立 source kind / presentation state 和单一 Namespace。
2. 为会话列表 toolbar 与 iPad sidebar 两个入口绑定不同 source ID。
3. 目标 `NewSessionSheet` 只在 source 存在且未启用 Reduce Motion 时使用 system zoom。
4. 在 iPhone 17 Pro、iPhone 17e、iPad Pro 13-inch (M5) 和窄窗口验证 source identity、关闭返回、普通 fallback 与 Reduce Motion。
5. Prototype 通过后把同一模型扩展到 sheet 形态的 Inspector；attached inspector 和程序化路径保持原行为。

Prototype Gate 的状态职责进一步收敛为：source 是一次 Presentation identity 的组成部分，不是按钮级 UI flag；Reduce Motion 由展示入口读取并锁定到本次 Presentation，避免设置在表单打开时变化导致 SwiftUI 分支重建和本地状态丢失。关闭后必须清空整次 Presentation，下一次打开重新读取设置，并验证 `toolbar -> dismiss -> sidebar` 与反向顺序均不会复用旧 source。

### Prototype 运行态证据

- iPad Pro 13-inch (M5)：侧栏加号沿自身源点 zoom 展开并原路关闭；普通系统 Sheet fallback、旋转期间表单持续存在、工作区与 Runtime 选择保持。
- Reduce Motion：开启后从侧栏打开为普通系统 Sheet；展示期间切换设置，当前表单不重建，下一次 Presentation 才采用新设置。
- iPhone 17 Pro：会话列表工具栏加号沿右上角源点 zoom 展开并原路关闭，来源未误匹配刷新按钮。
- iPhone 17e：小屏半高 Sheet 的标题、取消、创建、工作区和 Runtime 控件完整可见，工具栏入口可正常展开与关闭。
- 定向测试：`NewSessionPresentationSourceTests` 8/8、侧栏导航快照 1/1 通过。

实施前评审记录：[MIM-73 ChatGPT Pro 会话](https://chatgpt.com/c/6a6e6fb1-afa8-83ea-b56d-e6e9e60b9968)。

同一会话的 Prototype 合并前终审结论为 `GO`（Blocker 0 / High 0 / Medium 0 / Low 2，合并前必须修改项：无）。终审明确接受“打开时锁定 Reduce Motion 转场、下一次打开应用新值”的取舍，认为它比展示期间动态切换 View 结构更适合当前含本地表单状态的架构。

### Inspector 第二阶段

Inspector 实施前继续复用同一 ChatGPT Pro 会话，门禁结论为 `GO（有条件）`（Blocker 0 / High 0 / Medium 3）：

1. `showingInspector` 继续是展示真相；新状态只保存一次 Presentation 的 host、可选 source 与锁定后的 transition。
2. 只有 860–1179pt regular 宽度下、独立 `sessionDetail.inspector` 工具栏按钮的直接点击可以写入 `sessionToolbarInspector`。
3. Compact 更多菜单、attached `.inspector`、布局恢复和子 Agent 程序化打开全部 fail closed，使用普通系统 Presentation。
4. medium / attached host 变化立即失效旧 context，禁止把 zoom source 跨 host 迁移；Sheet 正常关闭则保留 context 到 `onDismiss`，让退出动画回到原 source。
5. `WorkbenchChrome` 只消费 Shell 锁定的 context，不自行读取 Reduce Motion 或推导 eligibility，避免转场状态反向拥有 Inspector 业务状态。

最终实现增加独立的 `InspectorPresentationState`，并把 source 标识只挂在中等宽度的独立工具栏项上。Inspector 内容增加 `sessionInspector.content` 可访问标识，便于设备级断言。Sheet 真正 dismiss 后只清理 transition context；用户明确点击“完成”或工具栏关闭时才清理相关子 Agent 导航，布局迁移关闭 Sheet 时保留关系，避免 compact / attached host 丢失同一子 Agent。

### Inspector 验收证据

- 最终定向回归 18/18 通过：`NewSessionPresentationSourceTests` 15/15、侧栏导航快照 1/1、1032pt / 1180pt 布局边界 2/2，覆盖 medium zoom、compact / attached / 程序化 fallback、Namespace 缺失、Reduce Motion 锁定、重入拒绝、dismiss 清理、连续来源序列和 host 变化失效。
- iPad Pro 13-inch (M5) 1032pt：独立详情按钮沿自身源点 zoom 展开并返回；录屏 `/tmp/mim73-inspector-medium.mp4`。来源未误匹配刷新或更多按钮。
- Reduce Motion：设置开启时同一入口改为普通 Sheet；录屏 `/tmp/mim73-inspector-reduce-motion.mp4`。单元测试同时验证当前 Presentation 锁定、下一次打开才读取新设置。
- iPad 旋转 UI 回归：专用 `MimiRemotePhysicalUITests` 1/1 通过；Inspector 在 portrait → landscape → portrait 往返中保持展示，关闭后无残留。结果位于 `Test-MimiRemotePhysicalUITests-2026.08.02_07-54-17-+0800.xcresult`。
- iPhone 17 Pro 与 iPhone 17e：各自使用独立 DerivedData 完成 Debug 构建；`… → 显示详情` 均展示带系统表单控制柄的普通大 Sheet，关闭后 `sessionInspector.content` 消失，小屏控件可用。
- 1180pt attached 边界：`ResponsiveLayoutTests` 与 Inspector host 状态测试覆盖 `.inspector` 选择、无 zoom 和跨 host 清理。当前 Xcode 27 beta 远程模拟器在旋转后仍保持 1032pt 自由窗口，无法诚实形成 ≥1180pt 运行窗口，因此不把本轮旋转录屏误记为 attached 运行态证据。
- 独立只读审查初次结论为 Blocker 0 / High 0 / Medium 1 / Low 1。修正 stale 子 Agent 后的复审继续发现一个 High：通用 `onDismiss` 清业务关系会误伤布局迁移。最终实现把用户关闭与 host 迁移拆开，复审结论为 `GO`（Blocker 0 / High 0 / Medium 0），文档 Low 同步关闭。
- ChatGPT Pro 初次终审未识别上述迁移风险；收到独立复审证据与修正版源码包后纠正结论。最终纠错终审为 `GO`（Blocker 0 / High 0 / Medium 0 / Low 1，必须修改项：无），确认 `presentation dismiss ≠ business context dismiss` 的职责边界。Low 仅提醒未来若改变 interactive dismiss 语义需重新评估；当前范围无需修改。终审同时接受 1180pt 运行态缺口为已记录的剩余风险，不阻止本阶段合并。

## 风险与优化

- `SessionListView` 当前把 toolbar 与空态入口汇总到同一个无参数回调；实现必须区分触发来源，不能把空态错误标记成 toolbar source。
- 工具栏加号当前与刷新按钮位于同一个 `ToolbarItemGroup`。Prototype 必须确认 source 只绑定加号，不把整个工具组当作来源。
- `showingInspector` 由 `RootView` 绑定并存在多条程序化写入路径；source 不能并入业务布尔值，也不能在外部打开时猜测来源。
- 如果任一入口在 public API 下不能稳定匹配，记录设备、系统、布局与证据，并降级为普通 Presentation；不扩大 source 命中范围，不重写导航架构。
