# Tailscale 直连与上海 Peer Relay 运维手册

## 目标

让 Mimi Remote 优先使用 iPad 与 Mac 之间的 Tailscale/WireGuard 直连；无法打洞时优先经上海 VPS 的 Tailscale Peer Relay 转发；Tailscale 整体不可用时，再由 App 自动切换到现有 nginx + SSH 反向隧道公网入口。

稳定链路按以下顺序选择：

```text
1. iPad <-> Mac                         Tailscale direct
2. iPad -> 上海 VPS -> Mac              Tailscale peer-relay
3. iPad -> nginx -> SSH reverse -> Mac  App 公网备用入口
4. Tailscale 官方 DERP                  Tailscale 最终网络兜底
```

应用层协议不变，仍然是 HTTP REST + WebSocket JSON-RPC。Tailscale 只负责底层加密网络和直连/中继选择。

## 方案

当前个人部署使用以下配置：

- Mac Tailscale 节点：`s-mac-studio`
- 上海 Peer Relay 节点：`shanghai-peer-relay`
- Peer Relay 监听：`40000/UDP`
- 上海 VPS 公网地址：`124.221.80.250`
- Mac `agentd`：`8787/TCP`
- 原 nginx + SSH reverse tunnel：保持运行，不做迁移或停机

iPad App 的连接配置：

```text
首选地址（Tailscale）: http://<Mac-Tailscale-IP>:8787
备用公网地址:          http://124.221.80.250
访问码:                原 AGENTD_TOKEN
```

App 在冷启动、回到前台和 WebSocket 自动重连时探测候选地址。切换前先断开旧 WebSocket，再让 REST 与新 WebSocket 一起使用新的 active endpoint，避免同一会话被拆到两条链路。

## 实现

### 1. VPS 安装并加入 tailnet

```bash
ssh ubuntu@124.221.80.250

curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up \
  --hostname=shanghai-peer-relay \
  --accept-dns=false
```

浏览器完成一次设备授权后确认：

```bash
tailscale status
tailscale ip -4
```

### 2. 启用 Peer Relay

腾讯云公网 IP 通过 NAT 映射给实例，因此同时公布静态公网端点：

```bash
sudo tailscale set \
  --relay-server-port=40000 \
  --relay-server-static-endpoints="124.221.80.250:40000"

sudo ss -lunp | grep ':40000'
```

腾讯云 CVM 安全组必须增加入站规则：

```text
来源:   0.0.0.0/0
协议:   UDP
端口:   40000
策略:   允许
备注:   Tailscale Peer Relay
```

Peer Relay 只接受同一 tailnet 内通过 Tailscale 身份认证且获得 capability 的节点。中继看到的是 WireGuard 加密包，不会解密 `agentd` 业务数据。

### 3. 配置 tailnet policy

在 Tailscale Admin Console 的 `Access controls -> JSON editor` 中，把以下 grant 合并进现有 `grants`。实际部署使用设备当前的 Tailscale IP，仓库不记录私有地址。

```jsonc
{
  "grants": [
    // 保留现有网络访问规则。
    {
      "src": ["<Mac-Tailscale-IP>", "<iPad-Tailscale-IP>"],
      "dst": ["<Relay-Tailscale-IP>"],
      "app": {
        "tailscale.com/cap/relay": []
      }
    }
  ]
}
```

不要把 relay capability 的 `src` 长期写成 `*`。当前只授权需要访问 Mimi 的 Mac 和 iPad，避免其他设备无意中使用上海 VPS 带宽。

### 4. 验证

Mac 本机先确认两个业务入口都健康：

```bash
curl -fsS http://<Mac-Tailscale-IP>:8787/healthz
curl -fsS http://124.221.80.250/healthz
```

确认上海节点在线且网络可直达：

```bash
tailscale ping shanghai-peer-relay
tailscale status
```

iPad 在线并产生 Mimi 流量后，在 Mac 和 VPS 分别查看：

```bash
tailscale status | grep -E 'direct|peer-relay|relay'
```

结果含义：

```text
direct       iPad 与 Mac 直接通信，最快
peer-relay   直连失败，经过上海 VPS
relay        Peer Relay 也不可达，经过官方 DERP
```

Peer Relay 是自动降级路径，直连成功时不会强制绕行上海 VPS。仅查看 relay 节点在线不能证明业务已经走 peer-relay；必须在 iPad 在线、产生实际流量且直连失败时观察连接类型。

### 5. 列表链路性能回归

历史和列表优化上线前后，使用同一只读脚本比较本机、Tailscale 与公网回退。脚本只执行 `initialize + thread/list`，不会创建会话或调用模型：

```bash
bash ./scripts/history-sync-regression.sh \
  --rounds 10 \
  --endpoint local=http://127.0.0.1:8787 \
  --endpoint tailscale=http://<Mac-Tailscale-IP>:8787 \
  --endpoint public=http://124.221.80.250
```

日常探针默认发送小页、最近更新时间倒序和 `useStateDbOnly=true`，对应 App 的 Codex 状态库快路径。需要验证 SQLite 索引遗漏时的普通扫描回退，可直接运行现有探针并关闭快路径：

```bash
go run -tags ipadwsprobe ./scripts/ipad-ws-probe.go \
  -endpoint http://<Mac-Tailscale-IP>:8787 \
  -list-only \
  -state-db-only=false \
  -list-limit 20
```

每条链路应保持零错误；当前验收目标是 Tailscale `thread/list` P95 不超过 1.5 秒，公网回退 P95 不超过 2 秒。若普通扫描明显慢于快路径，先检查 Codex 状态库是否完成索引，不要直接提高 Gateway 超时或响应上限。

### 6. 回滚

禁用 VPS Peer Relay：

```bash
ssh ubuntu@124.221.80.250 \
  'sudo tailscale set --relay-server-port="" --relay-server-static-endpoints=""'
```

然后从 tailnet policy 删除 `tailscale.com/cap/relay` grant，并移除腾讯云 `40000/UDP` 入站规则。

App 可把首选地址临时改回 `http://124.221.80.250`，备用地址留空。原 nginx、SSH reverse tunnel 和 `agentd` 均未因 Peer Relay 调整而停用，所以回滚不需要重建公网链路。

## 风险与优化

- 当前公网备用入口仍是 HTTP，Bearer Token 会以明文 HTTP 经过公网和可信 VPS。应尽快绑定域名并启用 HTTPS。
- iOS 必须保持 Tailscale VPN 开启，才能访问 `100.64.0.0/10` 地址并使用 direct/peer-relay。
- 腾讯云安全组未放行 `40000/UDP` 时，VPS 进程虽然显示监听，移动端仍无法主动建立 Peer Relay 连接。
- Tailscale 官方 DERP 仍是最后兜底，不能由 Peer Relay 完全替代；正常业务数据不会先绕海外 DERP 再经过上海节点。
- 外网 IP 变化不影响 Mac/iPad 身份，Tailscale 会重新发布 endpoint。上海 VPS 使用固定公网地址作为 relay 静态端点。
