# 公网 VPS 转发运维手册

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

### 2. 快速定位 502

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

### 3. 快速定位慢请求

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

### 4. iPad App 配置

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
