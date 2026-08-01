# Capability 声明与本地降级

## 目标

让可选新能力在 iOS 与当前 `agentd` 主机之间显式协商，并在依赖异常或线上问题出现时，
能够只关闭该能力，不回滚整个版本、不清除 Token、连接档案或设备数据。

MIM-30 先用已经公开、能够独立降级的 `file_upload_v1` 闭环。基础会话、审批、Git 和
Worktree 链路不受这个开关影响。本机制不包含远端配置、账号级开关、灰度平台或新后端。

## 方案

### 稳定状态模型

`GET /api/version` 的 `capabilities` 只列出当前进程实际可用的能力；
`capability_statuses` 为每个当前版本已知能力给出稳定机器码：

| state | reason | 含义 | iOS 行为 |
| --- | --- | --- | --- |
| `enabled` | `available` | 本地未禁用且启动依赖检查通过 | 仅当前 Host 可走新路径 |
| `locally_disabled` | `disabled_by_local_config` | 当前 Mac 配置显式禁用 | 显示本地禁用，不发起文件请求 |
| `dependency_unavailable` | `storage_unavailable` | 私有文件缓存目录不可写 | 显示依赖不可用，不发起文件请求 |
| 缺失 | 缺失 | 旧版或服务端不支持 | 安全旧路径或明确不可用 |
| 未知值、重复值或自相矛盾 | 任意 | 协商失败 | fail-closed，要求重新连接 |

旧客户端会忽略 `capability_statuses` 新字段；未知 capability 不影响它认识的能力。
iOS 把协商结果存入 `ActiveHostState`，文件选择请求同时携带 Profile、安装身份和连接
generation。切换到另一台 Mac、切回同一台 Mac 的新 generation，或选择器打开期间
发生 Host 变化时，旧 lease 都会失效，不能沿用上一台主机的声明。

### 命名、版本与默认值

- 名称固定使用小写 `snake_case_vN`，例如 `file_upload_v1`。
- 只要线协议、权限或失败语义发生不兼容变化，就创建新的 `_vN`，不静默改义旧名称。
- 当前 `file_upload_v1` 是已有能力：本地没有禁用且缓存探测通过时继续默认启用，
  保持升级兼容；服务端探测失败和 iOS 尚未协商时一律默认关闭新路径。
- 新的高风险能力必须先具备依赖检查、服务端拒绝和客户端安全降级，才能加入公开
  capability manifest；不能只加客户端入口。
- 废弃时先停止声明并保留端点的可诊断拒绝至少一个兼容窗口，再删除实现。

### 权限边界

开关只由运行 `agentd` 的本机服务账户编辑 `config.json`，没有远程写入 API。
iOS、其他 Host 和远端动态配置都不能打开被服务端关闭的能力。`agentd` 在启动时生成
一次不可变能力快照；修改配置后必须重启，避免单个请求看到半更新状态。

## 实现

### 禁用 `file_upload_v1`

macOS / Linux 使用 `jq` 只修改 `capabilities.disabled`。临时文件和备份沿用配置文件
权限；命令不输出 Token：

```bash
CONFIG_PATH="${AGENTD_CONFIG:-$HOME/Library/Application Support/mimi-remote/config.json}"
BACKUP_PATH="${CONFIG_PATH}.before-file-upload-disable"
TEMP_PATH="$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")"
trap 'rm -f "$TEMP_PATH"' EXIT

cp -p "$CONFIG_PATH" "$BACKUP_PATH"
jq '
  .capabilities = (.capabilities // {})
  | .capabilities.disabled = (
      ((.capabilities.disabled // []) + ["file_upload_v1"]) | unique
    )
' "$CONFIG_PATH" > "$TEMP_PATH"
chmod 600 "$TEMP_PATH"
mv "$TEMP_PATH" "$CONFIG_PATH"
trap - EXIT

agentd restart --no-pair
agentd status --json | jq '{
  service_ok,
  capability: (
    .doctor.checks[]
    | select(.name == "capability-file-upload-v1")
  )
}'
```

Linux 默认路径改为：

```bash
CONFIG_PATH="${AGENTD_CONFIG:-$HOME/.config/mimi-remote/config.json}"
"$HOME/.local/bin/agentd" restart --no-pair
"$HOME/.local/bin/agentd" status --json
```

Windows PowerShell：

```powershell
$ConfigPath = if ($env:AGENTD_CONFIG) {
  $env:AGENTD_CONFIG
} else {
  Join-Path $env:AppData "mimi-remote\config.json"
}
$BackupPath = "$ConfigPath.before-file-upload-disable"
Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath -Force

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $Config.capabilities) {
  $Config | Add-Member -NotePropertyName capabilities -NotePropertyValue ([pscustomobject]@{})
}
$Disabled = @($Config.capabilities.disabled) + "file_upload_v1" |
  Sort-Object -Unique
$Config.capabilities |
  Add-Member -NotePropertyName disabled -NotePropertyValue $Disabled -Force
$Json = $Config | ConvertTo-Json -Depth 100
$Utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ConfigPath, $Json, $Utf8WithoutBom)

agentd restart --no-pair
agentd status --json
```

重启后：

- `/api/version` 不再声明 `file_upload_v1`，状态为 `locally_disabled`；
- `/api/file-uploads` 的 POST / GET / DELETE 都返回 HTTP `503` 和结构化
  `capability_locally_disabled`，旧客户端不能绕过；
- iOS 当前 Host 显示“本地禁用”，不会发送文件上传请求；
- `agentd status --json`、`/api/doctor` 和启动日志都包含同一状态机器码，不记录凭据。

### 恢复能力

确认问题解除后只移除目标项，保留其他本地开关：

```bash
CONFIG_PATH="${AGENTD_CONFIG:-$HOME/Library/Application Support/mimi-remote/config.json}"
TEMP_PATH="$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")"
trap 'rm -f "$TEMP_PATH"' EXIT

jq '
  .capabilities = (.capabilities // {})
  | .capabilities.disabled = (
      (.capabilities.disabled // [])
      | map(select(. != "file_upload_v1"))
    )
' "$CONFIG_PATH" > "$TEMP_PATH"
chmod 600 "$TEMP_PATH"
mv "$TEMP_PATH" "$CONFIG_PATH"
trap - EXIT

agentd restart --no-pair
agentd status --json | jq '
  .doctor.checks[]
  | select(.name == "capability-file-upload-v1")
'
```

缓存依赖仍不可写时，状态会变为 `dependency_unavailable`，不会因为移除开关就错误声明
为可用。不要通过清空 Token、删除连接档案或重建设备来恢复 capability。

## 风险与优化

- 能力快照只在进程启动时计算，换取确定性和低维护成本；配置修改需要一次受管重启。
- 缓存检查只验证私有目录能够创建并关闭临时文件，不读取用户附件，也不记录真实路径。
- `file_upload_v1` 关闭后，已在该进程内保存的附件仍受端点统一拒绝；重新启用前不能下载。
  这是 fail-closed 取舍，避免禁用期间旧客户端继续读取。
- 当前只有一个真实可选能力，不建设通用 Feature Flag 服务。以后增加能力时复用同一
  状态模型和测试矩阵；只有真实运维需求出现后再考虑更细粒度策略。
