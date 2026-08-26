#!/bin/bash
# =============================================================================
# cloudflared 双模式启动包装
#   - 设置 TUNNEL_TOKEN 时: 命名隧道 (固定域名, 需在 CF 面板配置 ingress)
#   - 未设置时: quick tunnel (随机 trycloudflare.com 域名, 每次重启变化)
#   日志统一输出, 供 gen-links.sh 抓取随机域名
# =============================================================================
set -e

: "${TUNNEL_URL:=http://127.0.0.1:80}"

if [ -n "${TUNNEL_TOKEN}" ]; then
    echo "[cloudflared] 命名隧道模式 (token)"
    exec /usr/bin/cloudflared tunnel --no-autoupdate run --token "${TUNNEL_TOKEN}"
else
    echo "[cloudflared] quick tunnel 模式 (随机域名)"
    exec /usr/bin/cloudflared tunnel --no-autoupdate --url "${TUNNEL_URL}"
fi
