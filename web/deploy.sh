#!/usr/bin/env bash
#
# Deploy the Mimi Remote marketing site (web/) to a remote server as an
# ISOLATED static-file service. It does NOT touch nginx, the firewall, or any
# VPN/WireGuard/OpenVPN config — it only rsyncs files and installs one
# self-contained systemd unit that serves them on a dedicated port.
#
# Why a script (and not the agent): the Codex sandbox blocks outbound network,
# so the agent cannot SSH out. Run this from a machine that can reach the box.
#
# Usage:
#   export SSHPASS='your-ssh-password'          # kept out of files/args
#   WEB_PORT=8080 ./web/deploy.sh
#
# First run prints every listening port on the server so you can confirm the
# chosen WEB_PORT will not collide with your VPN. Override anything via env.
#
set -euo pipefail

HOST="${DEPLOY_HOST:-65.49.233.70}"
SSH_PORT="${DEPLOY_SSH_PORT:-29892}"
SSH_USER="${DEPLOY_USER:-root}"
WEB_PORT="${WEB_PORT:-8080}"
REMOTE_DIR="${REMOTE_DIR:-/var/www/mimi-remote}"
SERVICE="${SERVICE:-mimi-web}"

: "${SSHPASS:?export SSHPASS='...' first (your SSH password)}"
command -v sshpass >/dev/null || { echo "!! need sshpass (brew install sshpass / apt install sshpass)"; exit 1; }

SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
rsh () { sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_USER@$HOST" "$@"; }

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Connecting to $SSH_USER@$HOST:$SSH_PORT …"
rsh true

echo
echo "==> Current listening sockets on the server (confirm WEB_PORT=$WEB_PORT is safe vs your VPN):"
rsh "ss -tulpn 2>/dev/null | sort || netstat -tulpn 2>/dev/null | sort"

echo
echo "==> Checking TCP port $WEB_PORT is free…"
if rsh "ss -tlpn 2>/dev/null | grep -q ':$WEB_PORT '"; then
  echo "!! Port $WEB_PORT is already in use on the server. Re-run with WEB_PORT=<other>."
  exit 1
fi
# Guard against clobbering the SSH port itself.
if [ "$WEB_PORT" = "$SSH_PORT" ]; then echo "!! WEB_PORT must differ from SSH_PORT"; exit 1; fi

echo "==> Syncing web/ -> $HOST:$REMOTE_DIR (excluding scripts)…"
rsh "mkdir -p '$REMOTE_DIR'"
sshpass -e rsync -az --delete \
  --exclude '*.sh' --exclude '.DS_Store' \
  -e "ssh ${SSH_OPTS[*]}" \
  "$HERE/" "$SSH_USER@$HOST:$REMOTE_DIR/"

echo "==> Installing isolated systemd service '$SERVICE' on port $WEB_PORT…"
rsh "cat > /etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=Mimi Remote marketing site (static)
After=network.target

[Service]
Type=simple
ExecStart=$(rsh 'command -v python3') -m http.server ${WEB_PORT} --bind 0.0.0.0 --directory ${REMOTE_DIR}
Restart=on-failure
User=root
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
UNIT

rsh "systemctl daemon-reload && systemctl enable --now ${SERVICE} && sleep 1 && systemctl --no-pager --lines=3 status ${SERVICE} | head -n 6"

echo
echo "==> Local health check on the server…"
code="$(rsh "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${WEB_PORT}/ || echo ERR")"
echo "    GET http://127.0.0.1:${WEB_PORT}/  ->  $code"

echo
echo "==> Done."
echo "    Served from: $REMOTE_DIR   (service: ${SERVICE}, port: ${WEB_PORT})"
echo "    Public URL (if the cloud firewall/security-group allows TCP ${WEB_PORT}):"
echo "        http://${HOST}:${WEB_PORT}/"
echo
echo "    If it's not reachable from outside, the host firewall or cloud security"
echo "    group is blocking TCP ${WEB_PORT}. Opening it is additive and won't affect"
echo "    the VPN, e.g.:  ufw allow ${WEB_PORT}/tcp   (only if you use ufw)"
