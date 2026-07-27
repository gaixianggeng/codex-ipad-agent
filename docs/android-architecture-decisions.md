# Android 架构决策

## 工具链锁定

| 项目 | 版本/决策 |
| --- | --- |
| Android Gradle Plugin | 9.3.0 |
| Gradle | 9.5.0 Wrapper |
| JDK | 17 |
| `minSdk` | 29 |
| `compileSdk` / `targetSdk` | 37 |
| Kotlin | AGP 9.3 内建 Kotlin；不应用 `org.jetbrains.kotlin.android` |
| Compose BOM | 2026.06.00 |
| Material 3 Adaptive | 1.2.0 stable |
| Navigation 3 | 1.1.4 stable |
| Lifecycle | 2.11.0 stable |
| DataStore | 1.2.1 stable |

依赖全部通过 version catalog 固定；禁止动态版本和 alpha 依赖。Kotlin Serialization 编译插件必须与 AGP 内建 Kotlin 版本匹配。

## 模块与包边界

首版使用单一 `:app` 模块，按以下 package 隔离职责：

- `app`：Application、Activity、依赖容器和顶层导航。
- `core.model`：REST、JSON-RPC 和产品领域模型。
- `core.network`：Endpoint 策略、REST、WebSocket、重连和协议投影。
- `core.security`：Keystore、Token 密文和备份排除。
- `core.storage`：非敏感 DataStore、档案元数据、草稿与队列。
- `feature.connection`、`feature.sessions`、`feature.conversation`、`feature.workspaces`、`feature.inspector`、`feature.settings`：屏幕与 ViewModel。
- `ui`：主题、Material 组件、自适应布局和可访问性约定。

只有网络、存储、时钟、通知和权限边界定义接口；其余使用具体类型，避免过早框架化。

## 状态与事件

事件链固定为：

`REST/WS -> protocol projection -> single-channel EventReducer -> immutable AppState -> Compose`

- 所有 WebSocket notification 和 server request 进入单一有序 Channel。
- Reducer 是会话、消息、审批、活动和日志状态的唯一写入口。
- 每次连接拥有 generation；旧 generation 的回调必须被丢弃。
- 重连使用 single-flight 和有界指数退避；401/鉴权型 403 立即终止。
- 历史恢复先应用快照并校准，再恢复实时订阅。

## 凭据与深链

- `mimiremote://pair` + 短期 `pair_sig` 是首选配对路径。
- 旧 `connect` 长期 Token 链接只用于显式兼容导入；展示来源和 Endpoint，用户确认后才保存，永不自动连接。
- 每个档案使用 Android Keystore AES-GCM 密钥；每条记录使用随机 96-bit IV，档案 ID 作为 AAD。
- 密文、IV 和版本写入 `noBackupFilesDir`，同时通过 Android backup/data extraction rules 排除。
- 密钥失效时仅删除对应失效档案的凭据并要求重新配对，不影响其他档案。

## 网络安全

- HTTPS 允许公网和私网；明文 HTTP 只允许 loopback、RFC1918、link-local、Tailscale CGNAT、ULA、`.local` 和解析到允许网段的 `.ts.net`。
- URL 禁止 user-info、fragment、非空 path 和未识别 scheme。
- REST 与 WebSocket 使用相同 Endpoint validator；每次连接和每次重定向都重新验证解析结果。
- 明文 HTTP 禁止跳转到公网地址；HTTPS 降级到 HTTP 必须拒绝。
- 文件路径、通知 profile/session 路由和 Worktree 删除全部 fail-closed。

## UI 设计基准

视觉基准位于 `android/design/android-ui-direction-v1.png`。实现原则：

- 手机使用 Material Navigation Bar；进入会话详情后让内容和 Composer 获得最大空间。
- 中宽窗口使用 Navigation Rail 与列表/详情双栏；大屏使用项目/会话、对话、Inspector 三栏。
- 默认 Material You 动态色，使用纯色和 tonal surface；阴影只用于 FAB、Dialog、Sheet 等瞬时层。
- 所有布局 edge-to-edge，正确处理状态栏、导航栏、IME、预测返回、横竖屏和铰链。
- 触控目标至少 48dp；核心流程必须支持 TalkBack、外接键盘和 200% 字号。

