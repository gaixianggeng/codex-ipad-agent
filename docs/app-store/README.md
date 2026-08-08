# Mimi Remote App Store 提交材料

## 目标

本目录保存可复制到 App Store Connect 的中英文元数据和审核说明，确保商店描述、App 实际能力、隐私政策与审核环境保持一致。

## 方案

- App 名称：简体中文 `咪咪 Remote`；英文 `Mimi Remote`
- 主类别：`Developer Tools / 开发者工具`
- 版本：`1.1`
- 下一个发布构建下限：`100068`；正式归档仍由发布脚本查询 App Store Connect 后选择唯一构建号。
- 隐私标签：开发者不收集数据；提交前必须按实际新增能力重新核对。
- 价格：免费；当前不包含订阅、AI 额度或其他数字商品内购。
- 中国大陆：本版本按“用户自托管开发工作台”准备。MIM-80 的 1.1 截图按当前真实界面提交，允许出现用户实际可选的第三方 Runtime 名称与图标；商店文案与免责声明必须保持独立第三方定位，不暗示 OpenAI、Anthropic 或其他服务商背书。

公开 URL：

- Marketing URL：首个中国大陆版本留空，避免把 README 中的开发者兼容性说明误当作商店宣传元数据。
- Privacy Policy URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/privacy-policy.md>
- Support URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/support.md>
- Terms URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/terms-of-use.md>

## 实现

- `en-US/` 与 `zh-Hans/`：名称、副标题、推广文本、关键词、描述和版本说明。
- `app-review-notes.md`：提交到 App Review Information 的英文说明模板。
- `review-environment-checklist.md`：审核专用 Mac 的最小安全闭环。
- `china-mainland-submission-checklist.md`：中国大陆地区合规、账号和 App Store Connect 核对清单。

提交时必须把模板中的占位符替换成审核专用值；Token、真实 Endpoint、电话号码和个人项目路径不得提交到 Git。

## 风险与优化

- GitHub 文档是当前最低维护成本方案。正式上架后可迁移到自有域名，但应先保证新旧 URL 都能长期访问。
- App Store 截图必须展示真实 App 使用界面，不应只展示连接页或宣传图。
- MIM-80 截图保留 App 内真实的 Runtime 名称与图标，这是当前确认的提交策略；审核仍可能要求补充授权说明或调整素材。公开商店元数据继续使用中性的功能描述，并明确不隶属或受第三方背书。
- 中国大陆可用性还取决于账号主体信息、可能适用的 App/ICP 备案以及 Apple 审核结果；本文档不替代适用法律的专业意见。
