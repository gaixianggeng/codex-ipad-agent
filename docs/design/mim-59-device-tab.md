# MIM-59「设备」一级入口设计交接

> 本 Issue 只交付信息架构、高保真概念稿和实现边界，不修改 iOS 业务代码。

## 目标

把 Mac 连接从“我的 → 更多 → Mac 连接”提升为一级“设备”入口，让用户在开始会话前即可确认当前工作宿主、切换已保存电脑、添加电脑并进入诊断；同时让“我的”回归用量、偏好和支持信息。

本轮的最小闭环是：

1. iPhone 使用“会话 / 工作区 / 设备 / 我的”四个系统 Tab。
2. iPad 宽屏侧栏主导航增加“设备”，“我的”仍固定在侧栏底部。
3. 设备页覆盖已连接、连接中、离线、无设备和多设备；状态首先回答“现在能不能工作”和“下一步做什么”。
4. iPad 设备内容在可用宽度足够时采用列表—详情，不足时采用单列；旋转、分屏和 Stage Manager 改变宽度时保留设备选择与滚动位置。
5. 只组合仓库已有的连接档案、切换、配对、探活、测速和 Doctor 诊断能力，不新增后端协议、持久化模型、账号体系、云同步或依赖。

## 方案

### 1. 仓库事实审计

#### 顶层导航与“我的”

- 当前生产入口是 `RootView` → `UnifiedWorkbenchShell`，不是 `ProfileRootView`。`ProfileRootView` 和其中的 `MacConnectionPanel` 在仓库内没有调用点，不应作为新页面的接入基础。
- iPhone/紧凑宽度由 `CompactWorkbenchTab`、每个 Tab 的 `NavigationStack` 和 `WorkbenchNavigationState` 驱动，目前只有“会话 / 工作区 / 我的”。
- iPad 由同一个 `UnifiedWorkbenchShell` 驱动；宽度小于 860pt 时切到紧凑 Tab，达到 860pt 时使用侧栏/浮动侧栏。判断已经同时使用实际容器宽度、Size Class 和 iPad 设备类型。
- 宽屏侧栏的一级入口目前是“会话 / 工作区”，底部 Footer 是“我的”和新建会话；这正好提供“设备放主导航、我的留在底部”的最小落点。
- 实际“我的”页面是 `SettingsView`。其“更多”区包含 `ConnectionManagementView`、诊断与支持、高级与开发、关于与法律。MIM-59 落地时应移除其中的连接管理行，并把“我的偏好设置”改为“偏好设置”；其他能力不变。

#### 可复用的设备与连接能力

| 现有事实 | 可用于设备页 | 限制 |
| --- | --- | --- |
| `ConnectionProfile` | 稳定 `id`、显示名、endpoint、上次成功时间、installation ID、主机平台、revision | 没有“持续在线时长”“设备型号”“物理位置” |
| `ConnectionProfileSettingsModel` | 当前档案、其他档案、保存数量和稳定排序 | 当前与其他被分开；概览页不要把当前设备再复制进“其他设备” |
| `AppStore.connectionStatus` | 当前设备的未连接、连接中、已连接、失败 | 只描述当前连接，不可套用到其他档案 |
| `SessionStore.connectionSwitchTargetProfileID` | 精确标记正在切换到哪台设备，并禁用冲突操作 | 同一时间只允许一个切换事务 |
| `HostStatusStore` / `HostProbeState` | 非当前设备的未知、检查中、可用、不可用、需认证、身份不匹配、需升级 | `checkedAt` 是本次运行中的探测时间，不是持久化“最后在线” |
| `SessionStore.switchConnectionProfile(id:)` | 复用已验证、可回滚的切换事务及暖快照恢复 | 切换失败必须留在原宿主并展示现有错误，不能乐观改选中态 |
| `InitialConnectionSettingsSections` | 扫码、粘贴、手动添加、修复、重命名、复制、删除 | 当前与 `Form`/设置页耦合，首版只需复用入口和已有回调，不复制连接协议逻辑 |
| `ConnectionManagementView` | 完整的“管理连接”二级页 | 当前是 `SettingsView.swift` 内的 `private` 类型，落地时需缩小范围地调整可见性或提取到设备 Feature |
| `ConnectionSpeedTestView`、`DoctorView` | “连接帮助与诊断”的二级能力 | 均在设置 Feature 内；不要把详细阶段、JSON 或 Runtime 信息铺在设备首页 |
| `HostPlatform` / `HostPlatformGlyph` | macOS、Windows、Linux、未知平台的真实图标语义 | 未上报平台必须使用通用电脑，禁止从名称猜平台 |

`AppStore.activeConnectionRoute` 只能可靠区分当前连接的“本机直连”和已配置路由；已配置路由目前显示为 Tailscale。`ConnectionTestReport` 可以在用户实际运行测速后给出更细的 Tailscale 网络路径，但不是所有设备都具备的常驻数据。因此概念稿中的“局域网”仅表示信息层级，不应直接写死为实现文案；没有可信路由数据时显示 endpoint 摘要或省略连接方式。

`ConnectionProfile.lastSuccessfulAt` 只表示“上次成功连接”，不能写成“最后在线”。`HostProbeStatus.checkedAt` 只表示“上次检查”。实现文案必须区分二者，避免虚构实时在线记录。

#### 本地化现状

可直接复用的键包括：

- 导航与标题：`ui.session`、`ui.workspace`、`ui.me`、`ui.mac_devices`。
- 分区与状态：`ui.current_connection`、`ui.saved_mac`、`ui.current_label`、`ui.connected`、`ui.connecting`、`ui.offline`、`ui.connection_failed`、`ui.available`、`ui.not_connected`。
- 动作：`ui.add_mac`、`ui.switch`、`ui.retry`、`ui.manage_connections`、`ui.check_host_status`、`ui.diagnosis_and_support`。

落地时至少需要补充“设备”短 Tab 文案、“偏好设置”、设备空态和“上次成功连接/上次检查”的中英文键。不要复用语义不准确的近似键；新增键仍进入 `Localizable.xcstrings` 并由 `LocalizationTests` 覆盖。

### 2. 信息架构

本方案按 Apple Design 与 SwiftUI UI Patterns 做了以下取舍：

- **Purpose / Simplicity**：设备是会话运行前提，值得一级入口；首页只保留状态、选择、添加与求助，不把所有设置搬上来。
- **Familiarity / Flexibility**：使用系统 Tab、侧栏、NavigationStack、List/Form、toolbar 和 ProgressView；布局由可用宽度而非机型名称决定。
- **Response / Agency**：点击设备行立即更新查看 selection，切换必须点击明确动作；连接事务进行中持续反馈，失败保留原当前设备并允许重试。
- **Accessibility / Reduced Motion**：44pt 命中区、Dynamic Type 重排、VoiceOver 非颜色语义和 Reduce Motion 是布局输入，不作为上线后补丁。
- **SwiftUI 状态所有权**：共享的 selection/scroll 放在跨布局稳定的 Shell，视图局部展开态用 `@State`，现有 Store 继续经 environment 注入；不为页面新增 ViewModel 或全局 Router。

#### iPhone：四个一级 Tab

| 顺序 | Tab | SF Symbol | 根页面 |
| --- | --- | --- | --- |
| 1 | 会话 | `bubble.left.and.bubble.right` | 现有会话列表 |
| 2 | 工作区 | `folder` | 现有工作区 |
| 3 | 设备 | `desktopcomputer` | 新的“Mac 与设备”页 |
| 4 | 我的 | `person.crop.circle` | 精简后的 `SettingsView` |

“设备”放在“工作区”和“我的”之间：它是运行会话的前提和工作对象，不是个人偏好。`desktopcomputer` 没有稳定的同名 fill 配对，选中态沿用系统 Tab tint 和选中语义，不拼接不存在的 Symbol，也不额外自绘胶囊。

每个 Tab 继续拥有独立 `NavigationStack`。从“设备”进入设备详情、连接管理或诊断后，切换到其他 Tab 再返回时保留原栈；不把设备详情塞进会话/工作区的 path。

#### iPad：侧栏与自适应内容

- 侧栏主导航顺序为“会话 / 工作区 / 设备”；当前选中规则、图标字重和 selection fill 复用 `WorkbenchSidebarDestinationButton`。
- “我的”继续固定在侧栏 Footer，不与工作对象混排。
- iPad 紧凑宽度直接复用 iPhone 四 Tab，而不是依赖 `NavigationSplitView` 自动折叠。
- iPad 宽屏外层仍由现有侧栏负责全局导航。设备页内部只在主内容区宽度足够时使用轻量 `HStack` 列表—详情，避免嵌套第二个 `NavigationSplitView`。
- 设备主内容区建议以实际可用宽度 760pt 为首版切换基线：达到基线时使用约 300–340pt 设备列表和剩余详情；不足时使用单列。该值应由快照覆盖 iPad 横竖屏、Split View 和 Stage Manager 后再微调，不按机型硬编码。

### 3. 页面结构与高保真规格

#### 单列设备页（iPhone、窄 iPad）

1. 导航标题“Mac 与设备”，右上角系统 `plus` 添加入口；iPad 折叠侧栏时同时保留系统侧栏显示按钮。
2. “当前连接”区：只显示当前设备一次。整行可进入详情；显示真实平台图标、名称、可读状态和一个可信的辅助信息。
3. “已保存的电脑”区：只显示 `ConnectionProfileSettingsModel.others`。多设备按现有“上次成功连接降序、名称升序”规则排列。
4. “连接帮助与诊断”置于末尾，保持低权重，不与添加/切换争夺主动作。
5. 无设备时使用系统空态：标题“还没有连接的电脑”，说明“添加电脑后，可在这里查看状态并切换”，主按钮“添加电脑”；不显示空白的当前/已保存分区。

当前设备在概念源图中同时出现于“当前连接”和“已保存”列表。审查后确定实现必须去重：当前连接卡展示当前设备，已保存列表只展示其他设备。宽屏列表同样每台设备只出现一次，以选中背景和“当前”标签表达双重语义。

#### 宽屏设备页（iPad）

- 左侧：现有全局侧栏。
- 中间：设备列表，标题“Mac 与设备”，工具栏 `plus`；当前设备默认选中但只出现一次。每行展示平台、名称、状态/上次成功连接，整行可选。
- 右侧：选中设备详情。首屏只放名称、平台、状态、可信的连接摘要，以及“管理连接”“重新连接/切换”“连接帮助与诊断”。高风险删除、复制凭据和手动字段继续留在管理连接二级页。
- 当前设备与列表选中是两个不同概念：`activeConnectionProfileID` 表示正在工作的宿主，`selectedProfileID` 表示用户正在查看的详情。用户可以查看其他设备而不立即切换；只有点击明确的“切换”动作才启动连接事务。
- 未选择且存在设备时，优先选择当前设备；无当前设备则选择排序后的第一台。所选设备被删除后回退到当前设备或第一台，不能留下空白详情。

#### 状态矩阵

| 场景 | 当前区/列表文案与视觉 | 主要动作 | 数据来源 |
| --- | --- | --- | --- |
| 已连接 | 绿色状态点 + “已连接”；可附本机直连/已配置路由摘要 | 查看详情、返回工作 | 当前 profile + `AppStore.connectionStatus` |
| 连接中 | `ProgressView` + “正在连接…”；目标行禁用重复切换 | 等待；可查看其他设备但不并发切换 | `connectionSwitchTargetProfileID` / `.testing` |
| 当前连接失败或全局离线 | 橙/红状态 + “离线”或“连接失败”；错误详情进入二级页 | 重试、诊断 | 网络状态 + `connectionStatus` |
| 其他设备可用 | 非当前行使用可用状态点 + “可用” | 明确点击“切换到这台电脑” | `HostStatusStore.available` |
| 其他设备不可用 | “暂时无法连接”；辅助信息为上次检查或上次成功连接 | 重新检查、诊断 | `.unavailable` + `checkedAt` / `lastSuccessfulAt` |
| 需认证/身份不匹配/需升级 | 使用钥匙、盾牌或升级语义，不统一伪装成离线 | 修复配对、管理连接 | 对应 `HostProbeState` |
| 无设备 | 系统空态，不显示伪造设备卡 | 添加电脑 | `connectionProfiles.isEmpty` |
| 多设备 | 当前设备只标记一次；查看选择与当前连接分别表达 | 查看不触发切换；按钮触发切换 | profile ID + view-local selection |

状态不能只靠红绿颜色区分。图标/进度、文字和 VoiceOver 值必须同时表达；“可用”不等于“已连接”。

### 4. 概念稿与 ImageGen 交付说明

概念图用于确认信息密度、层级和自适应关系，不是像素或数据合同。最终 SwiftUI 应优先采用系统导航、`List`/`Form`、语义色、Dynamic Type 和仓库现有 Theme token。

- [iPhone 设备与“我的”参考稿](assets/mim-59-device-iphone.png)：来自早期概念稿，确认四 Tab 与“我的”精简方向；其中当前设备重复和“局域网/在线时间”文案按本交接文档纠正。
- [iPad 宽屏列表—详情参考稿](assets/mim-59-device-ipad-wide.png)：确认全局侧栏 + 设备列表 + 设备详情的三层结构、当前设备只高亮一次、工具栏添加入口和低权重诊断。
- [iPad 窄屏单列参考稿](assets/mim-59-device-ipad-narrow.png)：确认按可用宽度退化为单列、保留系统侧栏入口，并明确旋转/窗口调整后保留当前选择。

新增两张 iPad 概念稿使用 Codex 内置 `image_gen` 生成，类型为 `ui-mockup`：

- 宽屏 prompt 聚焦真实的列表—详情关系、当前设备只高亮一次、工具栏添加、低权重诊断入口，不增加账号、云同步或虚构运行指标。
- 窄屏 prompt 聚焦按实际可用宽度使用单列、保留系统侧栏入口、布局切换后维持设备选择，不按具体 iPad 型号锁定布局。

### 5. 交互、状态保持与无障碍

#### selection 与 scroll

- `selectedProfileID` 和设备列表滚动锚点必须由 `UnifiedWorkbenchShell` 的稳定层级持有，再以 Binding 传给宽屏与单列设备页；不要放在仅存在于某个 `if layout...` 分支的子视图里。
- 设备行使用 profile `id` 作为稳定身份。宽屏选中一台设备后缩窄窗口，单列页保持同一设备为当前查看目标；若需要进入详情，使用设备 Tab 自己的 path，不改写会话/工作区 path。
- 列表滚动位置使用稳定 ID 记录锚点。布局切换后只在目标仍存在时恢复；不要无条件滚到顶部或当前连接。删除目标时先修正 selection，再恢复滚动。
- 切换设备成功只更新“当前”身份，不强制把用户查看中的另一台设备抢回当前；若产品验收希望成功后跟随当前设备，应作为显式规则写测试，不能依赖 SwiftUI 重建偶然发生。

#### 触控、字体与 VoiceOver

- 所有行、加号、侧栏开关、诊断和重试入口至少 44×44pt；视觉图标可以更小，但用 padding/`contentShape` 保留命中区。
- 正文使用系统语义字体或 `ThemeStore.uiFont`，不固定行高。Dynamic Type 到 Accessibility 尺寸时，状态与时间移到第二行，动作允许换行；名称最多两行，不能把状态挤成逐字换行。
- 设备行 VoiceOver 建议顺序：“设备名，平台，当前/未当前，已连接/可用/离线，上次成功连接时间”。整行标记为按钮；列表选择使用 `.isSelected`，当前连接另用明确的 accessibility value，不把两者混成一个“选中”。
- 连接中使用可访问的 `ProgressView`；切换成功/失败通过现有状态和 Alert 表达，必要时发送简短 announcement。错误详情不得只显示 endpoint 或内部错误码。
- 图标和状态点仅为补充，任何颜色变化都必须有文字等价物。平台未知时读作“电脑”，不猜测 macOS/Windows/Linux。

#### Reduce Motion

- 沿用 `accessibilityReduceMotion`。宽窄布局、侧栏显隐和详情替换在 Reduce Motion 开启时使用无位移的静态更新或短交叉淡化；不开弹性位移，不自动滚动制造大幅运动。
- 默认动画从当前呈现值开始，采用可中断、临界阻尼的轻量 spring；连接状态变化本身不需要 bounce。
- 任何动画都不能锁住添加、返回或查看其他设备。连接事务的禁用范围只覆盖会产生冲突的切换/编辑动作。

## 实现

### 1. 最小代码落点（后续 Issue/实现阶段）

| 文件/模块 | 最小改动 | 复用内容 |
| --- | --- | --- |
| `Features/Shell/UnifiedWorkbenchShell.swift` | `AppDestination`、`CompactWorkbenchTab` 增加设备；iPhone 增加第四 Tab；iPad 侧栏增加设备入口；detail 映射到设备页 | 现有 per-tab `NavigationStack`、侧栏 Row、Layout 判断 |
| `WorkbenchChrome.swift` | 扩展 `WorkbenchNavigationState` 对设备 Tab/选择的归并；确保宽窄切换不丢设备入口 | 现有单事件 reduce 和延迟 Binding scheduler |
| `Features/Shell/WorkbenchSidebarComponents.swift` | `WorkbenchNavigationIcon` 增加 `.devices`，使用 `desktopcomputer` | 现有选中态、Theme token 和 Footer |
| 新建 `Features/Devices/DevicesRootView.swift` | 只负责设备概览、宽窄组合、selection/scroll Binding 与状态映射 | `AppStore`、`SessionStore`、`HostStatusStore`、`HostPlatformGlyph` |
| `Features/Settings/SettingsView.swift` | “我的”移除连接管理行，偏好分区改名；将连接管理/诊断目标暴露给设备页 | `ConnectionManagementView`、`DiagnosticsAndSupportSettingsView` |
| `Features/Settings/InitialConnectionSettingsSections.swift` | 仅在确有必要时提取可复用添加/修复入口；不复制保存与切换逻辑 | 原扫码、粘贴、手动、修复、删除流程 |
| `Resources/Localizable.xcstrings` | 增加精确的新文案，复用已有状态键 | `L10n` 现有机制 |

不要新增设备 Repository、Coordinator、ViewModel、后端 DTO 或第三方布局库。首版用现有 `ObservableObject` 环境对象和最窄的 view-local `@State`/Binding 即可；设备页不持有 Token，也不直接发网络请求。

`ProfileRootView` 是无调用点的旧组合，不要同时改造成第二套设备页。若后续确认删除旧文件，应单独做可达性清理，不混入 MIM-59。

### 2. 导航和状态实现建议

1. 给 `AppDestination` 增加 `.devices` 和按需的 `.device(profileID:)`；给 `CompactWorkbenchTab` 增加 `.devices`。
2. 为设备 Tab 保留独立 path，或在设备根视图内部使用稳定的单一 `NavigationStack`。不得复用 sessions/workspaces path。
3. `WorkbenchNavigationState` 把“设备”当作一级覆盖入口，像“我的”一样保留后台会话恢复 route；布局切换时显式保留 `.devices`，不能被 `synchronize(restorationRoute)` 抢回会话。
4. `UnifiedWorkbenchShell` 稳定持有 `selectedProfileID` 和滚动锚点；Device View 只接收 Binding。当前连接、查看选择、切换目标分别来自不同字段，禁止合并为一个布尔状态。
5. 设备页出现时调用 `HostStatusStore.refreshIfNeeded`，沿用它的后台、网络、加载、节流、并发 2 个和最多 8 台保护；页面消失不额外创建轮询器。
6. 查看设备详情只更新本地 selection；切换按钮调用 `SessionStore.switchConnectionProfile(id:)`。失败沿用原 Alert 和重试/管理连接入口，成功后由 Store 发布真实 active profile。
7. 添加、修复、删除和诊断继续导航到现有二级页面。设备首页不展示 Token、完整 endpoint、installation ID、Doctor JSON 或网关指标。

### 3. 验证清单

| 验收面 | 必测矩阵 |
| --- | --- |
| 导航 | iPhone 四 Tab 独立历史；iPad 侧栏设备；我的仍在 Footer；宽窄切换仍停留设备页 |
| 布局 | iPhone 320/390pt；iPad 小窗 <760pt 单列；主内容 ≥760pt 列表—详情；旋转、Split View、Stage Manager |
| 数据 | 0、1、3、8 台；当前 ID 缺失；档案删除；未知平台；长中英文名称 |
| 状态 | idle/testing/connected/failed；网络离线；HostProbe 的 7 种状态；切换成功、失败、取消 |
| 状态保持 | 选中非当前设备后宽→窄→宽；列表滚动后旋转；切 Tab 返回；删除已选设备 |
| 无障碍 | 44pt、Accessibility 1–5 字号、VoiceOver 顺序/选中/当前语义、Increase Contrast、Reduce Motion、Reduce Transparency |
| 本地化 | 中英文标题、Tab、状态、复数和相对时间；`LocalizationTests` 与脚本检查通过 |

后续实现建议补充：

- `ConversationSessionStoreTests`：设备 Tab 在 `WorkbenchNavigationState` 中的路由归并和宽窄切换保持。
- `HostStatusStoreTests`：设备页复用探活时不绕过现有节流、取消和 revision 校验。
- 快照：iPhone 无设备/连接中/多设备，iPad 窄单列与宽列表—详情，至少一组 Accessibility Dynamic Type。
- 运行态：固定 iPad Pro 13-inch (M5) 验证横竖屏和窗口调整；明确的 iPhone 验收再使用项目约定的 iPhone 设备。

本 Issue 到此为设计交付，以上代码和测试均不在 MIM-59 中实施。

## 风险与优化

1. **概念稿包含不可靠数据。** “局域网”“刚刚”“在线 10 分钟前”不一定能从当前模型可靠获得。首版必须用 `activeConnectionRoute`、`lastSuccessfulAt`、`checkedAt` 的准确语义，数据缺失时省略，不造数。
2. **当前与选中容易混淆。** 宽屏查看另一台设备不代表已切换。需要分别呈现当前标签、列表 selection 和切换中的 target，并用测试锁定。
3. **导航恢复可能抢页。** 现有 restoration route 只认识会话/工作区，“我的”靠特殊分支保留。设备若只加一个 View 而不扩展 reducer，旋转后可能被同步回原 route；这是实现阶段的首要导航风险。
4. **设置组件可见性与耦合。** `ConnectionManagementView`、`DiagnosticsAndSupportSettingsView` 当前为 private。优先做同模块的最小提取，不复制连接表单或业务回调，也不为复用而引入新的 Coordinator。
5. **四 Tab 的空间压力。** 中文短标签可容纳，英文需要使用 “Devices” 并以 320pt、最大 Dynamic Type 验证。若系统自动隐藏标签或截断，先精简文案，不改成自绘 Tab Bar。
6. **探活成本。** `HostStatusStore` 已有 2 秒超时、每批 2 台、每次最多 8 台和退避。设备页必须复用这些约束，不新增持续轮询；超过 8 台的刷新由既有轮转覆盖。
7. **详情动作过多。** 首版详情只保留管理、切换/重试和诊断；复制连接、重命名、删除、扫码修复进入管理页。真实使用证明需要后再上提，不提前堆成新的设置中心。
8. **selection/scroll API 可用性。** 实现前确认项目最低 iOS 与拟用 `scrollPosition` API；若可用性不匹配，使用 `ScrollViewReader` + 稳定 ID 的现有兼容写法，不抬高部署目标。

未知项留给实现前确认：

- 产品是否要求设备页成为冷启动恢复目标；本稿默认它像“我的”一样保留隐藏的工作台 route，避免扩大 `WorkbenchRestorationRoute` 的持久化语义。
- 切换成功后详情是否自动跟随新当前设备；本稿默认保留用户正在查看的 selection，以减少意外跳转。
- 已配置路由是否未来要区分 LAN、Tailscale 直连、Peer Relay 和 DERP；当前首页不承诺这项能力，只有测速结果页展示已有诊断。
