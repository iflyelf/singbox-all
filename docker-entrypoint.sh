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
: "${LOCAL_PROXY_PORT:=7928}"
: "${LOCAL_PROXY_USER:=proxy}"
: "${LOCAL_PROXY_PASS:=Chqmyg#2024Moon!}"

mkdir -p /etc/sing-box

# ---- 公共出站: 统一走 conduitvpn 住宅IP, 不回落 direct (死守住宅IP) ----------
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

# ---- 生成 vmess 配置 --------------------------------------------------------
cat <<-EOF > /etc/sing-box/vmess.json
{
    "log":{ "level":"info" },
    "inbounds":[
        {
            "type":"vmess",
            "tag":"vmess-in",
            "listen":"::",
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
            "listen":"::",
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

# ---- 渲染 WAF 域名放行规则 --------------------------------------------------
if [ -x /data/nginx/conf/waf/render-waf.sh ]; then
    /data/nginx/conf/waf/render-waf.sh || echo "[entrypoint] render-waf 失败, 继续启动"
fi

# ---- 启动 supervisord (前台, PID1) ------------------------------------------
echo "[entrypoint] 启动 supervisord ..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
