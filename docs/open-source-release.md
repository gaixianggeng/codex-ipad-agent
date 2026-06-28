# 开源发布流程

## 目标

本项目的公开仓库是 [gaixianggeng/mimi-remote](https://github.com/gaixianggeng/mimi-remote)。公开发布的目标是只暴露可维护、可运行、可协作的最小代码集：

- Go 后端 `agentd`
- 原生 iOS App `Mimi Remote`
- 必要的 README、许可证、安全说明、隐私政策、贡献指南和发布配置

私有开发仓库可以继续保留历史、实验记录和本地工作流，但这些内容不应该进入公开仓库。

## 方案

不要直接把私有开发仓库改成 public。

原因很简单：私有仓库里通常会有旧 `main`、历史分支、实验代码、内部设计文档、构建产物、设备配置或已经删除但仍在 Git 历史中的内容。直接改成 public 会把这些历史引用一起暴露，清理成本高，也容易漏。

推荐方案是：

1. 在私有开发仓库里创建一个 orphan 分支作为公开起点。
2. 只恢复和提交公开需要的文件。
3. 把有价值但不适合公开的本地内容放进 `.gitignore`。
4. 对公开树做脱敏、命名和构建验证。
5. 新建干净 public repo，把 orphan 分支推成公开仓库的 `main`。

这个方案的好处是公开仓库没有私有历史，后续维护也清楚：私有仓库负责日常开发和实验，公开仓库只接收确认过的干净提交。

## 实现

### 1. 公开内容边界

公开仓库应保留：

- `cmd/agentd`
- `internal/`
- `ios/MimiRemote/`
- `.github/`
- `README.md`
- `LICENSE`
- `NOTICE.md`
- `SECURITY.md`
- `CONTRIBUTING.md`
- `config.example.json`
- `docs/ip-and-brand-policy.md`
- `docs/privacy-policy.md`
- `docs/production-reachability-audit.md`
- `scripts/deploy-ipad.sh`
- `.goreleaser.yml`
- `go.mod` 和 `go.sum`

不公开、但可以保留在本地的内容：

- `.codex/`
- `openspec/`
- `.claude/`
- `bin/`
- `build/`
- `ios/MimiRemote/build/`
- `ios/MimiRemote/build-test/`
- 私有规划文档，例如 `docs/release-plan.md`
- 内部重构和评审草稿，例如 `docs/codex-app-server-runtime-refactor.md`

这些路径需要写进 `.gitignore`，避免以后误提交。

### 2. 命名规则

公开项目统一使用：

- 产品名：`Mimi Remote`
- 仓库名：`mimi-remote`
- Go module：`github.com/gaixianggeng/mimi-remote`
- iOS target / scheme：`MimiRemote`
- iOS bundle id：`com.gaixianggeng.mimi`
- URL scheme：`mimiremote://`
- Homebrew formula：`mimi-remote`

不要在公开文档、代码标识或测试 fixture 中继续使用旧项目名。

### 3. 脱敏检查

提交前至少检查这些内容不能进入公开树：

- Apple Team ID
- 真实设备名
- 真实设备 UDID
- 私有 Tailscale IP
- 本机绝对路径
- 私有 token、GitHub token、OpenAI key、SSH 私钥
- 固定到个人机器的 SDK 版本
- 私有设计文档和本地自动化状态

推荐检查命令：

```bash
git grep --cached -n -I -E \
  '(AKIA|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY|DEVELOPMENT_TEAM =|DEVICE_ID=|iphoneos[0-9]+\.[0-9]+)'
```

提交前还要按本机实际情况临时追加扫描项，例如真实设备名、真实 UDID、私有 Tailscale IP、本机用户名和内部文档标题。如果有命中，先判断是不是测试 fixture 或公开占位；否则必须清理后再提交。

### 4. 本地验证

公开提交前必须验证后端和 iOS 都还能构建：

```bash
go test -p 1 ./...

xcodebuild -list \
  -project ios/MimiRemote/MimiRemote.xcodeproj

xcodebuild \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build
```

再做一次 diff 检查：

```bash
git diff --cached --check
git status --short --ignored
```

`git status --ignored` 里看到本地构建产物、`.codex/`、`openspec/` 等被 ignore 是正常的。

### 5. 创建公开仓库

公开仓库只接收干净提交，不接收私有仓库历史。

首次创建：

```bash
gh repo create gaixianggeng/mimi-remote \
  --public \
  --description "Mimi Remote: iPad remote control for local Codex environments"

git remote add public git@github.com:gaixianggeng/mimi-remote.git
git push public HEAD:main
```

后续从私有开发仓库同步公开提交时，仍然推到 `public/main`：

```bash
git push public HEAD:main
```

除非明确需要同步私有仓库里的公开分支，否则不要把开源整理提交反推回 `origin`。

## 风险与优化

主要风险：

- 误把私有仓库直接改成 public，导致历史分支和旧提交暴露。
- 误提交本地自动化状态、内部设计草稿或构建产物。
- 文档和代码名不一致，导致用户安装、Homebrew、iOS scheme 或 URL scheme 混乱。
- 公开仓库推错 remote，把干净提交推回私有仓库或把私有分支推到 public。

控制方式：

- 公开仓库使用独立 remote：`public`。
- 每次公开前先跑脱敏扫描和构建验证。
- `.gitignore` 只保留明确本地用途的目录，不靠“记得不要 add”。
- 文档、Go module、iOS target、bundle id、Homebrew formula 和 URL scheme 同步改名。
- 大改动先在 orphan 分支验证，通过后再推 `public/main`。

后续可以优化：

- 加一个 `scripts/check-public-release.sh`，把旧名扫描、敏感信息扫描、Go 测试和 iOS build 串起来。
- 在 GitHub Actions 里增加公开仓库专用检查，避免 PR 重新引入旧名或敏感占位。
