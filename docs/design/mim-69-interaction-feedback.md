# MIM-69 统一交互反馈规则

## 目标

为高频触控、状态变化、面板呈现和手势落位提供最小语义入口，让新功能复用一致反馈，并完整支持 Reduce Motion。

## 方案

| 语义 | 普通模式 | Reduce Motion 等价反馈 |
| --- | --- | --- |
| `press` | 即时轻微缩放与透明度变化，临界阻尼回弹 | 仅短透明度变化，不缩放 |
| `stateTransition` | 临界阻尼状态过渡 | 短淡变，不做空间移动 |
| `presentation` | 面板沿来源方向呈现，可轻微自然回弹 | 仅淡入淡出，不做大范围位移 |
| `gestureSettling` | 继承手势结果并自然落位 | 直接到达最终位置，仅保留短淡变 |

统一入口为 `MimiMotion` 与 `MimiPressButtonStyle`。调用方在 Reduce Motion 下除了选择 fallback 曲线，还必须读取 `allowsScale` / `allowsSpatialMotion`，避免只换曲线却继续执行缩放或大范围位移。

## 实现

- Press 由 `ButtonStyle.Configuration.isPressed` 在触点按下时立即响应。
- Press 样式只拥有 pressed；Focus 使用 SwiftUI 原生 FocusState/focus effect，Hover 使用 `hoverEffect`。
- 视觉优先级为 `pressed > focused > hovered > resting`。Hover 只是指针增强，不得承载唯一信息或唯一入口。
- Haptic 只允许在 `commit`、`completion`、`failure`、`snap` 离散节点调用一次。持续的 preparing/loading/running 状态不得循环触发。
- `prepare` 只负责预热，`fire` 只负责发出一次反馈；两者不隐式串联。
- 每个业务节点由调用方拥有去重责任；基础层不使用时间窗口做全局去重，避免误伤合法连续操作。

## 风险与优化

- 本 Issue 不迁移全仓历史动画；后续功能应直接使用语义入口，历史参数按真实需求逐步收敛。
- `gestureSettling` 的 velocity handoff 与目标投影属于具体手势实现，不能被固定 token 代替。
- Haptic 必须在真机上做最终体感验证；Simulator 与单元测试只能验证事件映射和调用边界。
