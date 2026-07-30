# Mimi iOS / agentd 版本化契约

## 目标

让 iOS 客户端与 `agentd` 的 REST / WebSocket 边界具备明确、可执行的兼容窗口。字段新增、删除、类型变化或最低版本要求改变时，Go、Swift 和 PR Gate 必须给出确定结果，不能等到用户连接后才发现单端模型已经漂移。

这套契约只覆盖 Mimi 自身的 iOS ↔ `agentd` API。Codex app-server 上游协议继续以 [Codex 协议支持边界](codex-protocol-support.md) 和现有快照为准，两者不能互相替代。

## 方案

### 权威来源

`contracts/mimi-protocol/` 是 Mimi 协议的权威目录：

- `contract.json`：当前修订、最低兼容客户端/服务端修订、握手 header 和公开 capabilities；
- `fixtures/version-current.json`：当前 `/api/version` 线协议；
- `fixtures/version-previous.json`：上一版 agentd 缺少新增字段时的兼容样例；
- `fixtures/version-incompatible.json`：服务端明确要求更高客户端修订时的失败样例；
- `fixtures/client-matrix.json`：上一版、当前、纯加法新客户端和不兼容客户端的服务端预期。

`internal/protocolcontract/generated.go` 与
`ios/MimiRemote/Sources/Core/Models/ProtocolContract.generated.swift` 由 manifest 生成，不是人工编辑入口。生成文件同时带 manifest SHA-256；CI 会拒绝只修改 manifest、没有同步生成结果的提交。

### 修订与握手

当前协议修订为 `2`，兼容窗口至少保留 revision `1`：

- 当前 `agentd` 最低支持客户端 revision `1`；
- 当前 iOS 最低支持服务端 revision `1`；
- revision `1` 客户端没有协议 header，服务端把完整缺失视为上一版客户端；
- revision `1` 服务端没有 `protocol_revision` 和
  `minimum_client_protocol_revision`，iOS 按上一版安全默认值解码；
- 当前客户端在每个已认证 REST 请求和 WebSocket Upgrade 中发送
  `X-Mimi-Protocol-Revision` 与
  `X-Mimi-Minimum-Server-Protocol-Revision`；
- 服务端响应带当前服务端修订窗口 header，确保 WebSocket Upgrade 失败时即使拿不到 JSON body 也能诊断。

兼容判断使用双方声明的“最低要求”，不单纯比较版本大小。更高修订的客户端如果仍声明支持当前服务端，可以继续使用纯加法能力；如果依赖新语义，必须提高最低服务端修订，旧 `agentd` 会在认证后、业务处理前返回 HTTP `426` 和结构化 `protocol_incompatible`。

### 跨版本矩阵

| 客户端 | agentd | 预期 |
| --- | --- | --- |
| revision 1，无握手 header | revision 2 | 成功；新增响应字段被旧模型忽略 |
| revision 2 | revision 2 | 成功；revision、最低客户端修订和 capability 均明确 |
| revision 2 | revision 1，无新增版本字段 | 成功；按 revision 1 解码，缺失 capability 降级为空集合 |
| revision 3，最低服务端仍为 1 | revision 2 | 成功；只允许纯加法客户端演进 |
| revision 3，最低服务端为 3 | revision 2 | HTTP `426`；REST 返回结构化错误，WebSocket 保留诊断 header |
| revision 2 | revision 3，最低客户端为 3 | iOS 在进入业务链路前返回明确升级错误 |
| 任一握手 header 缺失、非正整数或窗口自相矛盾 | revision 2 | HTTP `400 protocol_metadata_invalid`，不猜测兼容性 |

capability 只决定功能是否可用，不替代协议兼容判断。旧服务端缺少 capability 时，客户端必须隐藏入口或给出明确升级提示，不能根据 marketing version 猜测。

## 实现

### 更新流程

1. 先编辑 `contracts/mimi-protocol/contract.json` 和对应 fixtures。
2. 生成两端常量：

```bash
go run ./internal/protocolcontract/cmd/generate --write
```

3. 运行快速契约检查：

```bash
bash ./scripts/check-mimi-protocol-contract.sh
```

4. 运行统一 Gate 与两端回归：

```bash
bash ./scripts/check-pr-gate.sh
go test ./... -count=1
bash ./scripts/ios-dev.sh target
bash ./scripts/test-conversation-regressions.sh
```

`contracts/mimi-protocol/**`、生成器、契约脚本或本文档变化时，MIM-27 的路径分类会同时要求 Go 与 iOS job；最终 `PR Gate` 只有在两端和契约检查都成功时才通过。

### 字段演进规则

- 优先新增可选字段；旧客户端缺失时必须有安全默认值。
- 禁止无迁移删除字段、改变 JSON 类型或复用已有字段表达新语义。
- capability 名称一旦公开不得静默改义；废弃能力先停止声明，再经过至少一个兼容窗口后清理实现。
- 需要破坏性变化时先提高协议修订，并通过最低兼容修订明确切断旧端；同时增加可诊断失败 fixture。
- 当前 fixture 必须同时能被 Go 编解码测试和 Swift `Codable` 测试消费；不能只更新一端测试让 CI 变绿。
- 不把真实 Token、设备地址、工作目录、仓库或用户数据写入 fixtures。

## 风险与优化

- 当前采用单仓库 manifest、生成器和 golden fixtures，适合小团队且无需 Schema Registry。若 API 数量继续增长，再评估从 OpenAPI / JSON Schema 生成更多模型；当前不提前引入。
- revision 1 客户端没有 header，只能按已记录的上一版窗口识别。未来提高最低客户端修订前，必须先确认活跃旧版本已经完成迁移。
- 纯加法兼容依赖 capability 和安全默认值。新增能力时仍需补两端 fixture 与实际功能测试；本机制不替代 MIM-29 的用户链路回归，也不建设 MIM-30 的通用 capability/降级开关。
- 这套检查进入快速 PR Gate，不扩展 Nightly 或 Release 编排；更重的长期组合测试留给后续真实故障数据驱动。
