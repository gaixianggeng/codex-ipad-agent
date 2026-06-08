# Codex iPad Agent 发布方案

## 目标

把 `Codex iPad Agent` 作为个人兴趣开源项目发布出去，让用户可以用最少步骤完成：

1. 在 Mac 上安装并启动 `agentd`。
2. 在 iPad 上安装原生 App。
3. 扫码配对后，通过 iPad 连接自己的 Mac 上的 Codex app-server。

本阶段目标不是商业化，也不是做复杂 SaaS。优先级是：

- 可安装。
- 可解释。
- 可审核。
- 可回滚。
- 低维护成本。

首发额外目标：

- App Review 能独立理解 App，不强依赖审核员真的搭好 Mac 后端。
- 命名、商标、仓库身份和签名配置在提交前对齐，避免非功能性拒审或开源安装失败。

## 方案

### 发布形态

采用 **单仓库开源，双产物发布**：

| 产物 | 发布渠道 | 用户安装方式 | 说明 |
| --- | --- | --- | --- |
| `agentd` 后端 | GitHub Release + Homebrew | `brew install gaixianggeng/tap/codex-ipad-agent` | 运行在用户自己的 Mac 上，负责鉴权、项目 allowlist、app-server 启动和网关 |
| iPad App | App Store 免费发布 | App Store 下载 | 不走 TestFlight，直接正式提交审核 |
| 文档 | GitHub README + docs | GitHub 查看 | 说明安装、配对、安全边界和常见问题 |

暂时不拆分 iOS 和后端仓库。当前项目的产品体验天然是 “iPad App + Mac agentd”，单仓库可以减少版本兼容、issue 归属、文档同步和 release 对齐成本。

对外安装命令建议使用全限定 Homebrew formula：

```bash
brew install gaixianggeng/tap/codex-ipad-agent
```

README、App Review Notes 和快速安装路径都优先用全限定命令，减少短名解析歧义。需要解释 Homebrew tap 时，可以在补充文档里再展开。

### 是否走 TestFlight

本项目可以不走 TestFlight，直接提交 App Store。

原因：

- 这是个人兴趣项目，不需要先做大规模 beta 运营。
- TestFlight build 有有效期，长期分享反而增加维护成本。
- App Store 正式发布后，用户安装和更新体验更稳定。
- 如果不想公开搜索曝光，可以审核通过后申请 Unlisted App，只通过链接分享。

需要注意：不走 TestFlight 不等于不用审核。App Store 正式发布仍然需要 App Review。

如果不做离线演示模式，需要明确接受首提被 Guideline 2.1 或 4.2 拒绝 1-2 轮的概率，并预留 2-4 周沟通时间。更务实的首发策略是：提交前实现一个只读离线 demo，让审核员即使没有 Mac 后端，也能看到核心界面、会话流、日志、diff 和审批形态。

### 推荐发布顺序

```text
补齐发布前材料
  -> 实现离线演示模式
  -> 处理命名/IP/签名/仓库身份风险
  -> 发布 agentd v0.1.0
  -> 验证 Homebrew 安装链路
  -> 提交 iPad App 到 App Store
  -> 通过后公开 README 安装入口
  -> 可选：申请 Unlisted App
```

这个顺序的核心原因是：审核员和真实用户都需要一个可用的后端安装路径。先发布 `agentd`，再提交 iOS，审核说明会更完整。

## 实现

### 1. 发布前清单

必须补齐：

- [ ] `LICENSE`：建议 MIT，个人项目最省心。
- [ ] `SECURITY.md`：明确只建议本机、局域网或 Tailscale 使用，不要公网暴露 `agentd`。
- [ ] `Privacy Policy` 页面：App Store 必填，可以放在 GitHub Pages、README 固定链接或项目官网。
- [ ] 离线演示模式：审核员不安装 Homebrew、不登录 Codex、不连接你的 Mac，也能进入示例项目、示例会话、示例日志、示例 diff 和审批卡片。
- [ ] App Store 截图：至少覆盖设置页、扫码连接、项目列表、对话页、日志/审批页。
- [ ] App Review Notes：写清楚测试步骤和安全边界。
- [ ] 确认仓库、README、App 内文案都不要泄漏真实 Token、真实 Tailscale IP、私有路径或 Apple Team ID。
- [ ] 确认 `gaixianggeng/homebrew-tap` 已公开，且 `brew install gaixianggeng/tap/codex-ipad-agent` 可以在干净机器上成功。
- [ ] 统一 GitHub remote、Go module path、Go import path、GoReleaser homepage、README 和 App Review Notes 的仓库身份。当前推荐统一为 `github.com/gaixianggeng/codex-ipad-agent`。
- [ ] 首次提交 App Store 前定死最终 iOS Bundle ID。Bundle ID 上架后不可改，建议从旧身份 `com.gaixiaotongxue.CodexAgentPad` 迁移到最终公开身份，例如 `com.gaixianggeng.mimi`，并同步 `project.yml`、`project.pbxproj` 和 `scripts/deploy-ipad.sh`。

建议修正：

- [ ] `scripts/deploy-ipad.sh` 不要默认写死个人 `DEVELOPMENT_TEAM`，改成环境变量传入。
- [ ] `ios/CodexAgentPad/CodexAgentPad.xcodeproj/project.pbxproj` 不要写死个人 `DEVELOPMENT_TEAM`，否则外部贡献者用自己的证书构建会失败。
- [ ] README 里的真机部署示例不要出现个人 Team ID，只保留 `IOS_DEVELOPMENT_TEAM=YOUR_TEAM_ID` 这类占位符。
- [ ] README 中把“开发部署到我自己的 iPad”的说明和“普通用户安装”的说明分开，避免用户误以为必须自己签名。

### 1.1 离线演示模式

离线演示模式是首发必备项，不放到后续优化。

目标：

- 审核员不需要 Mac 后端也能验证 App 不是空壳。
- 新用户首次打开 App 时能理解最终工作台长什么样。
- 演示数据不包含真实路径、真实 Token、真实 Tailscale IP、真实对话或私有项目名。

最小实现：

- 设置页保留“扫码连接”和“手动输入 Endpoint/Token”。
- 未连接状态增加“查看演示”入口。
- 演示模式使用本地 fixture，展示：
  - 示例项目列表。
  - 示例历史会话。
  - 一段 assistant/user 消息流。
  - 一段日志输出。
  - 一个 diff 面板。
  - 一个审批卡片，按钮只改变本地演示状态，不调用后端。
- 演示模式顶部明确标记为 Demo，不要让用户误以为已连接真实 Mac。

不建议首发做复杂模拟器。只读 fixture + 少量本地状态足够，重点是让审核员看到最低可用功能。

### 1.2 命名和商标风险

`Codex` 是 OpenAI 产品名。第三方客户端如果在 App Name、图标、截图或描述里突出使用 `Codex`，可能触发 App Review 的知识产权风险。

发布前命名方案：

| 方案 | App Name | 风险 | 建议 |
| --- | --- | --- | --- |
| 首发推荐 | `Mimi` / `咪咪` | 低 | 有个人记忆点，避开 `Codex` 商标风险 |
| 说明型 | `Mimi for Mac Dev` | 低-中 | 名字更解释用途，但没那么干净 |
| 当前名 | `CodexAgentPad` | 高 | 不建议直接作为 App Store Display Name |

无论最终用哪个名字，都要加免责声明：

```text
This is an independent client for user-owned Mac environments. It is not affiliated with, endorsed by, or sponsored by OpenAI.
```

中文文案：

```text
本项目是独立开发的第三方客户端，不隶属于 OpenAI，也不代表 OpenAI 官方产品。
```

文案原则：

- 可以说明“连接用户自己 Mac 上的 Codex CLI / app-server”。
- 不要暗示 OpenAI 官方授权、官方客户端、官方移动端。
- App 图标、截图和描述不要使用 OpenAI 官方 Logo 或容易混淆的品牌元素。

身份边界：

- App Store Display Name 面向用户，可以首发改成 `Mimi`；中文本地化可以显示为 `咪咪`。
- Bundle ID 是 App Store 的永久技术身份，首次上架前必须定好，后续不要再改。
- Xcode scheme、target、product name 可以暂时保留 `CodexAgentPad`，它们主要影响工程内部，不必为了展示名做大范围重命名。

### 2. 后端发布

后端发布目标：

- GitHub Release 里有 darwin/linux、amd64/arm64 的 `agentd` tarball。
- Homebrew formula 可以安装。
- `agentd setup -> agentd start -> agentd doctor` 能完整跑通。

本地检查：

```bash
go mod tidy
go test ./...

CGO_ENABLED=0 go build \
  -trimpath \
  -ldflags "-s -w -X main.version=0.1.0-test" \
  -o /tmp/agentd \
  ./cmd/agentd

/tmp/agentd version
/tmp/agentd doctor --check-port
```

GoReleaser 快照检查：

```bash
go run github.com/goreleaser/goreleaser/v2@v2.9.0 check
go run github.com/goreleaser/goreleaser/v2@v2.9.0 release --snapshot --clean --skip=publish
```

正式发布：

```bash
git status --short
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

发布后验证：

```bash
brew update
brew install gaixianggeng/tap/codex-ipad-agent

agentd version
codex --version
codex app-server --help

agentd setup
agentd doctor --check-port
agentd start
agentd doctor
```

验证点：

- `agentd start` 能启动 Homebrew service。
- 终端能打印 Endpoint、Token、连接链接和二维码。
- `/healthz` 可访问。
- `/api/projects` 需要 Bearer Token。
- `/api/app-server/config` 不返回 upstream token。
- iPad 扫码后能保存连接并加载项目。

### 3. iOS App Store 发布

App Store 定位建议：

```text
Mimi 是一个 iPad 原生客户端，用来连接用户自己 Mac 上运行的 agentd。
它不在 iPad 上运行 Codex，也不把 Codex 凭证上传到第三方服务器。
```

名称建议：

- App Name：英文 `Mimi`，中文本地化 `咪咪`，不要首发直接使用 `CodexAgentPad` 作为 App Store Display Name。
- Subtitle：`iPad client for your Mac agent`
- Category：Developer Tools 或 Productivity，优先 Developer Tools。
- Pricing：Free。

App 隐私建议：

- 如果 App 不接入第三方 analytics、不上传日志、不接入自己的云服务，可以按“不收集数据”方向填写。
- 需要在隐私政策中说明：Endpoint 和 Token 只保存在用户设备本地，Token 存入 Keychain；App 只连接用户配置的 Mac endpoint。
- 如果未来加入崩溃分析、埋点或远程日志，再更新 App Privacy。

审核账号和测试环境：

- 这个 App 没有传统账号体系，不需要提供测试账号。
- 需要在 Review Notes 提供完整 Mac 后端安装步骤。
- 必须提供一个演示视频链接，展示 `agentd start` 输出二维码、iPad 扫码连接、发送一条消息。
- App 内必须提供离线演示入口，避免审核员无法搭建 Mac 后端时认为 App 是空壳。

### 4. App Review Notes 模板

提交审核时可以直接使用下面这段，按实际版本号和链接调整：

```text
Mimi is a companion iPad client for a user-owned Mac running agentd.

The iPad app does not execute code on iPad and does not download executable code.
It connects to the user's own Mac over local network or Tailscale.
The Mac-side agentd is open source and installed via Homebrew.
This is an independent third-party client and is not affiliated with, endorsed by, or sponsored by OpenAI.

Mac setup steps:
1. Install and sign in to Codex CLI.
2. Run: brew update
3. Run: brew install gaixianggeng/tap/codex-ipad-agent
4. Run: agentd setup
5. Run: agentd doctor --check-port
6. Run: agentd start
7. Open the iPad app and scan the pairing QR code.

Offline demo:
The app includes an offline demo mode that shows sample projects, sample sessions, logs, diffs, and approval UI without requiring a Mac backend.

Security notes:
- Codex credentials remain on the user's Mac.
- The iPad app stores only the agentd endpoint and outer access token.
- The app-server upstream token is stored only on the Mac and is never returned to iPad.
- The recommended network path is local network or Tailscale. Public internet exposure is not recommended.

Demo video:
<填入视频链接>

Source code:
https://github.com/gaixianggeng/codex-ipad-agent
```

### 5. App Store 文案草稿

短描述：

```text
Use your iPad as a native console for your own Mac dev environment.
```

中文描述：

```text
咪咪是一个面向开发者的 iPad 原生客户端，用来连接你自己 Mac 上运行的 agentd。

你可以在 Mac 上通过 Homebrew 安装 agentd，然后在 iPad 上扫码连接，选择本机项目，并通过 Codex app-server 协议远程使用你的本机开发环境。

主要特点：
- 原生 iPad SwiftUI 体验
- 通过扫码连接 Mac 上的 agentd
- 支持项目列表、历史会话和新会话
- 支持 Codex 结构化消息、日志、diff 和审批
- Codex 凭证保留在你的 Mac 本机

注意：
本 App 需要配合 Mac 端 agentd 使用。推荐通过局域网或 Tailscale 连接，不建议把 agentd 暴露到公网。

本 App 是独立开发的第三方客户端，不隶属于 OpenAI，也不代表 OpenAI 官方产品。
```

英文描述：

```text
Mimi is a native iPad client for developers who want to use their iPad as a companion console for their own Mac development environment.

Install agentd on your Mac with Homebrew, start the local control plane, then scan the pairing QR code from your iPad.

Features:
- Native SwiftUI iPad experience
- QR-code pairing with your Mac
- Project list, session history, and new sessions
- Structured Codex messages, logs, diffs, and approvals
- Codex credentials remain on your Mac

Note:
This app requires the Mac-side agentd service. Local network or Tailscale access is recommended. Public internet exposure is not recommended.

This is an independent third-party client and is not affiliated with, endorsed by, or sponsored by OpenAI.
```

### 6. 用户安装文档入口

README 首页建议保留一条最短路径：

```bash
brew update
brew install gaixianggeng/tap/codex-ipad-agent

codex --version
codex app-server --help

agentd setup
agentd doctor --check-port
agentd start
agentd doctor
```

iPad 端文案建议：

```text
1. 在 Mac 上安装并启动 agentd。
2. 确认 iPad 和 Mac 在同一网络，或都已连接 Tailscale。
3. 点击“扫码连接”，扫描 agentd start 输出的二维码。
4. 测试连接成功后保存。
```

### 7. 申请 Unlisted App

如果正式审核通过后不想让 App 出现在搜索、榜单和推荐里，可以申请 Unlisted App。

适合本项目的原因：

- 项目是小众开发者工具。
- 用户需要读 README 并安装 Mac 后端，不适合随机用户直接下载。
- 通过链接分发更符合个人兴趣项目的维护节奏。

申请顺序：

```text
App Store 正式审核通过
  -> 确认 App 可用
  -> 在 Apple Developer 提交 Unlisted App request
  -> 通过后在 README、GitHub Release、社交媒体里分享 App Store 链接
```

注意：Unlisted App 仍然是 App Store App，只是不公开展示；拿到链接的人都可以安装。

## 风险与优化

### 审核风险

风险：审核员无法搭建 Mac 后端，认为 App 不可用。

处理：

- Review Notes 写完整步骤。
- 提供演示视频。
- 发布前实现离线演示模式。
- 未连接状态有可理解的设置页、扫码入口和说明。

风险：被误解为 iPad 端下载或执行代码。

处理：

- 明确说明 iPad App 不执行代码。
- 明确说明 Codex 和项目文件都在用户自己的 Mac 上。
- App 内不要出现“在 iPad 执行代码”这类容易误导的文案。

风险：HTTP / Tailscale / 本地网络访问被质疑。

处理：

- 说明仅用于用户自有 Mac 的本地或 Tailscale 连接。
- 不建议公网暴露。
- 隐私政策说明 Endpoint/Token 的本地保存方式。

### 安全风险

风险：用户把 `agentd` 暴露到公网。

处理：

- README、App 内、`agentd doctor` 都提示不要公网暴露。
- 默认 `allow_query_token=false`。
- 推荐 Tailscale。
- 后续可以增加 doctor 检查：如果监听 `0.0.0.0`，输出高风险警告。

风险：Token 泄漏。

处理：

- 二维码只包含 iPad 访问 `agentd` 的外侧 Token。
- app-server upstream token 只保存在 Mac 本机。
- 日志和 doctor 输出必须脱敏。
- README 提醒不要把 Token 放进截图或 URL。

### 维护风险

风险：iOS App 和 `agentd` 协议版本不匹配。

处理：

- `/api/app-server/config` 返回 `agentd` 版本和能力字段。
- App 启动时检查最低兼容版本。
- Release notes 明确 iOS 版本和推荐 `agentd` 版本。

风险：Codex app-server 协议变化。

处理：

- `agentd doctor --check-port` 持续检查关键参数。
- 保留 app-server protocol samples 测试。
- README 明确推荐 Codex CLI 版本范围。

### 后续优化

- 增加 App 内“Mac 安装指南”页面。
- 增加 `agentd self-update` 或 Homebrew 更新提示。
- 增加多 Mac 配置。
- 增加 App 内安全状态检查，例如 endpoint 是否为公网地址。
- 增加 GitHub Actions：后端 release、iOS build-for-testing、文档链接检查。

## 参考链接

- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- Apple Unlisted App Distribution: https://developer.apple.com/support/unlisted-app-distribution/
- Apple App Privacy Details: https://developer.apple.com/app-store/app-privacy-details/
