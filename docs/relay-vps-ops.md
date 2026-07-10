# 公网 VPS 转发运维手册

> 当前推荐链路已经升级为 Tailscale 直连优先、上海 Peer Relay 次选、本页 nginx + SSH reverse tunnel 最终兜底。配置和验证见 [Tailscale 直连与上海 Peer Relay 运维手册](./tailscale-peer-relay-ops.md)。

## 目标

记录当前 Mimi Remote 的公网访问架构、这次从旧 1M VPS 迁移到新 5M VPS 的操作，以及后续排查慢请求、断连、端口不可达时应该先看哪里。

这份文档的重点是当前个人部署形态，不是通用商业化部署方案。

## 方案

当前 `agentd` 服务端仍然部署在本地 Mac。公网 VPS 不跑业务逻辑，也不保存 Codex 凭证，只负责把公网 HTTP/WebSocket 请求转发回 Mac 本机的 `agentd`。

```text
iPhone / iPad App
  |
  | HTTP / WebSocket
  | Authorization: Bearer <AGENTD_TOKEN>
  v
新 VPS: 124.221.80.250
  |
  | nginx :80
  | proxy_pass http://127.0.0.1:18786
  v
VPS loopback: 127.0.0.1:18786
  |
  | SSH reverse tunnel
  | ssh -R 127.0.0.1:18786:127.0.0.1:8787
  v
Mac loopback: 127.0.0.1:8787
  |
  | agentd
  v
Codex app-server: ws://127.0.0.1:4222
  |
  v
Codex core / 本机仓库 / 本机凭证
```

核心边界：

- iPad 端访问入口：`http://124.221.80.250`
- VPS 用户：`ubuntu@124.221.80.250`
- 旧 VPS：`14.103.53.126`，1M 带宽，已经不作为主入口
- Mac 本机 `agentd`：`127.0.0.1:8787`
- VPS 反代端口：`127.0.0.1:18786`
- Codex app-server：`ws://127.0.0.1:4222`
- 长期 Token 仍由 Mac 上的 `agentd` 校验，不写入本文档
- 服务器密码、`AGENTD_TOKEN`、Codex 登录态都不要写进仓库文档

当前链路里，VPS 只做转发；真正的项目扫描、权限校验、Codex app-server 托管、语音转写请求都发生在 Mac 上。

## 实现

### 1. 新 VPS 初始化

这次迁移到的新 VPS 是空机器，初始化时做了这些事：

```bash
ssh ubuntu@124.221.80.250

sudo apt-get update
sudo apt-get install -y nginx curl ca-certificates
```

把 Mac 的 SSH 公钥加入新服务器，之后本机 LaunchAgent 可以无密码建立反向隧道：

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
printf '%s\n' '<Mac 的 ~/.ssh/id_ed25519.pub 内容>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

检查 nginx：

```bash
systemctl is-active nginx
ss -ltnp
```

当前应看到：

```text
0.0.0.0:80
0.0.0.0:22
127.0.0.1:18786
```

其中 `127.0.0.1:18786` 是 Mac 通过 SSH 反向隧道映射出来的端口。如果这个端口不存在，公网访问通常会变成 `502 Bad Gateway`。

### 2. VPS nginx 配置

当前 nginx 配置文件：

```text
/etc/nginx/conf.d/mimi-agentd-relay.conf
```

内容如下：

```nginx
server {
    listen 80 default_server;
    server_name 124.221.80.250 _;

    client_max_body_size 64m;

    location = /healthz {
        proxy_pass http://127.0.0.1:18786;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    location ^~ /api/ {
        proxy_pass http://127.0.0.1:18786;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 10s;
        proxy_buffering off;
    }

    location / {
        return 404;
    }
}
```

修改后验证并 reload：

```bash
sudo nginx -t
sudo systemctl reload nginx
```

### 3. Mac 反向隧道 LaunchAgent

Mac 上用 LaunchAgent 维持 SSH 反向隧道，当前文件：

```text
~/Library/LaunchAgents/com.mimi-remote.agentd-vps-tunnel.plist
```

关键配置：

```text
/usr/bin/ssh
-N
-T
-o BatchMode=yes
-o ExitOnForwardFailure=yes
-o ServerAliveInterval=15
-o ServerAliveCountMax=3
-o TCPKeepAlive=yes
-o Compression=yes
-o StrictHostKeyChecking=accept-new
-R 127.0.0.1:18786:127.0.0.1:8787
ubuntu@124.221.80.250
```

迁移时做过的关键变更：

- 旧目标：`root@14.103.53.126`
- 新目标：`ubuntu@124.221.80.250`
- 旧 plist 备份：`~/Library/LaunchAgents/com.mimi-remote.agentd-vps-tunnel.plist.bak-20260702-migrate-124`

重载 LaunchAgent：

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.mimi-remote.agentd-vps-tunnel.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.mimi-remote.agentd-vps-tunnel.plist"
launchctl enable "gui/$(id -u)/com.mimi-remote.agentd-vps-tunnel"
launchctl kickstart -k "gui/$(id -u)/com.mimi-remote.agentd-vps-tunnel"
```

查看状态：

```bash
launchctl print "gui/$(id -u)/com.mimi-remote.agentd-vps-tunnel"
```

查看隧道日志：

```bash
tail -n 200 "$HOME/Library/Logs/codex-ipad-agent/vps-tunnel.out.log"
tail -n 200 "$HOME/Library/Logs/codex-ipad-agent/vps-tunnel.err.log"
```

### 4. 迁移后的验证

本机先确认 `agentd` 可用：

```bash
curl -i http://127.0.0.1:8787/healthz
```

确认新 VPS 公网入口可用：

```bash
curl -i http://124.221.80.250/healthz
```

确认旧 VPS 已不是主入口：

```bash
curl -i http://14.103.53.126/healthz
```

旧 VPS 如果返回 `502`，通常表示旧机器上的反向隧道已经断开，这是符合迁移后预期的。

WebSocket 主链路验证：

```bash
go run ./scripts/ipad-ws-probe.go \
  -endpoint http://124.221.80.250 \
  -list-only \
  -timeout 30s
```

成功时应能连上：

```text
ws://124.221.80.250/api/app-server/ws
```

并返回项目列表、线程列表等信息。

### 5. 端口是否需要在云厂商打开

当前新 VPS 已经验证过公网 `80` 可用。以后换服务器时，需要同时满足三层条件：

1. 云厂商安全组 / 防火墙放行 TCP `80`
2. VPS 系统防火墙放行 TCP `80`
3. nginx 正在监听 `0.0.0.0:80`

快速判断：

```bash
# 在本机执行，确认公网能访问
curl -i --connect-timeout 5 http://<VPS_IP>/healthz

# 在 VPS 执行，确认 nginx 监听公网 80
ss -ltnp | grep ':80'

# 在 VPS 执行，确认 nginx 状态
systemctl is-active nginx
```

如果本机访问超时，多半是云厂商安全组或系统防火墙没开。如果返回 `502`，多半是 Mac 到 VPS 的 SSH 反向隧道没连上。

## 监控与排查

### 1. 查看整体耗时

`agentd` 提供了转发链路诊断接口：

```bash
curl -sS \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://124.221.80.250/api/diagnostics/relay | jq
```

重点看这些字段：

```text
http.duration_ms_max
http.write_ms_max
app_server_gateway.active_connections_detail[]
app_server_gateway.active_connections_detail[].upstream_to_client.bytes
app_server_gateway.active_connections_detail[].upstream_to_client.write_ms_max
app_server_gateway.active_connections_detail[].rpc.latency_ms_max
app_server_gateway.active_connections_detail[].rpc.outstanding_requests
app_server_gateway.recent_rpc[]
hints[]
```

判断规则：

| 现象 | 优先怀疑 |
| --- | --- |
| `upstream_to_client.bytes` 很大，同时 `write_ms_max` 很高 | VPS 带宽或客户端网络 |
| `rpc.latency_ms_max` 很高，但 `write_ms_max` 很低 | Mac 本机 app-server / Codex 处理慢 |
| `outstanding_requests` 长时间大于 0 | 某些 JSON-RPC 请求卡住 |
| `/api/voice/transcribe` 4-8 秒 | 转录上游耗时，通常不是 VPS 带宽 |
| `/healthz` 返回 502 | SSH 反向隧道断开，或 Mac 本地 `agentd` 不可用 |

这次换 5M VPS 后观察到的结论：

- 新 VPS 当前写回客户端最大耗时约几十毫秒量级
- 没有请求积压
- 大包返回比旧 1M VPS 明显改善
- 剩余慢点主要是 `thread/list` 等 app-server JSON-RPC 响应偶发 3-9 秒
- 语音转写慢主要看转录上游，不看 VPS 带宽

### 2. 腾讯云外网出带宽告警排查

腾讯云「外网出带宽」告警表示 VPS 正在向公网客户端写出数据。当前架构下，最常见来源是 iPad 通过 `/api/app-server/ws` 拉取 app-server 大响应，尤其是 `thread/list` 或 `thread/turns/list` 返回过大的历史会话/turn 列表。

先不要重启 Mac 或 Codex。优先用只读诊断确认是不是公网写出带宽，而不是 app-server 本身慢：

```bash
curl -sS \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://124.221.80.250/api/diagnostics/relay \
  | jq '{
      generated_at,
      hints,
      gateway: {
        active_connections: .app_server_gateway.active_connections,
        upstream_to_client: .app_server_gateway.upstream_to_client,
        rpc: .app_server_gateway.rpc
      }
    }'
```

判断规则：

| 现象 | 结论 | 下一步 |
| --- | --- | --- |
| `upstream_to_client.bytes` 持续增长，且 `upstream_to_client.write_ms_max` 高 | VPS 到 iPad 的写出链路吃紧 | 定位是哪条 WS 连接和哪个 RPC 大响应 |
| `recent_rpc[].response_bytes` 很大，但 `write_ms_max` 不高 | app-server 返回了大包，但公网暂未卡住 | 优先优化列表/turn 拉取策略 |
| `recent_rpc[].latency_ms` 高，`response_bytes` 小，`write_ms_max` 低 | Mac 本机 app-server / Codex 慢 | 不按带宽故障处理 |
| `rpc.outstanding_requests` 长时间大于 0 | 上游请求未返回 | 看 Mac 本机 app-server、Codex、模型侧状态 |

定位 `thread/list` 和 `thread/turns/list` 大响应：

```bash
curl -sS \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://124.221.80.250/api/diagnostics/relay \
  | jq '[
      .app_server_gateway.recent_rpc[]?
      | select(.method == "thread/list" or .method == "thread/turns/list")
      | {
          completed_at,
          method,
          latency_ms,
          request_bytes,
          response_bytes,
          response_kb: ((.response_bytes / 1024) | floor)
        }
    ] | sort_by(.response_bytes) | reverse | .[:20]'
```

定位当前活跃连接里是谁在拉大包：

```bash
curl -sS \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://124.221.80.250/api/diagnostics/relay \
  | jq '.app_server_gateway.active_connections_detail[]
    | {
        id,
        remote,
        duration_ms,
        last_client_method,
        last_client_frame_bytes,
        last_upstream_method,
        last_upstream_frame_bytes,
        upstream_to_client: {
          bytes: .upstream_to_client.bytes,
          write_ms_max: .upstream_to_client.write_ms_max,
          last_frame_bytes: .upstream_to_client.last_frame_bytes
        },
        rpc: {
          latency_ms_max: .rpc.latency_ms_max,
          outstanding_requests: .rpc.outstanding_requests,
          outstanding_ms_max: .rpc.outstanding_ms_max
        },
        recent_large_list_rpc: (
          [.recent_rpc[]?
           | select(.method == "thread/list" or .method == "thread/turns/list")
           | {method, latency_ms, request_bytes, response_bytes}]
          | sort_by(.response_bytes)
          | reverse
          | .[:10]
        )
      }'
```

如果 `last_client_method` 是 `thread/turns/list`，并且 `last_upstream_frame_bytes` 或 `recent_large_list_rpc[].response_bytes` 很大，基本可以判断是 iPad 正在拉某个 thread 的 turns 列表导致公网出带宽升高。

临时止血按影响从小到大执行：

1. 停 iPad 客户端

   先让 iPad 端停止继续拉取数据：退出 Mimi Remote、断开当前网络，或临时把 Endpoint 改成不可用地址。等待 30-60 秒后再看诊断：

   ```bash
   curl -sS \
     -H "Authorization: Bearer $AGENTD_TOKEN" \
     http://124.221.80.250/api/diagnostics/relay \
     | jq '.app_server_gateway.active_connections, .app_server_gateway.upstream_to_client'
   ```

   如果 `active_connections` 归零，且腾讯云外网出带宽回落，说明告警来自 iPad 侧持续拉取。

2. 临时禁用公网 `/api/app-server/ws`

   在 VPS 上给 nginx 加一个精确匹配，必须放在 `location ^~ /api/` 前面。这样只阻断 app-server WebSocket，不影响 `/healthz` 和 `/api/diagnostics/relay`：

   ```nginx
   location = /api/app-server/ws {
       return 503;
   }
   ```

   验证并 reload：

   ```bash
   ssh ubuntu@124.221.80.250
   sudo nginx -t
   sudo systemctl reload nginx
   ```

   恢复时删除这个 `location = /api/app-server/ws` 块，再执行同样的 `nginx -t` 和 `reload`。

3. 临时切到 Tailscale 或局域网

   如果公网 VPS 持续触发出带宽告警，但本机 Mac 和 iPad 在可信网络里，可以绕开 VPS：

   ```text
   http://<Mac 的 Tailscale IP>:8787
   http://<Mac 的局域网 IP>:8787
   ```

   前提是 `agentd` 已经监听对应的 Tailscale / 局域网地址，并且访问来源受控。如果当前只监听 `127.0.0.1:8787`，不要为了止血把 `0.0.0.0:8787` 裸开到公网。Tailscale 优先于局域网直连，因为可以用 ACL 限制只有可信 iPad 访问 `8787`。切换后继续用 Mac 本地入口看健康状态：

   ```bash
   curl -i http://127.0.0.1:8787/healthz
   ```

止血后保留一份诊断样本，方便之后判断是不是列表接口需要分页、降频或缓存：

```bash
curl -sS \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://124.221.80.250/api/diagnostics/relay \
  | jq '{
      generated_at,
      hints,
      recent_large_list_rpc: (
        [.app_server_gateway.recent_rpc[]?
         | select(.method == "thread/list" or .method == "thread/turns/list")
         | {completed_at, method, latency_ms, request_bytes, response_bytes}]
        | sort_by(.response_bytes)
        | reverse
        | .[:20]
      ),
      active_connections_detail: .app_server_gateway.active_connections_detail
    }'
```

### 3. 快速定位 502

先看本机 `agentd`：

```bash
curl -i http://127.0.0.1:8787/healthz
```

再看 Mac LaunchAgent：

```bash
launchctl print "gui/$(id -u)/com.mimi-remote.agentd-vps-tunnel"
tail -n 100 "$HOME/Library/Logs/codex-ipad-agent/vps-tunnel.err.log"
```

再看 VPS 是否有反向端口：

```bash
ssh ubuntu@124.221.80.250 'ss -ltnp | grep 18786 || true'
```

最后看 nginx：

```bash
ssh ubuntu@124.221.80.250 'sudo nginx -t && systemctl is-active nginx'
```

### 4. 快速定位慢请求

先拉诊断：

```bash
curl -sS \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://124.221.80.250/api/diagnostics/relay | jq '.hints, .app_server_gateway.active_connections_detail'
```

如果 `write_ms_max` 不高，但 `recent_rpc[].latency_ms` 高，说明公网链路没堵，继续看 Mac 本地：

```bash
curl -i http://127.0.0.1:8787/healthz
agentd logs
```

如果 `write_ms_max` 很高，说明写回客户端被网络拖慢，优先看：

- VPS 带宽是否打满
- iPad 当前网络质量
- 返回 payload 是否异常大
- 是否需要继续升级带宽或减少列表刷新频率

### 5. 只读诊断脚本

仓库里提供了一个只读脚本，把上面的 `curl /api/diagnostics/relay + jq` 查询固定下来：

```bash
bash ./scripts/relay-bandwidth-diagnose.sh \
  --endpoint http://124.221.80.250 \
  --min-bytes 262144 \
  --min-latency-ms 2000
```

脚本只读取 `/api/diagnostics/relay`，不会建立 `/api/app-server/ws`，也不会发起 `thread/list` 或 `thread/turns/list` 新请求。Token 默认读取 `AGENTD_TOKEN`，如果环境变量为空，再尝试读取本机 `~/Library/Application Support/codex-ipad-agent/config.json`。

### 6. 列表与大历史诊断

日常 `thread/list` 使用 `limit=20`、最近更新时间倒序和 `useStateDbOnly=true`，直接读取 Codex 状态库，避免每次扫描 rollout JSONL。以下情况 App 会在同一连接代次执行一次普通扫描回退：

- 状态库返回空列表，但本地已有该工作区的已知会话
- 快路径没有返回当前已选会话
- 旧版 Codex 明确拒绝 `useStateDbOnly`

回退是修复路径，不是第二套轮询。成功回退或确认旧版本不支持后，本次连接不会持续重复两次 `thread/list`。

Gateway 按方法记录历史与列表流量，可用下面的命令观察累计值：

```bash
curl -fsS \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://127.0.0.1:8787/api/diagnostics/relay \
  | jq '.app_server_gateway.methods
      | with_entries(select(.key == "thread/list"
                         or .key == "thread/turns/list"
                         or .key == "thread/resume"
                         or .key == "thread/read"))'
```

每个方法包含：

- `requested`：进入历史/列表保护逻辑的请求数
- `inflight`：当前仍在等待上游响应的请求数
- `duplicate_rejected`：相同指纹仍在执行，被 Gateway 提前拒绝的次数
- `rejected`：重复、预算或策略拒绝总数
- `blocked`：响应超过单次预算、未下发到移动端的次数
- `rate_limited`：触发时间窗请求/字节预算的次数
- `response_bytes`：上游为该方法生成的累计响应字节数，包括被阻断响应

这些字段是进程启动后的累计值。对比改造前后时应各保存一次 diagnostics，再做字段差值；不要用历史最大值判断刚发生的一轮回归。

大历史的默认处理顺序：

1. 恢复会话只取最近最多 5 个完整 turn，并保持 `excludeTurns=true`
2. 更早历史按 cursor 分页，自动加载使用 `itemsView=summary`
3. 只有用户显式要求完整工具输出时才使用受限的 `itemsView=full`
4. 同参数并发请求由 App 合并；漏网重复由 Gateway 返回可重试原因 `history_request_in_flight`
5. 若 full 页超过预算，降低页大小或继续使用 summary，不提高响应上限

Gateway 的上限是在移动端之前止损，但 app-server 仍可能已经读取并构造了响应。因此优化重点始终是少请求、小页和 summary，而不是单纯调大 cap。

### 7. iPad App 配置

迁移后 iPad App 不需要改协议，只需要把 Endpoint 指向新入口：

```text
http://124.221.80.250
```

Token 仍使用原 Mac `agentd` 的 Token。迁移 VPS 不应该重新生成业务 Token，除非明确要让旧设备失效。

## 风险与优化

当前方案是个人 MVP 友好的公网访问方案，优点是简单、成本低、迁移快；风险也要明确：

- 目前 iPad 到 VPS 是 HTTP 明文，`AGENTD_TOKEN` 会经过公网；下一步建议绑定域名并上 HTTPS。
- VPS 上 nginx 能看到请求头和路径，所以 VPS 仍然需要被当成可信节点管理。
- SSH 反向隧道断开时公网入口会变成 `502`，LaunchAgent 的 `KeepAlive` 会自动拉起，但仍建议保留日志检查。
- `thread/list` 偶发慢现在更像 app-server / Codex 本地处理耗时，不是 5M VPS 带宽瓶颈。
- 如果后续用户变多或请求变重，再考虑把诊断指标接入 Prometheus / Grafana；当前阶段用 `/api/diagnostics/relay` 足够。

推荐的下一步优化顺序：

1. 给 `124.221.80.250` 绑定域名并配置 HTTPS。
2. 继续观察 `/api/diagnostics/relay`，确认慢点是否集中在 `thread/list`。
3. 如果 `thread/list` 仍然频繁 3 秒以上，再优化 App 端刷新频率或给线程列表做轻量缓存。
4. 保留旧 VPS 配置一段时间，但不要再作为主入口使用。
