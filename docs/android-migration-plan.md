# Mimi Remote Android 全功能迁移计划

## 目标与交付边界

以当前 iOS 可达功能为基线，完整迁移到原生 Android；功能、安全边界和异常处理保持一致，布局、导航、控件和动效按 Android 重做，不逐像素复制 iOS。

- 功能基线冻结为当前提交 `c3c8326`，迁移期间新增的 iOS 功能通过变更清单单独纳入。
- 首发覆盖 Android 手机、平板、折叠屏和窗口化场景。
- `minSdk 29`（Android 10），`compileSdk/targetSdk 37`（Android 17）。
- 首个公开版本必须达到全部功能对等；开发期间按阶段提供 Play Internal Testing 构建。
- 不新增云账号、云中继、任意 Shell、后台常驻服务或多用户系统。
- iOS 继续使用 SwiftUI；Android 使用 Kotlin/Compose，不引入 KMP，不重构现有 iOS 业务代码。
- 预计总投入 24–32 人周：单人约 5–7 个月；两名开发者约 12–16 周完成全功能内测版。

“功能原封不动”指能力和行为对等，Apple 专属实现使用 Android 等价能力替换，例如 Keychain → Android Keystore、Quick Look → Android 文件预览、Apple Speech → Android 设备语音输入。

## 技术与设计方案

### 工程架构

在仓库新增单一 Android 工程 `android/`，首版只保留一个 `:app` 模块，通过 package 分层，避免过早多模块化。

- 构建：AGP 9.3、Gradle 9.5、JDK 17、Gradle Wrapper；当前环境需补装 JDK 17 和 Android SDK 37。[AGP 9.3 官方兼容矩阵](https://developer.android.com/build/releases/agp-9-3-0-release-notes)
- UI：Kotlin、Jetpack Compose、稳定版 Material 3/Material 3 Adaptive；不依赖 alpha 组件。
- 状态：ViewModel + `StateFlow` 单向数据流，Coroutines 处理网络、事件和生命周期。
- 网络：OkHttp REST/WebSocket + Kotlin Serialization，直接消费现有 `/api/app-server/ws`，禁止恢复旧 `/api/sessions*` 链路。
- 依赖注入：轻量 `AppContainer` 手动注入；只为网络、存储、通知等需要测试替身的边界定义接口。
- 本地数据：DataStore 保存非敏感设置；Token 使用 Android Keystore 生成的 AES-GCM 密钥加密；队列写入 `noBackupFilesDir`，禁止云备份。
- 内容：CommonMark/GFM 解析后由 Compose 原生渲染；Coil 负责图片；Photo Picker 选择图片，不申请广泛存储权限。
- 事件链保持为：

  `REST/WS → 协议投影 → 串行 EventReducer → Session/Message/Log 状态 → Compose UI`

WebSocket 事件通过单一 Channel 顺序归并，避免多个协程并发修改会话。保留现有 single-flight、connection generation、指数退避、历史快照校准和断线重订阅规则。

### Android 16/17 视觉规范

基于 [Material 3 Expressive](https://developer.android.com/develop/ui/compose/designsystems/material3) 和 [Material Adaptive](https://developer.android.com/develop/ui/compose/build-adaptive-apps)，采用克制、扁平的 Material 风格：

| 场景 | Android 实现 |
| --- | --- |
| 手机主导航 | Material Navigation Bar；进入会话详情后隐藏 |
| 中等宽度 | Navigation Rail + 列表/详情双栏 |
| 平板/大窗口 | 项目与会话列表 + 对话 + Inspector 三栏 |
| 新建会话 | FAB 或顶部主要操作 |
| 低频选项 | Modal Bottom Sheet、Dropdown Menu |
| 危险确认 | Material AlertDialog，明确动作对象与后果 |
| 临时结果 | Snackbar；阻断错误保留页面内错误态 |
| Inspector | 大屏固定 supporting pane，手机使用全屏或底部 Sheet |

视觉规则：

- 默认启用 Material You 动态色；保留 Codex、GitHub、Xcode、Gruvbox 四套固定主题。
- 保留系统/浅色/深色、85%–135% 字号、系统/圆体/衬线字体选择。
- 代码字体替换为 Android System Mono 与开源 Roboto Mono。
- 使用纯色和 tonal surface；阴影只用于弹层、FAB 等瞬时层级，不复刻 iOS 毛玻璃。
- 支持 edge-to-edge、IME 动画、预测返回、分屏实时缩放和折叠屏铰链避让。Android 16 已强制推进 edge-to-edge 和预测返回适配。[Android 16 行为变更](https://developer.android.com/about/versions/16/behavior-changes-16)

### 网络与安全接口

后端公开接口不做破坏性修改，Android 复用现有 REST、25 个 app-server client method 和全部 7 类审批/用户输入反向请求。

- 继续支持 `mimiremote://connect?...` 与 `mimiremote://pair?...`，Android 注册对应 Intent Filter。
- Android 17 私网连接前按需申请 `ACCESS_LOCAL_NETWORK`；拒绝后不清空档案，展示授权说明和系统设置入口。[Android 17 局域网权限](https://developer.android.com/privacy-and-security/local-network-permission)
- 公网 HTTP 在输入校验、REST client、WebSocket client 三层拒绝；私网/Tailscale HTTP 保持兼容，长期优先迁移到 MagicDNS HTTPS。
- Token 不进入 DataStore、日志、通知、崩溃信息或备份；密钥使用 [Android Keystore](https://developer.android.com/privacy-and-security/keystore)。
- 多台 Mac 独立加密 Token，同一时间只允许一条活动连接；切换时先验证新档案，再原子提交并退役旧连接。
- 401/鉴权型 403 终止重试；普通业务 403 不误删凭据。
- 通知 payload 只保存版本、profile/project/session ID，不保存 Token 或明文 Endpoint。

## 功能清单

| 领域 | 必须迁移的能力 |
| --- | --- |
| 连接 | QR 配对、手动地址/Token、连接链接、多 Mac 档案、重命名/切换/删除、连接测速、readyz、首次 45 秒和已有档案 10 秒恢复、弱网与前后台恢复 |
| 会话 | 列表、即时搜索、Codex 全文搜索与分页、新建/恢复、历史分页、重命名、压缩、fork、archive/unarchive、本地 pin、提醒、Review、goal |
| 对话 | 流式输出、steer、interrupt、审批、用户问题表单、持久权限确认、排队消息编辑/删除/恢复、模型/推理强度/权限/发送模式、Skills、插件引用 |
| 内容 | 富 Markdown、表格、任务列表、代码复制、`proposed_plan`、图片输入与历史图片、文件引用、安全文件读取、图片/文本/PDF 内置预览及外部打开 |
| 语音 | Codex 录音上传转写、波形、最短时长、失败重试；Android 31+ 在设备支持时提供实时设备语音输入，其他设备保留 Codex 模式 |
| 工作区 | 项目列表、目录浏览、打开授权目录、Codex/Claude 新会话、Managed Worktree 创建、分支选择、列表、受保护删除、prune、30 天清理预览和部分成功处理 |
| Inspector | 会话状态、目标、上下文、活动、日志、diff、审批；Git 文件/hunk stage、unstage、revert、commit、push、草稿 PR、PR 状态、Quick Publish、远程 TestFlight action |
| 工具 | allowlist command action、确认、FIFO 队列、输出历史；Skills/MCP 只读发现，不增加配置写入 |
| 设置 | 中英文/跟随系统、外观、默认权限、保持屏幕常亮、Codex/Claude 用量、Developer Mode、Doctor、能力检查、开源许可、隐私/条款/支持 |
| 平台 | 本地提醒、运行完成/失败/审批通知、通知点击路由、相机/麦克风/通知/局域网权限拒绝恢复、深浅色、TalkBack、外接键盘和大字体 |

Claude 通道继续保持实验状态，并保留 goal、archive、fork 等现有能力限制，不在 Android 端伪造缺失功能。

## 实施阶段

### 阶段 0：冻结基线与契约，1–2 周

- 建立 `docs/android-feature-parity.md`，给每项功能分配状态、测试编号和 iOS 参考入口。
- 只统计当前真正可达的产品功能，排除遗留但未接入导航的 SwiftUI 视图。
- 将脱敏 REST 响应、JSON-RPC 事件流、审批流、历史流整理到共享 `testdata/mobile-contract/`。
- 共享 fixture 同时由 Go、Swift、Kotlin 测试消费，协议漂移时 CI 直接失败。
- 确认 Play Console 账号、`com.gaixianggeng.mimi` 包名、开发者验证、应用签名和 GPL/第三方许可边界。

完成门禁：Android 工程可构建；中英文、主题、导航壳和协议模型测试可运行。

### 阶段 1：连接和最小对话闭环，3–4 周

- 完成安全存储、QR/链接/手动配对、多档案、局域网权限和连接状态机。
- 完成项目加载、会话列表、新建/恢复、WebSocket 初始化、普通消息、流式回复、interrupt。
- 实现手机单栏和大屏基础双栏，形成第一个可真实连接 Mac 的内部构建。

完成门禁：Android 真机可从扫码到完成一轮 Codex 对话；离线、重连和凭据失效均有确定行为。

### 阶段 2：完整会话与内容系统，4–5 周

- 迁移历史同步、搜索/分页、事件投影、timeline、富 Markdown、图片、文件预览。
- 迁移审批、用户问题表单、goal/plan/review、排队消息持久化、模型与权限选择。
- 迁移 Codex/设备语音、通知和会话提醒。

完成门禁：共享事件 fixture 在 iOS/Android 得到相同消息、状态和审批结果；长会话、流式输出期间 Composer 保持可编辑。

### 阶段 3：工作区、Worktree、Git 与 Inspector，4–5 周

- 完整迁移目录、项目、Worktree 生命周期和所有删除保护。
- 完成 Inspector 三个分区、Git 文件/hunk 操作、commit/push/PR、command action 和日志导出。
- 实现大屏三栏、手机 Inspector Sheet，并保证窗口缩放时状态不丢失。

完成门禁：Worktree 计划过期、blocker、部分成功；Git revert、push、PR 失败等风险路径均有自动化或真机验收。

### 阶段 4：设置、诊断和 Android 设计打磨，2–3 周

- 完成用量、主题、字体、Doctor、Capabilities、许可与法律文档。
- 统一 Material 组件、动态色、图标、间距、动效、预测返回、键盘和 edge-to-edge。
- 补齐 TalkBack、200% 字号、横竖屏、折叠/展开和运行时语言切换。

完成门禁：手机、平板、折叠屏不出现不可返回页面、内容遮挡、键盘覆盖 Composer 或危险操作误触。

### 阶段 5：全量回归与 Play 内测，2–3 周

- PR CI：`lint`、单元测试、协议 fixture、Debug 构建、Compose UI 测试。
- Nightly：API 29/31/36/37 手机和 API 37 平板/折叠屏模拟器矩阵。
- 真机：至少一台 Pixel、一台三星手机、一台 Android 平板。
- 生成签名 AAB，完成 Play Data Safety、隐私政策、开源许可和 Internal Testing 发布。
- Parity 清单全部通过后才进入公开发布评估。

## 验收与风险

### 核心验收场景

- 新档案提交失败不影响旧 Endpoint、Token、会话和 WebSocket。
- 网络恢复只重连一次；401/鉴权 403 停止重试；未知 Notification 不导致断线。
- 大历史首屏不被图片阻塞；切回会话先校准状态再恢复监听。
- 500 字连续输入和持续流式输出不产生明显卡顿。
- 日志内部最多 120000 字符、界面最多渲染 80000 字符；文件保持 20MB、语音 12MB、队列 64MB 上限。
- Worktree 删除没有 force 入口，执行前必须复核 `plan_id`、精确路径和服务端最新状态。
- 公网 HTTP、越权文件路径、跨 Mac 通知自动切换全部失败关闭。
- Android 10 可完成核心闭环；Android 16/17 完整支持 edge-to-edge、预测返回、大屏窗口和局域网权限。

### 主要风险及控制

- iOS 持续变化：冻结基线，新增需求必须同时更新 parity 表和共享 fixture。
- Android 17 私网权限影响主链路：首配时解释并按需申请，拒绝后提供可恢复路径。
- 私网 HTTP 长期兼容风险：保留现有 Tailscale IP 能力，同时将 MagicDNS HTTPS 作为后续网络演进方向。
- Android 设备语音能力不统一：只有确认支持 on-device recognition 时才展示，默认始终保留 Codex 转写。
- 后台限制：不增加常驻前台服务，不承诺离线 push；行为与当前 iOS 的前台连接、本地提醒边界一致。
- Material 组件更新快：只使用稳定版 API，不为追逐 Android 17 视觉引入 alpha 依赖。

### 默认决策

未收到额外选择时采用以下默认决策：手机+平板同步首发、Android 10+、分阶段 Play 内测、Material You 默认且保留四套固定主题、SwiftUI/Compose 双原生独立实现、全功能对等后再公开发布。
