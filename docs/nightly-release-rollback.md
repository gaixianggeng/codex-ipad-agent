# Nightly、Release validation 与回滚检查

## 目标

把 Mimi 的验证分成三个互不冒充的层级：

| 层级 | 反馈目标 | 负责内容 | 不负责 |
| --- | --- | --- | --- |
| PR Gate | 约 10–12 分钟 | 变更路径分类、协议/安全静态检查、Go/iOS/Rust 关键回归 | 全量 iOS、Mac App、跨平台安装包、真实 Runtime |
| Nightly | 每天一次，允许约 90 分钟 | Go race、完整 Rust、Mac App、全量 iOS、Linux rollback fixture、Mac/Windows/GoReleaser snapshot | 签名、公证、TestFlight、生产数据 |
| Release validation | 明确 candidate + previous 后手工触发 | N/N-1、全量回归、跨平台归档、安装包元数据；发布准备模式再验证签名、公证、ASC 与真实 Runtime 证据 | 创建 tag/Release、上传 TestFlight、部署、自动生产回滚 |

`.github/workflows/pr-gate.yml` 继续只承担快速 Gate。`.github/workflows/nightly.yml`
与 `.github/workflows/release-validation.yml` 承担重任务。workflow、action、路径分类或
验证脚本自身变化时，`scripts/check-validation-workflows.sh` 会进入 PR Gate 静态验证，
不会等到夜间才发现 YAML、权限或 fail-closed 语义已经漂移。

## 方案

### Nightly

定时任务每天北京时间 02:30 运行，也可以在 GitHub Actions 的 **Nightly Validation**
页面手工选择 **Run workflow**。默认任务只使用仓库源码、公开工具链和脱敏 fixture：

- Ubuntu：Codex/Mimi 契约、Go race、Linux 安装/升级/回滚 fixture、四平台
  GoReleaser snapshot；
- Ubuntu + Windows：完整 Rust bridge workspace；
- macOS：Mac App 测试、完整 iOS 单测/快照、universal DMG snapshot；
- Windows：unsigned installer、SHA-256、metadata、静态安装策略；
- artifact 保留 7 天；旧运行由 concurrency 取消，避免重复消耗 runner。

Nightly 不读取 Apple/Windows 发布私钥，也不使用真实用户仓库、Token 或会话。

真实 Runtime smoke 是独立可选 job。定时启用前必须同时满足：

1. 仓库变量 `MIMI_NIGHTLY_RUNTIME_SMOKE_ENABLED=true`；
2. 存在标签为 `self-hosted`、`mimi-runtime-smoke` 的隔离 runner；
3. `nightly-runtime-smoke` environment 中配置可撤销的
   `MIMI_NIGHTLY_RUNTIME_ENDPOINT`、`MIMI_NIGHTLY_RUNTIME_TOKEN`；
4. environment 变量 `MIMI_NIGHTLY_RUNTIME_CANDIDATE_SHA` 必须是该受控环境实际运行的
   完整 commit SHA，并与当前 Nightly commit 一致；
5. Endpoint 只允许 HTTPS 或 runner 自己的 loopback，后端只暴露一次性样例仓库；
6. Claude 还需仓库变量 `MIMI_NIGHTLY_CLAUDE_SMOKE_ENABLED=true`。

Codex smoke 只执行 `initialize + thread/list` 多轮读取。Claude smoke 只执行
`models/list`，不启动 turn。缺少 Claude 明确开关时结果写为 `SKIPPED`，不能伪造成功；
请求了整个 Runtime job 但 runner、Endpoint、Token、候选 SHA 缺失，或任一次只读请求
失败时，Nightly 直接失败。

### Release validation

Release validation 只能 `workflow_dispatch`，输入必须绑定到不可变证据：

- `candidate_ref`：待发布 commit、分支或 tag；
- `previous_release_ref`：上一已知可用正式版本，必须解析为 candidate 的祖先；
- `candidate_version`：不含 `v` 的候选语义版本；`dry-run` 可用 `0.0.0`，
  `publish-readiness` 必须填写真实版本；
- `validation_mode`：`dry-run` 或 `publish-readiness`；
- `run_controlled_runtime_smoke`：是否运行隔离 Runtime；
- `internal_testflight_evidence`：同一 candidate 的 Internal TestFlight 证据 URL；
- `rollback_drill_evidence`：同一 candidate 发布前，上一签名产物恢复演练证据 URL。

`dry-run` 不读取发布凭据，生成：

- N/N-1 与 capability/rollback Markdown 报告，保留 30 天；
- 四平台 Go 归档、checksums 与 Homebrew Formula；
- ad-hoc universal Mac DMG；
- unsigned Windows installer、metadata 与 SHA-256；
- unsigned iOS xcarchive；
- Go、Rust、Mac 和完整 iOS 测试结果。

`dry-run` 变绿只表示“候选可构建、静态兼容和回滚入口存在”，明确不授权发布。

`publish-readiness` 仍不发布，但会 fail-closed 地增加：

- 使用 Developer ID 构建并 notarize Mac DMG，再验证 Gatekeeper/ticket；
- 使用 Authenticode PFX 签名三份 Windows payload 和 installer，再验证签名；
- 使用 Distribution certificate/profile 生成 IPA，并通过 App Store 服务端
  `validate-app`；`IOS_TESTFLIGHT_UPLOAD=0`，不上传、不关联 beta group；
- 强制运行受控 Codex Runtime smoke；Claude 未显式配置时保留 `SKIPPED` 证据；
- environment 的候选 SHA 和 `/api/version` 必须分别与已解析 candidate commit、
  `candidate_version` 完全一致，防止误验旧环境；
- 强制要求 Internal TestFlight 与上一签名产物恢复演练的 `https://` 证据。

任何 secret、runner、previous ref、N/N-1、签名、ASC、Runtime 或人工证据缺失都会失败；
不能把 `dry-run` artifact 或 `SKIPPED` 当作正式发布凭据。artifact 保留 30 天（unsigned
iOS archive 保留 14 天），同一 candidate 的新验证不会取消已经开始的旧验证。

## 实现

### 本地无副作用检查

先检查 workflow 与文档约束：

```bash
bash ./scripts/check-validation-workflows.sh
bash ./scripts/check-pr-gate.sh
```

再对明确的 candidate / previous 生成回滚报告。命令只读 Git，不安装或停止服务：

```bash
candidate_ref="HEAD"
previous_ref="<上一正式 tag 或 commit>"
report_dir="$(mktemp -d)"

bash ./scripts/check-rollback-readiness.sh \
  --candidate-ref "$candidate_ref" \
  --previous-ref "$previous_ref" \
  --output "$report_dir/rollback-readiness.md"
```

需要本地复现发布 artifact 时：

```bash
bash ./scripts/verify-release.sh verify

bash ./scripts/build-macos-installer.sh \
  --snapshot \
  --version 0.0.0 \
  --output-dir dist-macos
bash ./scripts/check-macos-installer.sh dist-macos/Mimi-Remote-Mac.dmg
```

Windows snapshot 必须在 Windows PowerShell 运行：

```powershell
./scripts/build-windows-installer.ps1 `
  -Version 0.0.0 `
  -OutputDirectory dist-windows `
  -Snapshot
$Installer = Get-Item "dist-windows\Mimi-Remote-Setup-*.exe"
./scripts/check-windows-installer.ps1 -InstallerPath $Installer.FullName
./scripts/test-windows-install.ps1
```

### 读取结果

先打开最终 `Nightly Validation` 或 `Release Validation` job summary，再进入失败的具体 job。
最终 job 只聚合判定，根因日志位于对应平台：

- 协议/Go/Rust：测试名、package 与 GoReleaser artifact；
- Mac/iOS：XCTest method、archive metadata、codesign/notary/Gatekeeper；
- Windows：payload SHA-256、Authenticode、Inno policy；
- Rollback：`release-rollback-report-*` artifact；
- Runtime：只读成功率/P50/P95；日志不得出现 Endpoint 或 Token。

Nightly 第一次失败先在同一 GitHub run 上重跑失败 job，确认是否为 runner/网络瞬态。连续
两次定时运行失败，必须查重并创建或更新一张 Mimi Linear Issue，附两个 run URL、失败
job、首个确定错误和负责人；Nightly 红灯本身不冻结所有 PR，但关联问题解决前不能忽略。

### 允许继续发布的条件

只有以下条件同时满足才允许进入“人工发布”阶段：

1. candidate SHA 与准备发布的 commit 完全一致；
2. `candidate_version` 与安装包元数据、受控 Runtime `/api/version` 完全一致；
3. `Release Validation` 的 `publish-readiness` 最终 job 成功；
4. Mac/Windows 签名、Mac notarization、iOS ASC validate 均为成功，不是 snapshot；
5. Internal TestFlight 使用同一 candidate，关键移动端链路已记录；
6. previous 是仍可下载的上一签名正式版本，恢复演练已记录实际版本、`readyz` 和结果；
7. 未执行项、手工项、构建号、artifact/run URL 已回写发布 Issue；
8. 没有未解释的 `SKIPPED`。Claude 可以因实验通道未启用而跳过，但必须明确记录。

本仓库 workflow 到此停止。创建 tag、GitHub Release、TestFlight 分发或正式部署是后续
独立人工动作，不由本验证流程自动执行。

### capability kill switch 降级

当 `file_upload_v1` 出现问题，但基础会话、审批与 Git 仍健康时，优先只关闭该能力。
操作前备份私有配置，按
[Capability 声明与本地降级](capability-rollout.md) 中对应平台的完整命令修改
`capabilities.disabled`，然后：

```bash
agentd restart --no-pair
agentd status --json | jq '
  .doctor.checks[]
  | select(.name == "capability-file-upload-v1")
'
```

必须同时确认：

- `/api/version` 不再声明 `file_upload_v1`；
- 状态为 `locally_disabled / disabled_by_local_config`；
- 文件上传端点返回结构化 `503 capability_locally_disabled`；
- iOS 当前 Host 隐藏或禁用入口，不发送请求；
- 基础会话、审批、Git/Worktree 仍可用。

恢复时只移除 `file_upload_v1`，保留其他禁用项；依赖仍异常时必须保持
`dependency_unavailable`，不能强制宣告 capability。禁止通过清 Token、删连接档案、
擦除 Simulator 或关闭服务端权限检查来“恢复”。

### 上一签名产物恢复演练

演练只能在隔离测试用户/主机执行，不能对生产主机自动回滚。记录中至少包含 candidate、
previous、平台、安装方式、配置备份位置（只记录类型，不记录真实路径/Token）、开始和
结束时间、恢复后的版本、`service_ok`/`readyz`、Doctor、移动端连接和执行人。

- Mac：用上一仍可下载、Developer ID 签名并 notarize 的 DMG 覆盖测试 App，或按
  `docs/install-upgrade-rollback.md` 使用上一签名 Homebrew keg；
- Windows：重新运行上一仍为 `Valid` Authenticode 的正式 installer；
- Linux：使用正式归档保存的 helper 执行：

```bash
bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback
"$HOME/.local/bin/agentd" status --json
```

如果 previous artifact 不可下载、签名无效、配置不再向后兼容、恢复后 `service_ok`
不是 `true`，或证据无法关联到同一 candidate，结论必须是 fail-closed。

## 风险与优化

- 托管 runner 能证明跨平台构建和静态安装策略，不能替代相机、通知、Keychain、
  Tailscale/弱网、性能和真实设备专项；这些结果必须单独记录。
- macOS notarization 与 ASC validate 会访问 Apple，但不向用户分发；只有显式选择
  `publish-readiness` 才读取凭据。
- 自托管 Runtime runner 是权限最高的环节，只允许样例仓库、只读 smoke、短期 Token 和
  environment approval；不要挂载个人工作目录或复用日常 agentd Token。
- 当前不建设自动生产回滚、设备农场或商业灰度系统。真实故障数据证明需要更多组合前，
  保持这套薄编排。
