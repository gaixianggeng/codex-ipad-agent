# MIM-80 App Store 1.1 截图清单

## 目标

为 App Store Connect 版本 `1.1` 提供当前 App 界面的中英文截图，同时更新 GitHub README 使用的产品图片。

## 方案

- 设备：iPhone、iPad，共 2 组。
- 语言：`zh-Hans`、`en-US`，共 2 组。
- 页面：工作区、会话、会话列表、设置（可见 Token 使用量）、Mac 连接，共 5 张。
- 总数：`2 × 2 × 5 = 20` 张。
- `source/` 保存带介绍文案的源图；`upload/` 由脚本生成 App Store Connect 接受的尺寸。

每组按以下顺序上传：

1. `workspace.png`
2. `conversation.png`
3. `sessions.png`
4. `settings.png`
5. `mac-connection.png`

## 实现

- iPhone 源图统一为 `853 × 1844` RGB PNG，上传版为 `1242 × 2688`。
- iPad 源图统一为 `1086 × 1448` RGB PNG，上传版为 `2064 × 2752`。
- 中文 iPhone 工作区源图原先误用了会话画面，已单独替换为实体 iPhone 的工作区界面，并保持原有标题、背景与版式。
- 上传版由 `scripts/prepare-ios-store-screenshots.py` 等比缩放并在必要时补边，不裁切宣传文案，也不拉伸 App 界面。
- Manifest 记录每张上传图的尺寸、文件大小与 SHA-256，供上传前校验。

生成命令：

```bash
python3 scripts/prepare-ios-store-screenshots.py \
  --iphone-source artifacts/app-store/mim-80-submission/1.1/source/iphone \
  --ipad-source artifacts/app-store/mim-80-submission/1.1/source/ipad \
  --output-root artifacts/app-store/mim-80-submission/1.1/upload \
  --source-commit "$(git rev-parse HEAD)"
```

上传脚本默认只做只读预检；只有增加 `--apply` 才会写入 App Store Connect：

```bash
ruby scripts/ios_asc_publish_screenshots.rb \
  --bundle-id com.gaixianggeng.mimi \
  --version 1.1 \
  --screenshots-root artifacts/app-store/mim-80-submission/1.1/upload
```

App Store Connect 新建版本时可能继承上一版本截图。确认目标确实是可编辑的 `1.1` 后，正式上传需要显式增加 `--apply --replace-existing`；脚本会先删除 `1.1` 截图集中的继承图片，再上传清单内的 20 张新图。

## 风险与优化

- 截图按产品当前真实样式保留第三方 Runtime 名称与图标，不代表相关第三方背书；审核仍可能要求补充说明或替换素材。
- 所有项目路径、Token、Endpoint、Tailnet 地址和账户信息必须使用演示值，不得把真实隐私数据提交到 Git 或 App Store Connect。
- App Store Connect 中已上线的 `1.0` 截图不得修改；本清单只用于新的 `1.1` 版本。
- TestFlight 邀请页使用已批准 App Store 版本的产品页素材，因此 `1.1` 截图需要通过审核后才会反映到该预览。
