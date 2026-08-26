#!/bin/bash
set -e

# =============================================================================
# sing-box all-in-one 入口脚本
#   1. 生成 sing-box vmess/trojan 配置 (出站统一走 conduitvpn socks5)
#   2. 渲染 WAF 域名放行规则
#   3. 启动 supervisord 统一守护全部进程
# =============================================================================

# ---- 默认值 (可被 compose/.env 环境变量覆盖) --------------------------------
: "${VMESS_PORT:=6601}"
: "${VMESS_NAME:=xiaonuo}"
: "${VMESS_UUID:=f011c012-5f1d-418c-9494-d24d77a9d8f9}"
: "${VMESS_ALTER_ID:=0}"
: "${VMESS_WSPATH:=/xiaonuo/vmess}"
: "${TROJAN_PORT:=6602}"
: "${TROJAN_NAME:=xiaonuo}"
: "${TROJAN_PWD:=ysyh!9Sky}"
: "${TROJAN_WSPATH:=/xiaonuo/trojan}"
: "${LOCAL_PROXY_HOST:=127.0.0.1}"
# sing-box 入站监听地址: host 网络模式下默认仅回环, 由同网络栈内的 nginx 反代,
# 无需对外暴露 6601/6602 (入口统一走 cloudflared 隧道)
: "${SINGBOX_LISTEN:=127.0.0.1}"
: "${LOCAL_PROXY_PORT:=7928}"
: "${LOCAL_PROXY_USER:=proxy}"
: "${LOCAL_PROXY_PASS:=Chqmyg#2024Moon!}"
# 出站回落策略: none=只走住宅IP, direct=VPNGate不可用时允许直连测速选择
: "${SINGBOX_FALLBACK:=none}"
# nginx 监听地址: 127.0.0.1 仅本机(供 cloudflared 隧道回源, 不开放公网);
#                0.0.0.0  开放公网直连
: "${NGINX_LISTEN:=127.0.0.1}"
# nginx 对外监听端口: 端口冲突时可改 (cloudflared 回源地址会自动同步)
: "${NGINX_PORT:=80}"

mkdir -p /etc/sing-box

# ---- 公共出站 ---------------------------------------------------------------
if [ "${SINGBOX_FALLBACK}" = "direct" ]; then
    # urltest 会在 conduitvpn 与 direct 之间选择健康且延迟较低的出站。
    # 这不是严格优先级回落: 开启后可能选择 direct, 因此会失去住宅IP保证。
    read -r -d '' OUTBOUNDS <<EOF || true
    "outbounds":[
        {
            "type":"socks",
            "tag":"conduit-out",
            "server":"${LOCAL_PROXY_HOST}",
            "server_port":${LOCAL_PROXY_PORT},
            "version":"5",
            "username":"${LOCAL_PROXY_USER}",
            "password":"${LOCAL_PROXY_PASS}"
        },
        {
            "type":"direct",
            "tag":"direct"
        },
        {
            "type":"urltest",
            "tag":"auto",
            "outbounds":["conduit-out","direct"],
            "url":"https://www.gstatic.com/generate_204",
            "interval":"1m",
            "tolerance":50
        }
    ],
    "route":{
        "final":"auto"
    }
EOF
else
    read -r -d '' OUTBOUNDS <<EOF || true
    "outbounds":[
        {
            "type":"socks",
            "tag":"conduit-out",
            "server":"${LOCAL_PROXY_HOST}",
            "server_port":${LOCAL_PROXY_PORT},
            "version":"5",
            "username":"${LOCAL_PROXY_USER}",
            "password":"${LOCAL_PROXY_PASS}"
        }
    ],
    "route":{
        "final":"conduit-out"
    }
EOF
fi

# ---- 生成 vmess 配置 --------------------------------------------------------
cat <<-EOF > /etc/sing-box/vmess.json
{
    "log":{ "level":"info" },
    "inbounds":[
        {
            "type":"vmess",
            "tag":"vmess-in",
            "listen":"${SINGBOX_LISTEN}",
            "listen_port":${VMESS_PORT},
            "tcp_fast_open":true,
            "udp_fragment":true,
            "udp_timeout":300,
            "disable_tcp_keep_alive": false,
            "users":[
                { "name":"${VMESS_NAME}", "uuid":"${VMESS_UUID}", "alterId":${VMESS_ALTER_ID} }
            ],
            "transport":{
                "type":"ws",
                "path":"${VMESS_WSPATH}",
                "max_early_data":0,
                "early_data_header_name":"Sec-WebSocket-Protocol"
            }
        }
    ],
${OUTBOUNDS}
}
EOF

# ---- 生成 trojan 配置 -------------------------------------------------------
cat <<-EOF > /etc/sing-box/trojan.json
{
    "log":{ "level":"info" },
    "inbounds":[
        {
            "type":"trojan",
            "tag":"trojan-in",
            "listen":"${SINGBOX_LISTEN}",
            "listen_port":${TROJAN_PORT},
            "tcp_fast_open":true,
            "udp_fragment":true,
            "udp_timeout":300,
            "disable_tcp_keep_alive": false,
            "users":[
                { "name":"${TROJAN_NAME}", "password":"${TROJAN_PWD}" }
            ],
            "transport":{
                "type":"ws",
                "path":"${TROJAN_WSPATH}",
                "max_early_data":0,
                "early_data_header_name":"Sec-WebSocket-Protocol"
            }
        }
    ],
${OUTBOUNDS}
}
EOF

# ---- 渲染 nginx vhost (监听地址 / 端口 / WS 路径) ----------------------------
VHOST_TPL=/data/nginx/conf/vhost/default.conf.template
VHOST_OUT=/data/nginx/conf/vhost/default.conf
if [ -f "${VHOST_TPL}" ]; then
    sed -e "s|__NGINX_LISTEN__|${NGINX_LISTEN}|g" \
        -e "s|__NGINX_PORT__|${NGINX_PORT}|g" \
        -e "s|__VMESS_PORT__|${VMESS_PORT}|g" \
        -e "s|__TROJAN_PORT__|${TROJAN_PORT}|g" \
        -e "s|__VMESS_WSPATH__|${VMESS_WSPATH}|g" \
        -e "s|__TROJAN_WSPATH__|${TROJAN_WSPATH}|g" \
        "${VHOST_TPL}" > "${VHOST_OUT}"
    echo "[entrypoint] nginx vhost 渲染完成 (listen ${NGINX_LISTEN}:${NGINX_PORT})"
fi

# ---- 渲染 WAF 域名放行规则 --------------------------------------------------
if [ -x /data/nginx/conf/waf/render-waf.sh ]; then
    /data/nginx/conf/waf/render-waf.sh || echo "[entrypoint] render-waf 失败, 继续启动"
fi

# ---- 启动 supervisord (前台, PID1) ------------------------------------------
echo "[entrypoint] 启动 supervisord ..."
# -n 同时作为命令行兜底，防止配置文件中的 nodaemon 设置被覆盖为后台模式。
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
