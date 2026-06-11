# Mimi Remote 隐私政策

生效日期：2026-06-09

## 目标

本隐私政策说明 iPad App「Mimi Remote」如何处理数据。

Mimi Remote 是一个面向开发者的 iPad 原生客户端，用来连接用户自己 Mac 上运行的 `agentd`。本 App 是独立开发的第三方客户端，不隶属于 OpenAI，也不代表 OpenAI 官方产品。

## 数据收集

Mimi Remote 不收集、上传、出售或共享用户的个人数据。

本 App 不包含第三方分析 SDK，不进行广告追踪，不上传崩溃日志、使用统计、项目内容、终端输出、对话内容、代码文件或凭证到开发者服务器。

## 本地保存的数据

为完成连接和使用流程，Mimi Remote 会在用户设备本地保存少量配置数据：

- 用户配置的 Mac `agentd` endpoint。
- 用于连接用户自己 Mac 上 `agentd` 的访问 token。
- 最近使用的工作区、会话索引、外观设置等本地偏好。

其中访问 token 会保存在 iOS Keychain 中。上述数据仅用于连接用户自己配置的 Mac 端服务，不会发送给本 App 开发者。

## Mac 端与第三方服务

Mimi Remote 本身不在 iPad 上执行代码，也不下载可执行代码。它只连接用户自己 Mac 上运行的 `agentd`。

如果用户在 Mac 上使用 Codex CLI、OpenAI API 或其他第三方开发工具，这些工具的数据处理方式由对应服务或工具的条款和隐私政策约束。Mimi Remote 不托管这些第三方账号凭证，也不会从用户 Mac 主动收集这些凭证。

## 网络连接

Mimi Remote 会连接用户手动配置或扫码导入的 Mac endpoint。推荐仅在本地网络或 Tailscale 等私有网络中使用，不建议将 `agentd` 暴露到公网。

## 儿童隐私

Mimi Remote 面向开发者工具场景，不专门面向儿童。由于本 App 不收集个人数据，也不会有意收集儿童个人信息。

## 政策变更

如果未来加入崩溃分析、遥测、远程日志、账号系统或云同步等能力，本隐私政策和 App Store 隐私披露会同步更新。

## 联系方式

如果你对本隐私政策有疑问，可以联系：

gaixg94@gmail.com
