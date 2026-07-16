# APP 全场景截图采集清单

## 采集结论

- 正式 PNG 共 **23 张**：iPhone 竖屏 11 张、iPhone 横屏 3 张、iPad 竖屏 6 张、iPad 横屏 3 张。
- 运行时为 iOS 27.0；本轮使用的设备为 iPhone 17 Pro（`D691649B-B7D0-4CE6-AAC6-F6E094EDE959`）和 iPad Pro 11-inch (M5)（`27BC11EC-0E5B-40B1-B3CD-CEF37BFF7687`）。未创建新模拟器。
- 运行、构建和每个方向切换后的即时截图均调用 Build iOS Apps 插件的 XcodeBuildMCP；交互使用已启动模拟器的 serve-sim / in-app browser 坐标 fallback；正式 PNG 使用同一真实模拟器 framebuffer 的原始分辨率导出，并用 `sips`/`file` 复核。
- iPadOS 27 的右下角窗口缩放把手是真实 windowed UI，不是浏览器叠加层；相关文件使用 `windowed` 命名并在下表注明。正式图不含浏览器工具栏、鼠标提示或系统桌面。
- 文件名含 `debug-seeded` 的图片均由现有 `--debug-skip-pairing --debug-seed-ui` 入口到达，只证明本地 UI 状态，不代表真实后端已连接。连接页中的“Debug 进入工作台”是 Debug 构建本身的可见入口，已如实标注，未冒充生产连接页。
- 未修改业务代码、工程配置、测试代码或依赖；未提交、未推送。

## 逐文件产物与实际状态

### iPhone

| 方向 | 场景 | 文件名 | 尺寸 | 进入步骤与实际状态 |
|---|---|---|---|---|
| 竖屏 | 相机权限 | `iphone-connection-camera-permission-prompt.png` | 1206×2622 | 连接页 → 扫描二维码；系统相机权限请求，未使用外部凭据。 |
| 竖屏 | QR 扫码不可用 | `iphone-connection-qr-sheet-unavailable.png` | 1206×2622 | 允许相机后进入扫码 Sheet；显示设备无可用相机的错误提示。 |
| 竖屏 | 手动连接展开 | `iphone-connection-manual-expanded.png` | 1206×2622 | 连接页 → 手动连接；Endpoint/Token 表单展开且为空。 |
| 竖屏 | Endpoint 聚焦 | `iphone-connection-endpoint-focused.png` | 1206×2622 | 点击 Tailscale 地址字段；有焦点但模拟器通道未呈现键盘，未伪造键盘态。 |
| 竖屏 | 会话完成态 | `iphone-conversation-completed-debug-seeded.png` | 1206×2622 | `--debug-skip-pairing --debug-seed-ui` 启动；本地 seeded 完成会话与 Composer。 |
| 竖屏 | 会话列表有数据 | `iphone-sessions-list-debug-seeded.png` | 1206×2622 | Debug seed 后返回会话列表；显示 3 条本地 seeded 会话。 |
| 竖屏 | Workspace/Project | `iphone-workspace-projects-debug-seeded.png` | 1206×2622 | Debug seed → 工作区；显示 seeded 项目卡片与最近会话。 |
| 竖屏 | Settings 主页面 | `iphone-settings-main-debug-seeded.png` | 1206×2622 | Debug seed → 设置；显示 Mac 连接、额度、外观、诊断入口。 |
| 竖屏 | Appearance | `iphone-settings-appearance-debug-seeded.png` | 1206×2622 | 设置 → 外观；显示系统/浅色/深色和主题预览。 |
| 竖屏 | Doctor 错误 | `iphone-settings-doctor-error-debug-seeded.png` | 1206×2622 | 设置 → 高级 → 诊断与支持；显示诊断请求失败。 |
| 竖屏 | ThirdPartyNotices | `iphone-settings-third-party-notices-debug-seeded.png` | 1206×2622 | 设置 → 高级 → 开源许可；显示第三方许可正文。 |
| 横屏 | 连接页 | `iphone-landscape-connection-clean.png` | 2622×1206 | 无 seed 启动连接页，通过 serve-sim in-app browser 的真实 Rotate device；原始 framebuffer 宽高比为横屏。 |
| 横屏 | 会话列表/工作台 | `iphone-landscape-sessions-list-debug-seeded.png` | 2622×1206 | seeded 会话详情 → 返回；最后一次坐标点击后即时核验到会话列表。 |
| 横屏 | 会话详情 + Composer | `iphone-landscape-conversation-composer-debug-seeded.png` | 2622×1206 | seeded 会话详情；Composer 可见，未呈现键盘。 |

### iPad Pro 11-inch (M5)

| 方向 | 场景 | 文件名 | 尺寸 | 进入步骤与实际状态 |
|---|---|---|---|---|
| 竖屏 windowed | 未配置连接页（Debug build） | `ipad-portrait-windowed-connection-unconfigured-debug-build.png` | 1668×2420 | 无参数启动；连接页无配对数据但可见“Debug 进入工作台”；右下角为真实 iPadOS windowed 控件。 |
| 竖屏 windowed | QRCodeScannerSheet | `ipad-portrait-windowed-connection-qr-sheet.png` | 1668×2420 | 连接页 → 扫码 → 允许相机；显示“无法扫码/没有可用相机”提示及手动连接选项。 |
| 竖屏 windowed | 手动配置 | `ipad-portrait-windowed-connection-manual.png` | 1668×2420 | QR Sheet → 改用手动连接；手动配置 DisclosureGroup 展开。 |
| 竖屏 windowed | 会话列表有数据 | `ipad-portrait-windowed-sessions-list-debug-seeded.png` | 1668×2420 | `--debug-skip-pairing --debug-seed-ui` 启动后返回列表；显示 seeded 项目和最近会话。 |
| 竖屏 windowed | 会话完成态 | `ipad-portrait-windowed-conversation-completed-debug-seeded.png` | 1668×2420 | Debug seed 直接进入会话；显示完成消息和 Composer。 |
| 竖屏 windowed | Settings 主页面 | `ipad-portrait-windowed-settings-main-debug-seeded.png` | 1668×2420 | Debug seed → 设置；显示设置主入口。 |
| 横屏 windowed | 未配置连接页（Debug build） | `ipad-landscape-windowed-connection-unconfigured-debug-build.png` | 2420×1668 | iPad 真正切换到 `landscape_left` 后无参数运行；连接页可见“Debug 进入工作台”和真实 windowed 控件。 |
| 横屏 windowed | 会话详情 + Inspector | `ipad-landscape-windowed-conversation-inspector-debug-seeded.png` | 2420×1668 | Debug seed 后真实切换到 `landscape_left`；会话与右侧 Inspector overview 同屏。 |
| 横屏 windowed | Sidebar + Inspector 工作台 | `ipad-landscape-windowed-workbench-sidebar-inspector-debug-seeded.png` | 2420×1668 | 在上述横屏会话中打开 Sidebar；左侧 Sidebar、中间会话、右侧 Inspector 同屏。 |

## 第四轮返工记录

- P0 文件 `iphone-open-workspace-sheet-error-debug-seeded.png` 已立即删除。逐张复核确认其实际画面属于其他 App 的“浏览/宠物卡片”页面，不属于 Mimi Remote。
- 已重新以 Mimi Remote seeded 会话尝试进入 Workspace → OpenWorkspaceSheet；重拍过程中 serve-sim 画面先出现方向/启动异常，随后 XcodeBuildMCP screenshot 与 simctl 截图通道持续超时。按停止指令未继续重置或创建模拟器，因此真正的 Mimi Remote OpenWorkspaceSheet 本地后端不可达错误态本轮仍未覆盖。
- 本轮未执行 Endpoint/Token + 软件键盘、无效地址测试连接 loading、测试失败、Composer 聚焦 + 软件键盘避让；没有伪造或沿用错误截图。
- iPhone 横屏连接页底部说明的截断保留原样，属于现有横屏布局表现；未裁切、拼接或修改代码修复。

## A-D 应有矩阵、已覆盖与未覆盖

### A. 连接闭环

- 已覆盖：iPhone 竖屏相机权限、扫码不可用、手动配置、Endpoint 聚焦；iPad 竖屏未配置连接页、扫码不可用、手动配置；iPhone 横屏连接页和 iPad 横屏未配置连接页。
- 未覆盖：Endpoint/Token 键盘态、测试连接进行中/失败、保存进行中/失败、真实已连接、忘记凭据确认框、disconnected/reconnecting/reconnect failed overlay。本轮这些纯 UI 状态未执行；真实连接状态另因没有仓库内可安全使用的后端凭据/服务而不伪造。
- 另外，`iphone-connection-qr-camera-starting.png` 与手动连接图内容完全相同，已删除重复文件；QR 不可用状态仍由 `iphone-connection-qr-sheet-unavailable.png` 和 iPad QR 图覆盖。

### B. 工作台与会话

- 已覆盖：iPhone/iPad 竖屏 seeded 会话列表、iPhone/iPad 竖屏 seeded 完成会话、iPhone 横屏 seeded 会话列表和会话+Composer、iPad 横屏 Sidebar/Inspector 工作台与会话详情、iPhone 工作区/项目。
- 未覆盖：OpenWorkspaceSheet 本地后端不可达错误（原错误图误截到其他 App，重拍时截图通道超时）、首次空态的独立原生分辨率重拍、搜索有/无结果、真实 streaming/tool activity、会话级 error、approval/user input、Composer 键盘态、Composer 手动输入/高级选项/附件/Goal Editor。未用裁切或 Debug seed 冒充这些状态。

### C. iPad 专属形态

- 已覆盖：iPad 横屏连接页、横屏会话详情、横屏 Sidebar 展开、SessionInspector/右侧 overview 同屏；竖屏和横屏均保留真实 iPadOS windowed 形态。
- 未覆盖：Inspector 的 activity/diff 分段、Composer 键盘态、可调整分屏尺寸对照。横屏 Inspector overview 已保存，其他分段没有安全、确定性的现有入口。

### D. 其他主要页面

- 已覆盖：Workspace/Project、Settings、Appearance、Doctor 错误、ThirdPartyNotices（iPhone 竖屏）；Settings 主页面（iPad 竖屏）；扫码不可用和 Doctor 错误可作为错误/提示代表图。
- 未覆盖：OpenWorkspaceSheet 错误态、LogPanel/日志、忘记凭据确认框；OpenWorkspaceSheet 因错误截图删除且重拍通道超时，其他分支没有安全的确定性入口。

## 方向覆盖矩阵

| 设备/形态 | 竖屏连接 | 竖屏工作台/列表 | 竖屏会话详情 | 横屏连接 | 横屏工作台/列表 | 横屏会话详情/Composer |
|---|---|---|---|---|---|---|
| iPhone | 部分：权限、QR 不可用、手动、Endpoint 聚焦 | 已覆盖 Debug seeded | 已覆盖 Debug seeded | 已覆盖原生 2622×1206 | 已覆盖 Debug seeded | 已覆盖 Debug seeded；Composer 可见、无键盘 |
| iPad Pro 11-inch (M5) | 已覆盖 windowed：clean、QR、手动 | 已覆盖 Debug seeded | 已覆盖 Debug seeded | 已覆盖 windowed 原生 2420×1668 | 已覆盖 Sidebar + Inspector | 已覆盖 Inspector overview；无键盘 |

横屏核验结果：所有文件名含 `landscape` 的 PNG 均满足 `width > height`，且尺寸为真实 framebuffer，不是旋转或裁切竖屏图。

## 方向工具检查与旋转尝试

### 只读工具检查

- `command -v idb`、`command -v applesimutils`、`command -v simctl` 均未发现独立工具；可用的是 `/usr/bin/xcrun`。
- `xcrun simctl help` 的 `ui` 子命令没有公开 orientation/rotate 选项。
- `npx --yes serve-sim@latest --help` 和 `serve-sim rotate --help` 暴露了 `portrait|portrait_upside_down|landscape_left|landscape_right`；只读检查未安装依赖、未修改工程。

### 具体路径结果

1. **iPad 路径成功**：`serve-sim rotate -d 27BC11EC-0E5B-40B1-B3CD-CEF37BFF7687 landscape_left`；随后立即调用 XcodeBuildMCP screenshot（800×551 优化回传）并导出原始 framebuffer，得到 2420×1668 的 3 张正式横屏图。
2. **iPhone 路径 1 失败**：直接执行 `serve-sim rotate -d D691649B-B7D0-4CE6-AAC6-F6E094EDE959 landscape_left`，原始错误为 `No serve-sim server running. Run 'serve-sim' first.`；该次截图仍为 1206×2622，未作为横屏图保存。
3. **iPhone 路径 2 成功**：启动已有设备的 serve-sim 端口 `3201`，通过 in-app browser 的精确 `Rotate device` 控件真实旋转；立即调用 XcodeBuildMCP screenshot（800×368 优化回传）并导出 2622×1206 原始 framebuffer，得到 3 张正式横屏图。成功后未再尝试第三条路径。

补充：按要求调用 XcodeBuildMCP `open_sim` 时原始错误为 `Unable to find application named 'Simulator'`；这不影响已启动模拟器和截图通道。iOS 27 beta 的 `snapshot_ui` 仍因缺少 `SimulatorKit.framework` 私有框架返回不可用，因此使用了插件允许的当前截图坐标 fallback，并在每次操作后截图核验。

## 最终验证

- PNG 总数：23；所有剩余文件均存在，`file` 与 `sips` 均验证为 PNG 和上述原生尺寸。
- 竖屏尺寸：iPhone 1206×2622；iPad 1668×2420。横屏尺寸：iPhone 2622×1206；iPad 2420×1668。
- 已删除：`_probe-iphone-raw.png`、首轮 368×800/551×800 优化图、`ipad-portrait-connection-clean-simctl.png`、旧的未精确命名连接图、与手动连接图完全重复的 `iphone-connection-qr-camera-starting.png`，以及误截其他 App 的 `iphone-open-workspace-sheet-error-debug-seeded.png`。
- 已逐张复核新增 iPad/iPhone 横屏画面及已有 iPhone 竖屏画面；未发现系统桌面、浏览器面板、鼠标提示或全黑帧。iPad 右下角 windowed 把手为真实系统 UI，已保留并标注。
