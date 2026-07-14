# 本地自动发布 Mimi TestFlight

## 目标

iOS 内测不再依赖 GitHub Actions。`git testflight-push` 会先推送 `main`、核对远端 SHA，再从该 commit 创建干净 worktree，在本机完成 build number 预检、签名 Archive、上传和 `咪咪 Internal` 分发。

公开二进制、Go/iOS CI 和协议检查仍保留原 GitHub workflows；这里只替换 Mimi TestFlight。

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

## 使用

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

## 风险与恢复

- push 失败不会上传；Apple 阶段失败后可对同一 commit 重新执行。
- 同一 commit 成功状态保存在 `~/Library/Application Support/ios-testflight-local/mimi/`，默认防止重复上传。
- 主工作区的未提交内容不会进入构建；发布来源始终是明确 commit。
- 本机必须在线、解锁，并安装配置指定的 Xcode 与有效签名材料。
