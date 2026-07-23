# 中国大陆 App Store 截图

## 目标

使用当前中国大陆提交代码生成不含真实账号、Token、私有地址、个人目录或第三方品牌图标的商店截图。

## 可直接上传

### iPhone 6.5 英寸

目录：`upload-ready/iphone-6.5/`

尺寸均为 `1242 × 2688`，建议顺序：

1. `iphone-6.5-workspace.png`
2. `iphone-6.5-conversation.png`
3. `iphone-6.5-sessions.png`

iPhone 原图来自 iPhone 17 Pro 的 `1206 × 2622` framebuffer。上传版仅裁掉模拟器边缘的 4px 截图瑕疵、补齐极窄背景边，并等比例缩放到 App Store Connect 当前接受的尺寸；未改写 App 内容。

### 13 英寸 iPad

目录：`upload-ready/ipad-13/`

尺寸均为 Apple 接受的 `2064 × 2752`，建议顺序：

1. `ipad-13-workspace-portrait.png`
2. `ipad-13-conversation-portrait.png`
3. `ipad-13-sessions-portrait.png`

## 布局验证

`ipad-mini-*.png` 是 iPad mini（A17 Pro）的 `1488 × 2266` 原始截图，用于检查紧凑 iPad 布局，不上传到当前 13 英寸 iPad 截图槽。

## 说明

- 截图使用 Debug 内存种子数据，不连接真实后端，不包含真实用户内容。
- 截图中的 `/Users/demo` 和 Token 占位符是专门准备的公开示例。
- 工作区入口使用“默认运行时 / 可选运行时”和中性的系统图标。
- 简体中文产品名统一为“咪咪 Console”。
- 正式构建若继续修改界面或商店名称，上传前必须重新截图。
