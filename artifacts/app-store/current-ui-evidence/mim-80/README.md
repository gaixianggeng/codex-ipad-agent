# MIM-80 当前界面截图证据

## 目标

记录 `origin/main` 在 MIM-80 验收时的真实 iPad 与 iPhone 界面，证明当前工作区、会话列表和完成态对话的运行效果。

这组图片的分类是 `current-ui-evidence`，**不是中国大陆 App Store 可上传素材**。现有 `china-mainland-screenshots/upload-ready/` 资产保持不变。

## 方案

- 源码基线：`e8c193242d3871beb9c1854aa6aef6bb01ec92cf`
- App：`com.gaixianggeng.mimi`
- Scheme / 配置：`MimiRemote` / `Debug`
- 启动参数：`--debug-skip-pairing --debug-seed-ui -app.language zh-Hans`
- 采集设备：iPad Pro 13-inch (M5)、iPhone 17 Pro
- 运行环境：Xcode 27.0 beta 4（`27A5228h`）、iOS 27.0 Simulator（`24A5390f`）
- 系统状态栏固定为 09:41、Wi-Fi 满格、电量 100%，界面使用浅色模式。

图片只包含 Debug 内存种子数据和 `/Users/demo` 示例路径，不连接真实后端，不包含真实账号、Token、私有地址或个人目录。

## 实现

- `ipad-13/`：三张 `2064 × 2752` 原始 framebuffer，覆盖工作区、完成态对话和会话列表。
- `iphone-17-pro/`：三张 `1206 × 2622` 原始 framebuffer，覆盖相同核心流程。
- `iphone-6.5-sized/`：iPhone 原图裁掉左上角 `4 × 4` framebuffer 伪影后，按高度等比缩放并补齐两侧极窄背景边，得到 `1242 × 2688` 尺寸验证样本；没有改写 App 内容。
- `manifest.json`：记录分类、来源、尺寸、文件大小和 SHA-256，供独立验收复核。

## 风险与优化

- 当前真实 UI 会展示 Codex、ChatGPT、Claude Code 和模型名称等第三方品牌信息，与仓库现行中国大陆商店截图规范冲突，因此 `uploadReady` 固定为 `false`。
- `testFlightReplacementReady` 同样固定为 `false`，避免把运行态证据误解为可直接替换 TestFlight 展示的素材。
- 不得把本目录图片上传到 App Store Connect，除非产品所有者先明确品牌展示政策并完成合规确认。
- TestFlight Invitation Experience 使用最新已批准 App Store 版本的截图；当前 1.0 已上架且 1.1 尚未创建，不能通过独立 beta 截图入口立即替换。
- 若后续需要中性品牌的商店截图，应另立 Issue 定义展示政策和 DEBUG-only 商店截图种子，不能后期抹除、AI 重绘或把证据图误标为可上传。

下一步允许的迁移顺序是：`current-ui-evidence` → 独立的 store-safe screenshot Issue → `upload-ready`；没有完成中间 Gate 时不得跳转。
