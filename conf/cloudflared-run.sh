#!/bin/bash
# =============================================================================
# cloudflared 双模式启动包装
#   - 设置 TUNNEL_TOKEN 时: 命名隧道 (固定域名, 需在 CF 面板配置 ingress)
#   - 未设置时: quick tunnel (随机 trycloudflare.com 域名, 每次重启变化)
#   日志统一输出, 供 gen-links.sh 抓取随机域名
# =============================================================================
set -e

# 回源地址: 默认指向本机 nginx, 端口跟随 NGINX_PORT (与 .env 保持一致)
: "${NGINX_PORT:=80}"
: "${TUNNEL_URL:=http://127.0.0.1:${NGINX_PORT}}"

# 边缘连接协议: 默认 http2 (走 TCP, 规避部分网络对 QUIC/UDP 的限速)
# 可在 .env 中设置 TUNNEL_PROTOCOL=quic 恢复默认 QUIC
: "${TUNNEL_PROTOCOL:=http2}"

if [ -n "${TUNNEL_TOKEN}" ]; then
    echo "[cloudflared] 命名隧道模式 (token), protocol=${TUNNEL_PROTOCOL}"
    exec /usr/bin/cloudflared tunnel --no-autoupdate --protocol "${TUNNEL_PROTOCOL}" run --token "${TUNNEL_TOKEN}"
else
    echo "[cloudflared] quick tunnel 模式 (随机域名), protocol=${TUNNEL_PROTOCOL}"
    exec /usr/bin/cloudflared tunnel --no-autoupdate --protocol "${TUNNEL_PROTOCOL}" --url "${TUNNEL_URL}"
fi
