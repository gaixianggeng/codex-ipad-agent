// ConversationStore 已经承载分页消息、结构化 delta、local echo 和渲染缓存。
// 这里给新数据流一个明确的 MessageStore 名称，后续可以在不影响 View 的情况下继续收敛职责。
typealias MessageStore = ConversationStore
