# Nightly 与正式发布

## 目标

`main` 有新提交时，每天北京时间 02:30 自动给官方仓库生成一个 Internal TestFlight Nightly；正式发布仍由维护者明确触发。Nightly 只服务于内测，不代表 App Store 审核或公开上架。

## 方案

- Nightly workflow 先在无签名凭证的步骤中确认官方仓库、`refs/heads/main`、事件 SHA、checkout 的 `HEAD` 与最新 `origin/main` 完全一致。
- 同一 SHA 已有成功 Nightly 时，普通定时或手工触发只做成功的 skip；需要重发时手工选择 `force_publish`。
- 发布 job 复用 iOS CI 的归档、签名和 `ios_testflight_ci.sh`，成功后保存 `nightly-testflight-<SHA>` evidence artifact 30 天。
- 正式 iOS 候选通过 iOS CI 的 `workflow_dispatch` 和 `publish_app_store` 手工触发；正式 Mac、agentd、Windows 仍由维护者在当前 `main` 上创建并推送 `v*` tag，沿用现有 Release workflow。

## 实现

Nightly 的 What to Test 只包含北京时间日期、短 SHA 和清洗后的 commit title。App 的 marketing version 与 host 的 `v*` 版本线独立；build number 继续由 App Store Connect 预检分配。Windows 签名和真实 Runtime 不属于 Nightly 的阻塞链路。

## 风险与优化

- 同一 SHA 的并发运行由固定 concurrency 串行化；已有成功 Nightly run 时默认跳过。如果上传完成后 caller 的最终汇总因基础设施故障失败，也只接受同时绑定原 Nightly workflow run、head SHA 和 evidence JSON 的 artifact，不能仅凭同名 artifact 跳过。Apple 处理或签名凭证失败时，由维护者检查日志后选择 `force_publish` 重试。
- Nightly 不会替代本地恢复入口；需要指定 commit 或离线排查时，继续使用 [`git testflight-push`](local-testflight.md)。
- 当前不包含 App Store 审核、公开上架、rollback attestation 或额外 ASC 编排；真实需求出现后再单独评估。
