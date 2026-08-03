# 本地自动发布 Mimi TestFlight

## 目标

iOS 的日常 Nightly 由 GitHub Actions 每天从最新 `main` 上传 Internal TestFlight；本页的 `git testflight-push` 保留为维护者的本地、手工和恢复入口。它会先推送 `main`、核对远端 SHA，再从该 commit 创建干净 worktree，在本机完成 build number 预检、签名 Archive、上传和 `咪咪 Internal` 分发。

正式 iOS 候选仍通过 iOS CI 手工 dispatch；Mac、agentd 和 Windows 正式版本仍由维护者推送 `v*` tag。Nightly 不执行 App Store 审核或公开上架。公开二进制、Go/iOS CI 和协议检查继续由 GitHub workflows 负责。

## 配置

仓库内配置位于 `config/release/ios-testflight.local.env`。本机 Secrets 位于：

```text
~/.config/ios-testflight/mimi/secrets.env
```

首次配置：

```bash
mkdir -p "$HOME/.config/ios-testflight/mimi"
cp config/release/ios-testflight.secrets.example \
  "$HOME/.config/ios-testflight/mimi/secrets.env"
chmod 600 "$HOME/.config/ios-testflight/mimi/secrets.env"
./scripts/install_git_testflight_push.sh
```

MIM-78 引入 Widget Extension 后，Apple Developer 还必须先完成：

1. 注册 App Group `group.com.gaixianggeng.mimi`。
2. 注册 Widget App ID `com.gaixianggeng.mimi.carstatuswidget`，并让主 App 与 Widget App ID 都启用该 App Group。
3. 重新生成主 App 的 App Store profile，并新建 Widget App Store profile。
4. 将重新生成的主 App profile ID/name 更新到 `IOS_PROVISIONING_PROFILE_ID`、`IOS_EXPECTED_PROVISIONING_PROFILE_NAME`，并将 Widget profile 的真实 ID/name 写入已注释的 `IOS_WIDGET_PROVISIONING_PROFILE_ID`、`IOS_WIDGET_EXPECTED_PROVISIONING_PROFILE_NAME`；也可在本机 Secrets 中使用对应的 profile path 临时覆盖。

配置未完成时，`git testflight-push --check` 会明确失败；不要用主 App profile 代替 Widget profile。

## 使用

先做无副作用预检：

```bash
git testflight-push --check
```

预检会验证当前分支、已提交的项目配置、发布入口、本机 Secrets、证书/ASC Key 文件、Keychain 密码条目和 Xcode 等命令依赖；不会 push、Archive 或上传。Mimi 客户端的 TestFlight 按钮以该检查结果为准，未通过时只展示失败原因，不允许发布。

签名、Archive 和 Apple 服务端验证，但不上传：

```bash
./scripts/ios_testflight_local.sh \
  --dry-run \
  --ref HEAD \
  --what-to-test '本地验证，不上传。'
```

推送成功后自动发布：

```bash
git testflight-push \
  --what-to-test '验证 iPad 连接、项目、会话、日志和审批链路。'
```

普通 `git push` 只推送，不发布。标准 Git 没有客户端 `post-push` hook，因此使用显式包装命令保证“远端成功后才上传”。

客户端快捷发布的执行顺序是：用户确认 → 暂存当前授权工作区 → commit → 普通 push。TestFlight 是第二个独立确认动作，启动后由主机后台任务执行；关闭客户端页面不会中断发布，重新进入“变更”页会继续读取任务状态。

## 风险与恢复

- push 失败不会上传；Apple 阶段失败后可对同一 commit 重新执行。
- 同一 commit 成功状态保存在 `~/Library/Application Support/ios-testflight-local/mimi/`，默认防止重复上传。
- 主工作区的未提交内容不会进入构建；发布来源始终是明确 commit。
- 本机必须在线、解锁，并安装配置指定的 Xcode 与有效签名材料。
- `agentd` 重启会丢失内存中的任务展示状态；发布是否已经结束应从 `~/Library/Logs/ios-testflight-local/<project-id>/` 和 last-run 状态文件恢复核对，确认后再决定是否重试。
