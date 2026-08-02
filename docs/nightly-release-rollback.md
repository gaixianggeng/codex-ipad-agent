# Nightly、Release validation 与回滚检查

## 目标

把 Mimi 的验证分成三个互不冒充的层级：

| 层级 | 反馈目标 | 负责内容 | 不负责 |
| --- | --- | --- | --- |
| PR Gate | 约 10–12 分钟 | 变更路径分类、协议/安全静态检查、Go/iOS/Rust 关键回归 | 全量 iOS、Mac App、跨平台安装包、真实 Runtime |
| Nightly | 每天一次，允许约 90 分钟 | Go race、完整 Rust、Mac App、全量 iOS、Linux rollback fixture、Mac/Windows/GoReleaser snapshot | 签名、公证、TestFlight、生产数据 |
| Release validation | 明确 candidate + previous 后手工触发 | N/N-1、全量回归、跨平台归档、签名、公证、ASC、真实 Runtime，并消费已完成的 TestFlight/回滚 run | 创建 tag/Release、重复上传 TestFlight、部署、生产主机自动回滚 |

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
- artifact 保留 7 天；已开始的重任务不被新触发强制取消，避免留下半份证据。

Nightly 不读取 Apple/Windows 发布私钥，也不使用真实用户仓库、Token 或会话。

真实 Runtime smoke 是独立可选 job。定时启用前必须同时满足：

1. 仓库变量 `MIMI_NIGHTLY_RUNTIME_SMOKE_ENABLED=true`；
2. 存在标签为 `self-hosted`、`mimi-runtime-smoke` 的隔离 runner；
3. `nightly-runtime-smoke` environment 中配置可撤销的
   `MIMI_NIGHTLY_RUNTIME_ENDPOINT`、`MIMI_NIGHTLY_RUNTIME_TOKEN`；
4. 被测 `agentd` 必须由构建期 ldflags 注入完整 commit，并在 `/api/version.build_commit`
   返回；Nightly 会直接与当前 commit 比较，`unknown`、短 SHA 或 environment 自报值均失败；
5. Endpoint 只允许 HTTPS 或 runner 自己的 loopback，后端只暴露一次性样例仓库；
6. Claude 还需仓库变量 `MIMI_NIGHTLY_CLAUDE_SMOKE_ENABLED=true`。

Codex smoke 只执行 `initialize + thread/list` 多轮读取。Claude smoke 只执行
`models/list`，不启动 turn。缺少 Claude 明确开关时结果写为 `SKIPPED`，不能伪造成功；
请求了整个 Runtime job 但 runner、Endpoint、Token、二进制 commit 身份缺失，或任一次只读请求
失败时，Nightly 直接失败。

### Release validation

Release validation 只能在正式仓库的受保护 `main` 上 `workflow_dispatch`。候选固定为触发时
的 `github.sha`，workflow 会再次确认它等于 `origin/main`；不存在可由操作者填写的
`candidate_ref`，避免任意分支代码读取签名、ASC、Windows PFX 或 Runtime 凭据。输入为：

- `previous_release_tag`：上一已知可用且非 draft/prerelease 的正式 GitHub Release tag，
  必须解析为 candidate 的祖先；
- `candidate_version`：不含 `v` 的候选语义版本；`dry-run` 可用 `0.0.0`，
  `publish-readiness` 必须填写真实版本；
- `validation_mode`：`dry-run` 或 `publish-readiness`；
- `run_controlled_runtime_smoke`：是否运行隔离 Runtime；
- `internal_testflight_run_id`：同一 candidate 上成功的 `iOS CI` TestFlight 上传 run；
- `rollback_drill_run_id`：同一 candidate 上成功的 `Release Rollback Drill` run。

`dry-run` 不读取发布凭据，生成：

- N/N-1 与 capability/rollback Markdown 报告，保留 30 天；
- 四平台 Go 归档、checksums 与 Homebrew Formula；
- ad-hoc universal Mac DMG；
- unsigned Windows installer、metadata 与 SHA-256；
- unsigned iOS xcarchive；
- Go、Rust、Mac 和完整 iOS 测试结果。

`dry-run` 变绿只表示“候选可构建、静态兼容和回滚入口存在”，明确不授权发布。

`publish-readiness` 仍不发布，但会 fail-closed 地增加：

- 使用 Developer ID 构建并 notarize Mac DMG，验证 Gatekeeper/ticket 后按拖放语义复制到隔离
  `Applications` 目录；卸载 DMG 后只从安装副本启动 embedded agentd，要求候选
  `version/build_commit`、`readyz=200` 与 Doctor 全部通过，并生成 Mac 安装运行态证据；
- 使用 Authenticode PFX 签名三份 Windows payload 和 installer，再验证签名；
- 使用 Distribution certificate/profile 生成 IPA，并通过 App Store 服务端
  `validate-app`；`IOS_TESTFLIGHT_UPLOAD=0`，不上传、不关联 beta group；
- 强制运行受控 Codex Runtime smoke；Claude 未显式配置时保留 `SKIPPED` 证据；
- `/api/version.version` 与 `/api/version.build_commit` 必须分别等于候选版本和完整 candidate
  SHA；Runtime environment 变量不能替代被测进程身份；
- 通过 GitHub Actions API 校验两个 run 的正式仓库、workflow path、`main`、event、结论与
  `head_sha`，要求 exact artifact 唯一且未过期，下载后再核对 API `sha256:` digest；
- TestFlight artifact 只能由真实上传步骤生成：从实际 IPA 计算摘要，并由 ASC 回读确认
  build 为 `VALID`、已进入目标 Internal beta group、组内有 tester 且 What to Test 一致；
- Rollback artifact 只能由 `Release Rollback Drill` 生成：下载上一正式 Release 的 agentd
  归档，核对 release/tag/祖先/checksums，在同一部署路径、HOME、配置、Token 和端口启动
  candidate 后原位替换为 previous，再要求 previous 版本、`readyz=200` 与 Doctor 全部通过；
- 最终生成机器可读 `attestation`，绑定 candidate SHA、公开版本、previous SHA、实际验证 IPA
  的 bundle/version/build/digest、两份受信 artifact、其 run/artifact digest 和当前验证 run identity。

任何 secret、runner、previous Release、N/N-1、签名、ASC、Runtime 或机器证据缺失都会失败；
不能把 `dry-run` artifact 或 `SKIPPED` 当作正式发布凭据。artifact 保留 30 天（unsigned
iOS archive 保留 14 天），同一 candidate 的新验证不会取消已经开始的旧验证。真正的
`.github/workflows/release.yml` 在 tag 发布前从当前受保护 `main` checkout verifier，要求 tag
也指向该 current main，再筛选来自成功 `main` `workflow_dispatch` 的 exact attestation。
所有可能写 Release、上传资产或推送 Tap 的 job 都必须传递依赖 readiness；缺少或不匹配时
Mac/Windows/GitHub Release job 均不会启动。发布 tag/ruleset 与 environment branch protection
仍是仓库设置层的信任根，不能靠待发布 tag 自己携带的脚本替代。

生产凭据必须只保存为 Environment secrets，不能在 Repository secrets 保留同名副本：

- `ios-production-signing`：ASC、Distribution certificate/profile 与临时 Keychain 凭据；
- `release-production-signing`：Developer ID/Notary、Windows PFX 与 Tap deploy key；
- `nightly-runtime-smoke`：受控 Runtime endpoint/token。

前两个 environment 必须限制受保护 `main`；正式 `v*` tag job 还必须由 tag ruleset 和 environment
reviewer 共同授权。`nightly-runtime-smoke` 只允许受控 runner。若 environment 不存在、分支/tag
规则未配置，或 production secret 仍能从 repository 级别读取，publish-readiness 必须视为未就绪。

### 证据 run 的顺序

1. 在 current `main` 手工运行 **iOS CI**，选择 `publish_app_store=true`。该 run 真实上传并
   分发 Internal TestFlight，成功后生成 `internal-testflight-evidence-<candidate SHA>`。
2. 在同一 `main` 手工运行 **Release Rollback Drill**，填写上一正式 tag 与候选版本。该
   run 在隔离 GitHub-hosted runner 上执行 agentd binary rollback，生成
   `rollback-drill-evidence-<candidate SHA>`。
3. 记录两个成功 run ID，再触发 **Release Validation / publish-readiness**。输入只能选择
   run，不能直接粘贴 JSON 或 URL；workflow 会重新查询 run 与 artifact 并核对 digest。
4. `publish-readiness` 仍会重新归档并 `validate-app` 一份 IPA。它与已上传 TestFlight IPA
   分别记录 build/digest，避免把“服务端验证”误写成“已经分发”。

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
previous_ref="<上一正式 Release tag>"
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

只有以下条件同时满足才允许创建正式 tag：

1. candidate SHA 与准备发布的 commit 完全一致；
2. `candidate_version` 与安装包元数据、受控 Runtime `/api/version` 完全一致；
3. `Release Validation` 的 `publish-readiness` 最终 job 成功并上传 exact attestation；
4. Mac/Windows 签名、Mac notarization、iOS ASC validate 均为成功，不是 snapshot；
5. Internal TestFlight upload run 使用同一 candidate，ASC 已回读 `VALID`、Internal group、
   tester 和 What to Test；真机专项仍按对应功能 Issue 单独记录；
6. previous 是仍可下载的上一正式 Release，自动 agentd rollback drill 已恢复实际 previous
   版本并通过 `readyz`/Doctor；若发布风险要求 Mac App 级恢复，再补签名 DMG 真机演练；
7. 未执行项、手工项、构建号、artifact/run URL 已回写发布 Issue；
8. 没有未解释的 `SKIPPED`。Claude 可以因实验通道未启用而跳过，但必须明确记录。

维护者人工创建 `v<candidate_version>` tag 后，`.github/workflows/release.yml` 会再次验证
attestation 的 SHA、版本、验证 run、仓库和 workflow identity；验证通过后才构建并发布
签名的 Mac/Windows 与 GoReleaser 产物。Release validation 本身仍不创建 tag、不上传
TestFlight、不部署，也不执行生产回滚。

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

### 上一正式产物恢复演练

默认 Gate 使用 `.github/workflows/release-rollback-drill.yml` 在隔离 GitHub-hosted runner
完成 agentd binary 演练：同一部署路径、HOME 和配置先启动带精确 `build_commit` 的 candidate，
再停止并原位换成上一正式 Release 的 agentd 归档；归档必须通过 Release checksum，恢复后
实际版本、`readyz=200` 与 Doctor 都必须成功。证据记录 candidate/restored binary digest 与共享
配置 digest，由 workflow 生成并上传，不能由 Release Validation 输入 JSON。

Mac App 或 Windows installer 的人工演练只能在隔离测试用户/主机执行，不能对生产主机
自动回滚。需要时记录 candidate、previous、平台、安装方式、配置备份类型、开始/结束时间、
恢复版本、`service_ok`/`readyz`、Doctor、移动端连接、执行人和签名身份；它属于额外发布
风险证据，不替代默认 agentd binary Gate。

- Mac：用上一仍可下载、Developer ID 签名并 notarize 的 DMG 覆盖测试 App，或按
  `docs/install-upgrade-rollback.md` 使用上一签名 Homebrew keg；
- Windows：重新运行上一仍为 `Valid` Authenticode 的正式 installer；
- Linux：正式故障处理仍可使用归档保存的 helper 执行：

```bash
bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback
"$HOME/.local/bin/agentd" status --json
```

如果 previous artifact 不可下载、checksum/签名无效、配置不再向后兼容、恢复后
`readyz`/Doctor 失败，或 artifact run 无法关联到同一 candidate，结论必须 fail-closed。

## 风险与优化

- 托管 runner 能证明跨平台构建和静态安装策略，不能替代相机、通知、Keychain、
  Tailscale/弱网、性能和真实设备专项；这些结果必须单独记录。
- macOS notarization 与 ASC validate 会访问 Apple，但不向用户分发；只有显式选择
  `publish-readiness` 才读取凭据。
- 自托管 Runtime runner 是权限最高的环节，只允许样例仓库、只读 smoke、短期 Token 和
  environment approval；不要挂载个人工作目录或复用日常 agentd Token。
- 当前不建设自动生产回滚、设备农场或商业灰度系统。真实故障数据证明需要更多组合前，
  保持这套薄编排。
