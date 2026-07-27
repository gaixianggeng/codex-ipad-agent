# Android UI 设计基准

`android-ui-direction-v1.png` 由 OpenAI 内建 image generation 工具生成，用于定义 Mimi Remote Android 的整体视觉方向，不作为逐像素截图实现。

设计稿覆盖：

- Pixel 8 会话与 Composer。
- Pixel 8 项目/会话列表与新建会话 FAB。
- Android 平板 Navigation Rail、列表、对话和 Inspector 三栏布局。

Compose 实现必须遵循 Material 3/Material Adaptive、动态色、edge-to-edge、预测返回和平台可访问性规范；不得复刻 iOS 毛玻璃或导航结构。

## 活动时间线

`android-activity-timeline-v1.png` 定义手机会话内嵌活动卡片，以及平板 Inspector supporting pane 中的活动视图。

`android-activity-states-v1.png` 定义运行中、成功和失败三组状态。实现约束：

`android-activity-timeline-v2.png` 是基于当前 Compose 实现生成的收敛稿：左侧为手机内嵌时间线，右侧为平板 supporting pane；两端共享同一 reducer 状态源。它补充了 reasoning、命令、文件修改、工具调用、web search、中断与失败语义，并明确展示有界命令输出、工作目录、复制和截断提示。该稿没有安全重试入口。

- `item/started`、输出增量和 `item/completed` 必须原位更新同一个稳定 item，禁止终态回退。
- 状态不能只依赖颜色；图标、状态文字和 TalkBack 语义必须同时存在。
- 命令和输出使用等宽字体，默认只展示有界预览；复制是辅助动作，不抢占主层级。
- 失败色只作用于失败 item、退出代码和错误输出，已经成功的步骤保持成功语义。
- 手机使用可折叠内嵌卡片；宽屏在 Inspector 同步展示最近一组活动，不复制两套状态。
- 旧状态稿中的 `Retry` 只代表未来具备安全重试协议时的方向；当前协议未提供精确重试入口，因此实现不得伪造该动作，v2 稿已移除该控件。

## 会话 Inspector

`android-inspector-sections-v1.png` 使用 OpenAI 内建 image generation 生成，定义宽屏 supporting pane 的 Android 原生信息架构：Overview 承载会话状态、上下文和 allowlist quick actions，Changes 承载 Git 文件、hunk 与安全确认操作，Activity 承载结构化条目和有界脱敏原始输出。应用设置、诊断、外观、语音、档案、Worktree 与法律信息不属于会话 Inspector，必须保持独立导航目的地。

`android-context-components-v1.png` 进一步约束 320dp Overview 窄栏中的 Environment、Git、Tasks、Sources 与 Subagents 组件。它们是只读会话上下文，不提供重试或隐式执行入口；任务必须来自 thread/turn 或实时 item 投影，状态同时使用文字、图标和颜色，命令、路径与 SHA 使用有界等宽文本。

`android-goal-lifecycle-v1.png` 定义 Material 3 Goal 生命周期组件：Inspector 卡片展示 objective、状态、Token 进度、用时和更新时间；状态按钮严格由当前状态决定，编辑器只修改目标与可选正整数预算，清除必须二次确认。同步期间禁用重复操作，编辑和清除只有在服务端确认成功后才关闭；状态切换采用 app-server 部分字段更新，不得隐式覆盖目标或预算。

`android-session-library-v1.png` 定义 Android 会话库：使用“全部 / 进行中 / 需处理 / 历史”FilterChip，按活动与历史分区；每行以文本、进度指示和语义色共同表达审批、输入、运行、失败、完成、空闲与历史状态，并以次级胶囊承载 Goal、提醒、运行时等元数据。状态过滤不得只依赖当前选中会话，必须消费 thread/list 的原始状态和跨会话待处理请求。

`android-user-input-flow-v1.png` 定义长用户问题表单：紧凑窗口采用全高 Material 3 Modal Bottom Sheet，宽屏采用最大 560dp 的居中 Dialog；问题内容独立滚动，提交与跳过操作固定在 IME/导航栏 inset 上方。选项必须分别展示服务端 label 与 description，单选使用 RadioButton、多选使用 Checkbox；每个触控目标至少 48dp。关闭交互层后显示“继续填写”卡并保留当前请求草稿，所有问题均有答案后才启用主提交按钮。

`android-queued-turn-manager-v1.png` 使用 OpenAI 内建 image generation 生成，定义待发送队列的 Material 3 信息结构。会话页只保留两条紧凑预览和明确的“管理”入口；完整管理层在紧凑窗口使用 Modal Bottom Sheet，在宽屏使用最大 560dp 的居中 Dialog。每条消息同时展示状态图标、状态文字、冻结的模型/推理/权限元数据及附件摘要；发送中条目禁止编辑与重排，失败条目使用 error container 并显示有界失败原因。编辑可移除本地图片和 Skill 附件，重排必须原子落盘，“立即引导当前回复”仅在当前 turn 活跃且连接就绪时开放，删除保持危险操作语义。

`android-approval-flow-v1.png` 使用 OpenAI 内建 image generation 和现有应用截图作为视觉参考，定义审批主卡与持久权限确认层。主卡位于 Composer 上方，使用 tertiary container 表达“需要注意但尚非错误”，并以图标、标题、类型、风险、影响数量和可折叠详情共同提供决策上下文；拒绝使用 error outline，单次批准保持主动作，决定发送期间卡片不得消失。缺少可验证正文或明确旧命令标题时只允许拒绝。只有服务端同时给出 `acceptWithPermissionUpdate` 与精确本地规则时才显示“始终允许”，紧凑窗口通过 Modal Bottom Sheet、宽屏通过最大 560dp Dialog 二次确认，并明确规则只写入当前项目本地设置。
