# MIM-80 实体设备截图

## 目标

保存当前 App 的实体 iPhone 与实体 iPad mini 截图，覆盖工作区、绘画区（会话详情）、会话列表、设置和 Mac 连接，并分别保留简体中文与英文版本。

## 方案

- 设备：已连接的实体 iPhone 与实体 iPad mini。
- 语言：通过 Debug 启动参数注入中文或英文演示数据；英文工作区使用单独的英文种子内容。
- 数据：Mac 连接页只使用脱敏的演示 Mac 名称、IP 和 DNS，不包含真实访问码或账号信息。
- 输出：只保留 App 画面，去掉 Device Hub 电脑窗口外框；PNG 为 RGB，无透明通道。

## 实现

目录结构：

```text
physical/
├── iphone/{zh-Hans,en-US}/
└── ipad-mini/{zh-Hans,en-US}/
```

每个语言目录包含：

- `workspace.png`：工作区
- `conversation.png`：会话详情/绘画区
- `sessions.png`：会话列表
- `settings.png`：设置页，包含 Token 使用量
- `mac-connection.png`：Mac 连接页，包含已保存 Mac 与当前连接状态

尺寸：

- iPhone：当前实体设备源图 1206×2622
- iPad mini：当前实体设备源图 1488×2266

## 风险与优化

- iPad mini 的实体分辨率不是 App Store 必需的 iPad 13 英寸上传尺寸；它用于真实设备验证和本地素材留存。App Store 上传版本仍需另外生成 2064×2752 的 iPad 13 素材。
- 英文截图的系统状态栏仍跟随实体设备当前系统语言，App 内容本身已切换为英文。
- 本目录是本地素材归档；若后续要提交 App Store，应使用 `scripts/prepare-ios-store-screenshots.py` 生成上传尺寸，并再次检查截图中的敏感信息。
