# iOS 对话区 Markdown 渲染设计方案

> 分支：`codex/ios-markdown`（基于 `direct-app-server-client`）
> 范围：仅 iOS 原生 App（`ios/CodexAgentPad`）。Web/PWA 不在本方案内。
> 目标范围：GFM 完整（标题 / 强调 / 列表 / 引用 / 链接 / 行内代码 / 围栏代码 / 表格 / 任务列表 / 删除线）。

---

## 1. 背景与目标

### 现状
对话区中间气泡当前是**纯文本**渲染。链路如下：

```
ConversationMessage.content (String, 流式 didSet 改写)
  → MessageRenderPlanCache.plan(for:)           // LRU 缓存 + 增量解析
  → MessageRenderPlan { segments: [MessageRenderSegment] }   // 只切 text / code 两类
  → MessageBubble.renderContent
       └ Text(segment.text)  // 纯文本；code 段只是 monospaced + 灰底
```

`MessageRenderPlanCache.parseSegments`（[AgentModels.swift:351](../ios/CodexAgentPad/Sources/Core/Models/AgentModels.swift)）只识别 ` ``` ` 围栏，把内容切成 `.text` / `.code` 段，**没有任何真正的 Markdown 解析**：`**粗体**`、`# 标题`、`- 列表`、表格、链接全部按字面文本显示。

### 目标
1. assistant 回复按 GFM 渲染（标题层级、强调、列表/嵌套、引用、链接、行内/围栏代码、表格、任务列表、删除线）。
2. **不破坏现有三大性能机制**（见 §2），流式输出仍然顺滑。
3. 跟随主题（深/浅/高对比）、字号缩放（`ThemeStore.fontScale`）、用户/助手两种气泡配色。
4. 选择复制、链接可点（带 scheme 白名单）。

### 非目标（本期不做）
- Web/PWA 端。
- 代码块**语法高亮**（先做等宽 + 语言标签 + 横向滚动；高亮列为后续可选项，见 §9）。
- system 运行卡片（`RuntimeSummaryCard`：推理摘要 / 命令 / 文件变更 / 审批 / 错误）重构——它们是结构化卡片，保持原样。
- 图片远程加载、Mermaid、数学公式（LaTeX）。

---

## 2. 现状梳理：三条必须保住的红线

方案的难点不在"能不能渲染 Markdown"，而在**不能把现有为流式精心打磨的渲染管线推翻**。下面三条是硬约束：

| 机制 | 位置 | 作用 | 对本方案的含义 |
|------|------|------|----------------|
| **流式增量解析** | `MessageRenderPlanCache.extend` | 新内容若以旧内容为前缀，只解析**新增后缀**并 merge，避免每个 token 重解析整条消息 | Markdown 是**非局部**的（后来的 `**` 会改变前文强调；表格要等分隔行）。不能再做"字节后缀 merge"，要改成**块级增量**（§4.2） |
| **LRU 渲染缓存** | `MessageRenderPlanCache`（256 条） | 按 messageKey + contentDigest 缓存解析结果 | 缓存 value 从 `[MessageRenderSegment]` 升级为 `[MarkdownBlock]`，键值策略不变 |
| **行级复用 + 指纹** | `MessageRow.equatable()` + `renderFingerprint` + `List`（UITableView） | 流式只重绘内容变化那一行；行高真实、scrollTo 可靠 | `renderFingerprint` 仍由 `contentDigest/Revision/ByteCount` 决定，**继续有效**（块由 content 派生）。新渲染视图必须保持 `Equatable`/`Hashable` 值语义 |

其它现状约束：
- **部署目标 iOS 26.0**（`project.yml`）→ 可用最新 SwiftUI，无向后兼容包袱。
- **当前零第三方 Markdown 依赖**；测试依赖仅 SnapshotTesting。
- **配色**：`MessageBubble` 目前直接用系统语义色（`Color(.secondarySystemBackground)`、`.primary`、`Color.accentColor`），并**没有**消费 `ThemeStore.tokens`。本方案沿用"系统语义色为主"的既有风格，避免引入与现状不一致的配色源（§4.4）。
- **复制**：`contextMenu` 复制的是 `message.content` 原文（Markdown 源码）——这个行为**要保留**（开发者常想要源码）。

---

## 3. 选型对比（核心决策）

GFM 完整范围里**表格**是分水岭：Apple 内置的 `AttributedString(markdown:)` **不支持表格**，也不支持块级布局。所以选型围绕"谁来解析 + 谁来渲染"：

| 方案 | 解析 | 渲染 | 依赖 | GFM 表格 | 流式可控性 | 评价 |
|------|------|------|------|:---:|:---:|------|
| **A. `AttributedString(markdown:)` 内置** | Foundation 内置 | `Text(AttributedString)` | 无 | ❌ | 中 | 只渲染**行内**属性（粗/斜/码/链接/删除线）；块结构（标题大小、列表项、代码块框、表格）SwiftUI `Text` 不认，需自己遍历 `presentationIntent` 重组。**无表格** → 只适合把范围降到 "CommonMark 行内" |
| **B. `swift-markdown`（Apple）AST + 自绘渲染** ⭐ | swift-markdown（cmark-gfm） | 自写 `MarkdownBlockView` | +1（Apple 维护） | ✅ | **高** | 真·AST（`Document`/`Markup` visitor），完整 CommonMark+GFM。渲染与流式策略完全可控，能无缝接进现有缓存/指纹/行复用。代价：要写一层 AST→SwiftUI 渲染 |
| **C. `swift-markdown-ui`（MarkdownUI，第三方）** | 内部自带 | 库内置 SwiftUI | +1（社区） | ✅ | 低-中 | 上手最快，`Markdown(text)` 一行出图，主题化强。但它**接管整条消息的渲染与 diff**，长消息流式逐 token 刷新时它倾向整体重解析，难塞进现有"块级增量 + 行指纹"模型；依赖较重 |

### 推荐：方案 B（`swift-markdown` + 自绘）

理由：
1. **本项目对流式性能有重投入**（`MessageRenderPlanCache` 的增量 merge、`.equatable()` 行复用、`ParsingPerformanceTests`）。B 能把 Markdown 解析**接进**这套机制（块级增量），而不是绕开它。
2. GFM 完整（表格/任务列表/删除线）开箱即得，解析器由 Apple（swiftlang）维护，质量与长期可用性有保障。
3. 渲染、主题、配色、字号、选择/链接全部自己掌控，能与既有气泡视觉统一。
4. iOS 26 下 SwiftUI 表达力足够，自绘成本可控。

代价：要写 AST→SwiftUI 的渲染层（§4.3）。这是**一次性**成本，且能用快照测试钉死。

**备选 C**：若要"两天内上线、可接受第三方依赖与较弱的流式控制"，用 MarkdownUI 直接 `Markdown(message.content)` 替换 `renderContent`，放弃块级增量、靠 SwiftUI 自身 diff 扛流式。见 §10 的取舍与回退判据。

**降级 A**：若决定**砍掉表格**把范围降到 "CommonMark 行内 + 代码块"，则可零依赖，用 `AttributedString(markdown:)` 出行内属性 + 沿用现有围栏切块。见 §9 分期里的"最小集"路径。

---

## 4. 推荐方案（B）详细设计

### 4.1 数据模型：用 `MarkdownBlock` 替换 `MessageRenderSegment`

把"两类段"升级为"块模型"。新增 `Core/Models/MarkdownBlock.swift`：

```swift
// 全部值类型，Hashable/Equatable，保证 List 行复用与缓存键稳定。
enum MarkdownBlock: Hashable, Identifiable {
    case paragraph(InlineText)                          // 段落
    case heading(level: Int, InlineText)               // # ~ ######
    case bulletList(items: [ListItem], tight: Bool)    // - / *
    case orderedList(start: Int, items: [ListItem], tight: Bool)
    case taskList(items: [TaskItem])                   // - [ ] / - [x]
    case blockquote(blocks: [MarkdownBlock])           // 可嵌套
    case codeBlock(language: String?, code: String)    // 围栏 / 缩进
    case table(header: [InlineText], rows: [[InlineText]], align: [ColumnAlign])
    case thematicBreak                                  // ---
    var id: Int { hashValue }
}

struct ListItem: Hashable { let blocks: [MarkdownBlock] }   // 列表项可含多块/嵌套列表
struct TaskItem: Hashable { let checked: Bool; let inline: InlineText }

// 行内文本：解析阶段就压成一个可直接渲染的 AttributedString，
// 渲染层零解析、纯展示，流式重绘最便宜。
struct InlineText: Hashable {
    let attributed: AttributedString   // 已含 .bold/.italic/.strikethrough/inlineCode/.link
    let plain: String                  // 选择/复制/无障碍回退
}
enum ColumnAlign: Hashable { case leading, center, trailing }
```

对应改造 [AgentModels.swift](../ios/CodexAgentPad/Sources/Core/Models/AgentModels.swift) 里的 `MessageRenderPlan`：

```swift
struct MessageRenderPlan: Hashable {
    let messageKey: String
    let content: String
    let contentDigest: UInt64
    let contentByteCount: Int
    let blocks: [MarkdownBlock]          // ← 原 segments
    let openTailByteOffset: Int          // ← 流式：最后一个"稳定块"的结束字节位
    var isSinglePlainParagraph: Bool { … } // 快路径：单段无格式时仍走最轻的 Text
}
```

> 行内为何在解析期就生成 `AttributedString`：SwiftUI `Text` 能**原生**渲染带 `.bold/.italic/.strikethrough/link/monospaced` 的 `AttributedString`，且可选择。把行内属性在解析期一次算好，渲染层只 `Text(inline.attributed)`，是流式下最省的组合。

### 4.2 解析：块级增量 + 块内全量

核心思想：**Markdown 在"块"这一层基本是局部的**。一旦一个块被空行/下一个块边界封口，后续追加不会再改它（少数例外见 §8）。于是：

```
完整重解析（仅首次/非前缀变化）：
  swift-markdown 解析 content → Document → 遍历 Markup → [MarkdownBlock]

流式增量（新内容以旧内容为前缀，常态）：
  从 plan.openTailByteOffset 起切出"尾部开放区"
  只对尾部区重新解析 → 替换最后 N 个块
  openTailByteOffset 前的顶层块直接复用（命中缓存，零解析）
  ⇒ 每个 delta 的解析量 = O(最后一个块大小)，与现有"后缀 merge"同量级
```

实现要点（重写 `MessageRenderPlanCache`，对外签名不变）：
- **稳定前缀规则**：把"最后一个顶层块的起点"之前判为稳定，缓存冻结；最后一个顶层块始终跟流式尾部一起重解析。这样比单纯按空行冻结更保守，但能避开 loose list、blockquote、setext 标题等"空行后仍可能续写前块"的边界。GFM 表格额外处理"table 后紧贴 paragraph"的流式半行状态：如果两者中间没有空行，从 table 起点重算，避免半行数据被永久冻结成普通段落。
- **只重解析最后一个顶层块 + 新增尾部**，规避 setext 标题、惰性续行、列表/引用延续等"回头改前块"的情况（§8）。代价仍是常数级，且比整条消息重解析轻很多。
- **开放结构**：未闭合围栏（现状已用 `openCodeFenceLanguage` 处理）、未补分隔行的表格、未闭合的行内 `*`/`` ` `` —— 一律按"当前最佳"渲染（如未闭合 `**` 先按字面星号显示），闭合后下一帧自然收敛。
- AST→Block 用一个 `MarkupVisitor`；行内节点（`Strong`/`Emphasis`/`InlineCode`/`Link`/`Strikethrough`/`Text`）折叠进 `AttributedString`。
- LRU(256)、`contentDigest`/`contentByteCount` 命中逻辑、`renderFingerprint`**完全沿用**。

新增 `Core/Parsing/MarkdownParser.swift`：`func blocks(from: String, reusing: MessageRenderPlan?) -> (blocks, openTailByteOffset)`，把 swift-markdown 依赖隔离在这一处，便于将来替换解析器或写单测。

### 4.3 渲染：`MarkdownBlockView`

新增 `Features/Conversation/MarkdownBlockView.swift`，把 `MessageBubble.renderContent`（[ConversationView.swift:470](../ios/CodexAgentPad/Sources/Features/Conversation/ConversationView.swift)）从"遍历 segments"改为"遍历 blocks"：

```swift
VStack(alignment: .leading, spacing: style.blockSpacing) {
    ForEach(plan.blocks) { block in
        MarkdownBlockView(block: block, style: style)
    }
}
```

各块映射（iOS 26 SwiftUI）：

| Block | 渲染 |
|------|------|
| `paragraph` | `Text(inline.attributed)`，`.textSelection(.enabled)`，`fixedSize(vertical)` |
| `heading(level)` | `Text` + 按层级的字号/字重（h1…h6 递减），上下留白 |
| `bulletList`/`orderedList` | `VStack` 行：前导符（`•` / `1.`）+ 内容；嵌套靠 `leading padding` 递进；`tight` 控制行距 |
| `taskList` | `Image(systemName: checked ? "checkmark.square.fill" : "square")` + `Text`（只读展示，不回写） |
| `blockquote` | 左侧 `accent` 竖条 + 缩进，递归渲染内部 blocks |
| `codeBlock` | **复用现状代码块视觉**：等宽、`codeBlock` 底色、圆角；顶部小字语言标签；**横向 `ScrollView`** 防长行撑破气泡；右上"复制代码"按钮（复制该块原文） |
| `table` | 用 `Grid`（iOS 16+，26 可用）：表头加粗 + 分隔线，按 `ColumnAlign` 对齐，整体可横向滚动；超窄屏降级为堆叠展示 |
| `thematicBreak` | `Divider()` |

行级复用维持现状：`MessageRow.equatable()` 仍只比 `id/role/kind/sendStatus/revision/renderFingerprint`，blocks 由 content 派生，无需改判等逻辑。

### 4.4 主题 / 角色样式：`MarkdownStyle`

新增 `Features/Conversation/MarkdownStyle.swift`，一个值类型，按"角色 + 配色环境"产出：

```swift
struct MarkdownStyle: Equatable {
    let baseFont: Font            // 受 ThemeStore.fontScale 影响
    let textColor: Color         // assistant=.primary / user=.white
    let secondaryColor: Color
    let linkColor: Color         // user 气泡里需高可读变体
    let codeForeground: Color
    let codeBackground: Color     // 现状已按 user/assistant 区分
    let quoteBar: Color          // accent
    let blockSpacing: CGFloat
    static func make(role: ConversationMessage.Role,
                     colorScheme: ColorScheme,
                     fontScale: Double) -> MarkdownStyle
}
```

要点：
- **沿用系统语义色**（与现状 `MessageBubble` 一致），不引入新的配色源；`accent` 取 `Color.accentColor`。如果将来要切到 `ThemeStore.tokens`，只改这一个工厂即可。
- **user 气泡是 accent 底 + 白字**：链接、行内码、引用条要用在强调底色上仍可读的变体（如 `Color.white.opacity(0.16)` 码底，已是现状做法）。
- **字号**：`baseFont` 乘 `ThemeStore.fontScale`，让标题/正文/代码整体随设置缩放（现状 `Text(.body)` 未缩放——本方案顺手补上）。
- **谁渲染 Markdown**（建议，留作决策点）：
  - assistant `.message` → **完整 Markdown**。
  - user `.message` → 默认**保持纯文本**（用户输入所见即所得，避免把用户打的 `*` 吞掉）；可加设置项后续开启行内渲染。
  - system / `RuntimeSummaryCard` 各 kind → 维持结构化卡片不变。

### 4.5 链接 / 选择 / 复制 / 安全

- **链接**：`AttributedString.link` 由 `Text` 原生可点，走 `\.openURL`。**scheme 白名单**：仅 `http`/`https`/`mailto` 渲染为可点链接，其余（`javascript:`/`file:`/自定义 scheme）降级为普通文字，避免原生端被诱导跳转。
- **选择**：块级 `Text` 保留 `.textSelection(.enabled)`。
- **复制**：气泡 `contextMenu` 仍复制 `message.content` **原始 Markdown**（保留现状）；代码块额外提供"复制本块"。
- 原生端无 Web 的 XSS 面，但仍要 scheme 白名单 + 不自动发起网络（图片暂不远程加载）。

---

## 5. 改动点（文件级）

| 文件 | 改动 |
|------|------|
| `ios/CodexAgentPad/project.yml` | `packages:` 增加 `swift-markdown`（`https://github.com/swiftlang/swift-markdown`），target 依赖加 `Markdown` product |
| `…/xcshareddata/swiftpm/Package.resolved` | 解析后新增 swift-markdown / swift-cmark pin（xcodegen 后自动） |
| **新增** `Sources/Core/Models/MarkdownBlock.swift` | `MarkdownBlock` / `InlineText` / `ListItem` 等模型 |
| **新增** `Sources/Core/Parsing/MarkdownParser.swift` | swift-markdown AST → `[MarkdownBlock]`，隔离解析依赖 |
| `Sources/Core/Models/AgentModels.swift` | `MessageRenderPlan.segments`→`blocks`+`openTailByteOffset`；`MessageRenderPlanCache` 重写为块级增量（对外 `plan(for:)` 签名不变） |
| **新增** `Sources/Features/Conversation/MarkdownBlockView.swift` | block→SwiftUI 渲染 |
| **新增** `Sources/Features/Conversation/MarkdownStyle.swift` | 角色/主题/字号样式 |
| `Sources/Features/Conversation/ConversationView.swift` | `MessageBubble.renderContent` 改遍历 blocks；`segmentView` 移除/并入 |
| `Tests/CodexAgentPadTests/` | 新增 Markdown 解析/增量单测；扩展 `ParsingPerformanceTests`；更新 `ConversationSnapshotTests` 基线 |

> `MessageStore` 是 `ConversationStore` 的 typealias，事件流/分页/local-echo（`EventReducer`、`ConversationStore`）**无需改动**——本方案纯渲染层，不碰数据流与协议。

---

## 6. 流式与性能

- **解析量级**：稳态每 delta 只重解析最后一个顶层块与新增尾部，与现状"后缀 merge"接近；首屏/非前缀变化才整篇解析（与现状一致）。
- **渲染量级**：行级 `.equatable()` 不变 → 流式只重绘最后一行；该行内部只有"开放块"重建视图，已封口块的 `MarkdownBlock` 值不变、SwiftUI 直接复用子视图。
- **缓存**：LRU 256 不变；`InlineText` 在解析期算好，渲染期零解析。
- **代码块/表格**长行用横向 `ScrollView`，不参与气泡宽度计算，避免长输出把行高/滚动条算乱（呼应现状用 `List` 的初衷）。
- **性能门槛**：扩展 `ParsingPerformanceTests`，对"长表格 / 深嵌套列表 / 大代码块"在流式逐帧追加场景设单帧解析耗时上限，纳入 CI 防回归。

---

## 7. 测试方案

1. **解析单测**（新增）：GFM 各结构 → 期望 `[MarkdownBlock]`；含表格对齐、任务列表勾选、嵌套列表、未闭合围栏/强调的"流式中途"快照。
2. **增量正确性**：对同一目标文本，逐字符喂入 `MessageRenderPlanCache`，断言最终 blocks 与"一次性解析"等价（钉死块级增量不产生偏差），并断言 `openTailByteOffset` 前的块对象未被重建（复用计数，类比现状 `incrementalReuseCountForTesting`）。
3. **快照测试**（`ConversationSnapshotTests`）：新增"富 Markdown 会话"fixture（标题/列表/引用/表格/代码/链接，深浅 + 高对比 + 不同 fontScale），更新基线 PNG。
4. **性能测试**：见 §6。
5. **手动验收**：真机/模拟器跑一条会输出表格+代码+列表的 Codex 回复，观察流式收敛、选择、链接点击、复制源码/复制代码块、深浅色切换。

---

## 8. 风险与边界

| 风险 | 说明 | 缓解 |
|------|------|------|
| 块级增量的"回头改前块" | setext 标题（下一行 `===` 把上段变标题）、惰性续行、引用/列表的延续 | 最后一个顶层块始终重解析；只冻结其前面的稳定块 |
| 流式中途的"半个语法" | 未闭合 `**`、表格只到表头、围栏未闭合 | 按"当前最佳"渲染，闭合后下一帧收敛；围栏沿用现状 open 处理 |
| 表格在窄屏 | iPad 分栏下表格可能超宽 | 横向滚动；极窄降级堆叠 |
| 代码块长行 | 撑破气泡 | 横向滚动，独立于气泡宽度 |
| 字号缩放与行高 | fontScale 改变后 List 行高需重算 | blocks 经 `renderFingerprint` 之外的 style 变化触发重排；快照覆盖多档 fontScale |
| 依赖体积/构建 | 引入 swift-markdown + swift-cmark | Apple 维护、纯解析、体积可控；隔离在 `MarkdownParser.swift` 便于替换 |

---

## 9. 分期与工作量（建议）

> 可按需在任一期停手；范围越小越早可用。

- **P0 解析与模型**（~1d）：接入 swift-markdown，`MarkdownBlock` + `MarkdownParser` + 缓存块级增量 + 单测。无 UI，先用 dump 验证。
- **P1 基础渲染**（~1.5d）：段落/标题/强调/列表/引用/行内码/围栏码 + `MarkdownStyle` + 主题/字号。**此时已覆盖绝大多数 Codex 回复**。
- **P2 GFM 扩展**（~1d）：表格 + 任务列表 + 删除线 + 链接 scheme 白名单 + 代码块"复制/横向滚动"。
- **P3 打磨**（~1d）：快照基线、性能门槛、窄屏降级、无障碍（VoiceOver/Dynamic Type）。
- **可选 P4**：代码块语法高亮（轻量 tokenizer 或 `swift-highlight`/`Splash`）、user 消息行内渲染开关。

**降级路径**：若改为"CommonMark 基础（无表格）"，可走方案 A（`AttributedString(markdown:)`，零依赖），跳过 swift-markdown 与表格/任务列表渲染，工作量约减半，但失去 GFM 表格且块级布局仍需手动重组。

---

## 10. 备选方案 C（MarkdownUI）取舍

适用场景：要最快出活、可接受第三方依赖、且**暂不在意**超长流式消息的逐帧成本。

做法：`renderContent` 内 `Markdown(message.content).markdownTheme(...)`，主题映射到 `MarkdownStyle` 的等价配置，放弃 `MarkdownBlock`/块级增量，靠 SwiftUI 对 `Markdown` 视图自身 diff 扛流式。

回退判据（出现以下任一，回到方案 B）：
- 长消息（数千 token）流式时掉帧 / CPU 飙升（库整体重解析）。
- 与 `List` 行高测量、`scrollTo` 贴底出现竞态（呼应现状用 `List` 解决的问题）。
- 主题/字号/角色配色无法对齐现有气泡视觉。

---

## 附：决策点清单（待确认）

1. user 消息：纯文本（建议）/ 行内 Markdown / 完整 Markdown？
2. 代码块语法高亮：本期做 / 留 P4？（建议留 P4）
3. 方案 B（推荐，自绘可控）vs C（最快，依赖重）——本文按 **B** 展开。
