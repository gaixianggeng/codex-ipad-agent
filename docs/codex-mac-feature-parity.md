# Codex Mac App 功能对照

## 目标

用当前 Codex Mac app 的公开功能作为参照，检查 Mimi Remote 已有能力、缺口和补齐顺序。目标不是照搬桌面产品，而是在 iPad 场景下补齐真正影响远程开发闭环的能力。

官方基线来自 OpenAI Codex app 文档：

- Codex app 是面向多个线程并行、worktree、automations 和 Git 工作流的桌面体验。
- 新建线程支持 Local、Worktree、Cloud 三种模式。
- 桌面端包含 Git diff、inline comment、stage/revert、commit、push、PR、集成终端、语音输入、浏览器、Computer Use、artifact 预览、IDE sync、MCP、web search、image input/generation、通知和防睡眠等能力。

## 方案

移动端优先级按“能否让 iPad 远程闭环更接近桌面端”排序：

1. P0：审核安全、语音输入、图片上下文、运行选项、审批、日志、diff。
2. P1：Worktree 模式、Git 审查动作、项目级快捷命令/终端输出。
3. P2：artifact 预览、技能/MCP 浏览、通知、线程自动化。
4. P3：Cloud、IDE sync、Computer Use、浏览器操作。这些依赖账号中继、桌面权限或复杂插件，移动端先不强行重做。

## 实现

| Codex Mac app 能力 | Mimi Remote 当前状态 | 缺口 | 补齐策略 |
| --- | --- | --- | --- |
| 多项目、多线程 | 已支持。侧栏可打开工作区、展开项目、查看会话、继续历史；本轮补齐已加载会话搜索，以及 pin/archive MVP：长按会话可置顶、取消置顶、归档和取消归档，偏好按 agentd endpoint 隔离持久化；归档/取消归档会优先调用 app-server `thread/archive` / `thread/unarchive` 同步远端 thread，失败时保留 iPad 本地列表整理状态并提示。 | 置顶仍是 iPad 本地排序；搜索暂不下推到后端全文索引。 | 等 app-server 稳定暴露 pin 协议后再映射到远端；历史量变大后再做服务端搜索。 |
| Local 线程 | 已支持。`thread/start` / `thread/resume` 绑定 allowlist cwd。 | 无明显缺口。 | 保持安全默认值。 |
| Worktree 线程 | 本轮补齐 MVP。项目菜单可新建 managed Worktree，创建时可填写名称、base 和分支；后端会从 base 创建隔离 checkout 和本地分支，并返回可打开 workspace；iPad 侧把它当普通 workspace 继续走现有 `thread/list`、`thread/start`、Git 面板和 app-server gateway；侧栏新增 Worktree 管理入口，可列出、打开和删除 agentd 创建的 Worktree，并展示分支、base、dirty、ahead/behind 和 upstream；创建表单会只读枚举本地/远端分支，自动填当前分支作为默认 base，并支持从列表选择 base；管理页新增“清理丢失登记”，只移除 checkout 已不存在或根项目已移除的 agentd registry 记录，不删除任何仍存在的目录；会话长按菜单新增“转到新 Worktree”，从来源会话根项目创建隔离 checkout 后优先调用 app-server `thread/fork` 把完整历史 fork 到新 cwd，运行中会话需先停止或完成；旧 gateway 不支持 fork 时 fallback 为提示式新线程交接。 | 仍缺真实 checkout 的自动保留/清理策略。 | 真实 checkout 的自动清理需要先定义保留策略，避免误删用户现场；当前只提供安全的缺失 registry 清理和受保护的手动删除。 |
| Cloud 线程 | 未支持。 | 需要官方账号 relay / cloud environment。 | P3 暂不做，避免伪实现。 |
| Git diff 审查 | 本轮补齐 Git 面板。Inspector 可读取当前授权工作区的 `git status`、diff stat、staged/unstaged patch，支持文件级 stage、unstage、revert、单 hunk stage/unstage/revert、commit、push 当前分支，并可通过本机 `gh` 创建草稿 PR、刷新当前分支 PR 状态和打开 PR；同时保留运行时文件变更摘要；本轮新增本地 hunk 审查备注，iPad 可在 diff hunk 上添加 inline review note，并一键汇总追加到草稿 PR 描述。 | 仍缺 GitHub Review API 级别的 inline comment 同步和更完整的 PR 更新能力。 | PR 深度更新/Review 操作可等 GitHub 集成需求明确后补；移动端先保留本地备注到 PR 描述的低风险闭环。 |
| 集成终端 | 本轮补齐 allowlist command action MVP。agentd 配置文件可声明 `actions`，iPad Inspector 会按当前工作区列出可用动作、执行 action ID，并为每个工作区保留最多 10 条本地执行历史，界面展示最近 3 条输出；后端只执行配置中的 command/args，working_dir 必须落在当前授权 scope 内，且有超时和输出截断；高风险动作可配置 `requires_confirmation`，iPad 执行前会弹出二次确认；iPad 端新增轻量 FIFO 队列，当前动作运行时继续点击其它动作会排队顺序执行，并在动作行展示排队数量。已有日志和运行输出继续保留。 | 仍不是完整交互式终端。 | 先保持 allowlist action；不开放任意 shell。后续按真实使用频率补更完整的输出查看。 |
| 语音输入 | 本轮补齐。支持按住说话、转写到草稿、发送前确认；输入工具栏可选择自动、中文、英文、日文、韩文识别语言，仍优先使用本地语音识别；外接键盘可用 `Command+Shift+D` 切换语音输入。 | 无明显缺口；和桌面端相比仍是 iPad 原生本地听写体验。 | 保持触控优先；后续只按真实反馈补更多语言或快捷键。 |
| 图片输入 | 已支持。可选照片、iPad Files 图片、图片 URL、本机图片路径；照片和 Files 图片会在 iPad 端降采样为 inline data URL；附件 chip 可点开大图预览，远端本机路径会明确展示为 agentd 读取路径，并可通过 agentd 安全读取授权范围内的普通文件后交给系统 QuickLook 预览。 | 还缺更完整的附件详情和 PDF/非图片附件内嵌预览。 | P2 按真实使用场景补图片/PDF 内嵌预览；保持 `.localImage` 只代表本机 agentd 可读路径。 |
| Skills / mentions | 本轮补齐只读浏览 MVP。设置页新增“能力”视图，agentd 会按当前工作区发现 repo/user/admin scope 的 Skills，并展示名称、描述、scope 和路径；Composer 仍支持手动添加 skill / mention 路径。 | 还不能启停 skill、创建 skill 或读取 Codex plugin marketplace 元数据；隐式触发策略只展示，不参与本地推理。 | 后续按需接 skill enable/disable 和 skill-creator 工作流；移动端先不改写用户本地 Codex 配置。 |
| Automations / thread automations | 本轮补齐本地提醒 MVP。会话长按菜单可设置 30 分钟、2 小时或明天提醒；提醒按 agentd endpoint 隔离持久化，并尽力调度 iPad 本地通知；会话行用铃铛标记已有提醒，可随时清除。 | 仍缺真正的远端线程唤醒、周期任务、执行历史和失败重试。 | 项目级自动化后置；下一步等 app-server 暴露稳定 automation/thread wakeup 协议后再接远端执行，避免在移动端伪造后台 agent。 |
| 审批与 sandbox | 已支持。审批卡、Ctrl-C、stop、远程默认值。 | 标准模式默认使用用户批准下的完全访问，网关仍禁止 `approvalPolicy=never` 和默认开网。 | 保持 full access + on-request 的默认组合，不放开 `never`。 |
| MCP / web search / image generation | MCP 本轮补齐只读配置浏览 MVP。设置页“能力”视图会读取用户级和项目级 `.codex/config.toml` 中的 `mcp_servers` 与 plugin-provided MCP server 摘要，只展示 server 名称、scope、transport、command/url、enabled 状态和配置文件路径，不启动 server、不读取 env secret；本轮新增非侵入式配置状态探测：stdio server 会检查 command 是否可执行，HTTP server 只标记为已配置，disabled 和配置异常会在 iPad 端显示短状态与原因。web search / image generation 仍由本地运行时和模型能力决定，iPad 只传 prompt/输入。 | 仍缺 MCP 登录、启停、工具列表实时探测、web search 状态展示和 image generation 配额/状态展示。 | 高风险配置写入、OAuth 登录和真实工具列表探测先留在本机 Codex；后续若 app-server 暴露稳定只读 tool list/status API，再接到 iPad。 |
| Artifact 预览 | 本轮补齐 MVP。打开工作区面板现在会展示授权目录下的普通文件，iPad 可通过 `/api/files/read` 读取 20MB 内文件并用系统 QuickLook 预览；assistant 回复里的常见文件路径也会显示为可点预览按钮。后端只允许读取 projects / browse_roots / managed worktree 边界内的普通文件。 | 仍缺内嵌富预览、超大文件流式下载和 artifact 运行时。 | 下一步按需做图片/PDF 的内嵌轻预览；复杂 artifact 运行时后置。 |
| IDE sync / Auto context | 未支持。 | 需要编辑器扩展和桌面 app 同步协议。 | P3 暂不做。 |
| Browser / Computer Use / Appshots | 未支持。 | 依赖桌面 UI 权限和浏览器插件。 | P3 通过远端 Codex 执行，不在 iPad 原生端复刻。 |
| Chats | 不在 iPad 端提供独立入口。当前产品主路径是打开明确授权的项目/工作区，再在该上下文中启动或继续会话。 | 无项目 Cloud Chats / projectless thread 仍未支持。 | 等 app-server 暴露稳定 projectless thread API 后再评估，不再用 `~/.codex/threads` 伪装成工作区。 |
| Memories | 未支持 UI。 | 没有记忆读写或状态展示。 | P3 等 app-server 稳定暴露后再做。 |
| 通知 / 防睡眠 | 本轮补齐提醒型和运行态本地通知。设置会话提醒时会请求/使用系统本地通知；未授权时仍保留侧栏提醒状态；当 iPad 正连接会话并收到审批等待、turn 完成或失败事件时，会调度一次本地通知并按事件 ID 去重；设置页新增“运行中保持屏幕常亮”，仅在前台选中会话处于运行或等待审批状态时禁用系统自动锁屏，离开运行会话后恢复默认。 | 还缺后台 push、离线通知和通知点击深链。 | 后台 push 需要远端事件订阅和设备 token 策略；通知深链等远端协议稳定后再接。 |

## 风险与优化

- Worktree、Git 写操作和命令 action 都会改变用户机器状态；当前 Worktree 删除只允许删除 agentd registry 中登记的 checkout，普通删除默认保留 Git 对未提交改动的保护。
- 任意 shell 终端不适合作为移动端 MVP；当前只支持用户配置的 allowlist actions，降低误触和权限风险。
- Cloud、IDE sync、Computer Use 不是单机 `agentd` 能安全复刻的能力，不应做“看起来像支持”的伪 UI。
- 功能对照每次补齐后要同步更新本表，避免产品状态和文档脱节。
