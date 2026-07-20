# Mimi Remote App Store 提交材料

## 目标

本目录保存可复制到 App Store Connect 的中英文元数据和审核说明，确保商店描述、App 实际能力、隐私政策与审核环境保持一致。

## 方案

- App 名称：`Mimi Remote`
- 主类别：`Developer Tools / 开发者工具`
- 版本：`1.0`
- 下一个发布构建下限：`100048`；正式归档仍由发布脚本查询 App Store Connect 后选择唯一构建号。
- 隐私标签：开发者不收集数据；提交前必须按实际新增能力重新核对。
- 价格：免费；当前不包含订阅、AI 额度或其他数字商品内购。

公开 URL：

- Marketing URL：<https://github.com/gaixianggeng/mimi-remote>
- Privacy Policy URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/privacy-policy.md>
- Support URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/support.md>
- Terms URL：<https://github.com/gaixianggeng/mimi-remote/blob/main/docs/terms-of-use.md>

## 实现

- `en-US/` 与 `zh-Hans/`：名称、副标题、推广文本、关键词、描述和版本说明。
- `app-review-notes.md`：提交到 App Review Information 的英文说明模板。
- `review-environment-checklist.md`：审核专用 Mac 的最小安全闭环。

提交时必须把模板中的占位符替换成审核专用值；Token、真实 Endpoint、电话号码和个人项目路径不得提交到 Git。

## 风险与优化

- GitHub 文档是当前最低维护成本方案。正式上架后可迁移到自有域名，但应先保证新旧 URL 都能长期访问。
- App Store 截图必须展示真实 App 使用界面，不应只展示连接页或宣传图。
- Claude Code 是用户在 Mac 上自行启用的可选实验通道，商店描述与审核备注必须披露，但不得暗示 Mimi Remote 提供 Claude 服务或订阅。
- 中国大陆可用性由 App Store Connect 地区选择和 Apple 审核结果决定；本文档不替代适用法律的专业意见。
