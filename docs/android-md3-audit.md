# Android 17 / Material 3 视觉审计

审计目标：`android/app` 的 Jetpack Compose 界面，以及 Pixel 8 / Android 17（API 37）上的真实连接态。

参考：

- [Material Design 3](https://m3.material.io/)
- [Material Design 3 in Compose](https://developer.android.com/develop/ui/compose/designsystems/material3)
- [hamen/material-3-skill](https://github.com/hamen/material-3-skill) v1.1.1
- Imagegen 视觉方向：`android/design/android17-m3-expressive-v1.png`

## 结论

功能迁移完成后的首轮界面已经从“所有内容使用同一种大卡片”收敛为 Material 3 的语义层级。真机保持用户当前的大字号偏好，仍能在一屏展示 3 条会话、完整底部导航和全部关键操作。视觉实现继续使用 Compose 与主题 token，Imagegen 产物只作为参考稿，不进入运行时 UI。

整体评分：83 / 100（改造前约 72 / 100）。

| 类别 | 得分 | 结果 | 说明 |
|---|---:|---|---|
| 颜色 token | 8/10 | 通过 | 运行时组件使用 `MaterialTheme.colorScheme`；动态色、深浅色和固定色板均保留。会话、Composer、设置改用 surface container 层级，减少 primary-container 滥用。 |
| 排版 | 8/10 | 通过 | 标题、正文、标签继续使用 MD3 type scale；长会话标题限制为两行，135% 字号下不再占据三至四行。 |
| 形状 | 8/10 | 通过 | 新增统一 `MimiShapes`；搜索、主操作、消息、设置分组使用 full / medium / large 语义形状。 |
| 层级 | 8/10 | 通过 | 主要依靠 tonal surface，而非阴影；助手正文回到基础 surface，进度更新和设置分组使用低层容器。 |
| 组件 | 9/10 | 通过 | 使用 Material 3 NavigationBar/Rail、TextField、FilterChip、Card、Surface、Button 和 IconButton。 |
| 布局 | 9/10 | 通过 | 保留 compact/medium/expanded、supporting pane、tabletop 与 separating hinge 策略；紧凑页改用 8dp 节奏。 |
| 导航 | 9/10 | 通过 | 手机底部导航、中宽/大屏 Navigation Rail、详情预测返回均已通过真机和设备测试。 |
| 动效 | 6/10 | 警告 | 已有预测返回和系统组件状态动效；尚未为列表筛选、消息插入和 pane 变化增加统一的 Expressive spring motion。 |
| 无障碍 | 9/10 | 通过 | 48dp 触控目标、TalkBack 语义、确定性 IME 顺序和 200% 字号继续通过设备测试。 |
| 主题 | 9/10 | 通过 | `MaterialTheme` 统一提供 color/typography/shapes，支持系统/浅色/深色、动态色及四套固定色板。 |

## 本轮落地

1. 新增 `MimiSpacing` 和 `MimiShapes`，建立 4/8/12/16/24/32dp 的共享节奏。
2. 会话页采用圆角 filled search container、全宽主操作和低层会话容器；状态与路径合并为紧凑元数据行。
3. 普通助手正文不再套卡片；用户消息保持 primary container，commentary 保持 secondary container。
4. Composer 改为 `surfaceContainerLow`，能力、模式、模型、推理强度和权限统一为可横向滚动的紧凑控制，发送为唯一高强调动作。
5. 设置页将诊断、通知、默认权限、外观和语音输入分成独立 tonal groups，所选权限使用 secondary container。
6. `PaneHeader` 限界长标题并降低详情页标题字号，在大字号下保留内容空间。

## 后续非阻塞优化

- 在 Material 3 Expressive API 稳定后，为筛选、会话选择和消息插入统一 spring motion。
- 将仍集中在 `MimiRemoteApp.kt` 的大型设置/Inspector 组件拆分为独立文件，降低后续视觉迭代成本。
- 增加中等/高对比度主题选择；现有颜色对比已满足当前设备验收，但尚未暴露三档对比设置。

## 验收证据

- 改造前：`android/captures/mimi-audit-list.png`、`mimi-audit-detail.png`
- 改造后：`android/captures/mimi-m3-list-v2.png`、`mimi-m3-detail-v2.png`、`mimi-m3-settings-v1.png`、`mimi-m3-final.png`
- Imagegen 参考：`android/design/android17-m3-expressive-v1.png`
- 自动化：175 项 JVM 测试、39 个 suite、0 failure/error/skipped；Lint 0 error / 15 warnings。
- Pixel 8/API 37：`SessionLibraryDeviceTest + AppearanceThemeDeviceTest + AccessibilityDeviceTest` 字面量 `OK (8 tests)`。
