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
# 出站策略: none=只走住宅IP, direct=纯直连本机线路(默认)
: "${SINGBOX_FALLBACK:=direct}"
# nginx 监听地址: 127.0.0.1 仅本机(供 cloudflared 隧道回源, 不开放公网);
#                0.0.0.0  开放公网直连
: "${NGINX_LISTEN:=127.0.0.1}"
# nginx HTTP  对外监听端口: 端口冲突时可改 (cloudflared 回源地址会自动同步)
: "${NGINX_PORT:=80}"
# nginx HTTPS 对外监听端口: 0 表示不启用 HTTPS
: "${NGINX_HTTPS_PORT:=0}"
# SSL 证书目录名 (对应 conf/nginx/ssl/<SSL_DOMAIN>/, 换域名只需改此变量)
: "${SSL_DOMAIN:=xiaonuo.live}"
# SSL 证书根目录 (可挂载覆盖: -v /host/ssl:/data/nginx/conf/ssl)
: "${SSL_BASE_DIR:=/data/nginx/conf/ssl}"
# 证书文件名 (默认与域名同名, 可单独覆盖以适配不同签发机构的命名)
: "${SSL_CERT_FILE:=${SSL_DOMAIN}.pem}"
: "${SSL_KEY_FILE:=${SSL_DOMAIN}.key}"
: "${SSL_TRUSTED_FILE:=origin_ca_rsa_root.pem}"
: "${SSL_CLIENT_CA_FILE:=origin-pull-ca.pem}"
# Cloudflare Authenticated Origin Pull: on 时仅允许 CF 边缘回源
: "${SSL_VERIFY_CLIENT:=off}"

mkdir -p /etc/sing-box

# ---- 公共出站 ---------------------------------------------------------------
if [ "${SINGBOX_FALLBACK}" = "direct" ]; then
    # direct: 纯直连, 直接走宿主机线路, 不经 conduitvpn/VPNGate。
    # 出站不再是住宅IP, 而是本机公网IP。
    read -r -d '' OUTBOUNDS <<EOF || true
    "outbounds":[
        {
            "type":"direct",
            "tag":"direct"
        }
    ],
    "route":{
        "final":"direct"
    }
EOF
else
    # none: 只走 conduitvpn 住宅IP, VPNGate 不可用时连接失败, 不泄漏本机IP。
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
# 模板放在 conf 根目录: ssl/ 可能被只读挂载覆盖, 模板不能放在其中
SSL_TPL=/data/nginx/conf/https.conf.template
# 渲染输出也写到 conf 根目录 (ssl/ 只读挂载时无法写入)
SSL_OUT=/data/nginx/conf/https.conf
if [ -f "${VHOST_TPL}" ]; then
    # HTTPS 启用时 (NGINX_HTTPS_PORT!=0): 渲染 https.conf 并在 vhost 中 include
    HTTPS_INCLUDE=""
    if [ "${NGINX_HTTPS_PORT}" != "0" ] && [ -f "${SSL_TPL}" ]; then
        SSL_CERT_PATH="${SSL_BASE_DIR}/${SSL_DOMAIN}/${SSL_CERT_FILE}"
        SSL_KEY_PATH="${SSL_BASE_DIR}/${SSL_DOMAIN}/${SSL_KEY_FILE}"
        SSL_TRUSTED_PATH="${SSL_BASE_DIR}/${SSL_DOMAIN}/${SSL_TRUSTED_FILE}"
        SSL_CLIENT_CA_PATH="${SSL_BASE_DIR}/${SSL_DOMAIN}/${SSL_CLIENT_CA_FILE}"

        # 证书文件缺失提前警告 (不阻止启动, 便于诊断)
        for f in "${SSL_CERT_PATH}" "${SSL_KEY_PATH}"; do
            [ -f "$f" ] || echo "[entrypoint] ⚠️  SSL 证书文件不存在: $f (HTTPS 将启动失败, 请检查挂载或 SSL_DOMAIN)"
        done

        # 可选: Cloudflare Authenticated Origin Pull
        if [ "${SSL_VERIFY_CLIENT}" = "on" ]; then
            SSL_CLIENT_CA_LINE="ssl_client_certificate ${SSL_CLIENT_CA_PATH};"
            SSL_VERIFY_LINE="ssl_verify_client on;"
        else
            SSL_CLIENT_CA_LINE="# ssl_client_certificate ${SSL_CLIENT_CA_PATH};"
            SSL_VERIFY_LINE="# ssl_verify_client on;"
        fi

        sed -e "s|__NGINX_LISTEN__|${NGINX_LISTEN}|g" \
            -e "s|__NGINX_HTTPS_PORT__|${NGINX_HTTPS_PORT}|g" \
            -e "s|__SSL_CERT__|${SSL_CERT_PATH}|g" \
            -e "s|__SSL_KEY__|${SSL_KEY_PATH}|g" \
            -e "s|__SSL_TRUSTED__|${SSL_TRUSTED_PATH}|g" \
            -e "s|__SSL_CLIENT_CA_LINE__|${SSL_CLIENT_CA_LINE}|g" \
            -e "s|__SSL_VERIFY_LINE__|${SSL_VERIFY_LINE}|g" \
            "${SSL_TPL}" > "${SSL_OUT}"
        HTTPS_INCLUDE="    include https.conf;"
        echo "[entrypoint] SSL 使用域名: ${SSL_DOMAIN}, 证书: ${SSL_CERT_PATH}"
    fi

    # 先替换单行占位符, 再把 __HTTPS_INCLUDE__ 整行替换为 include 或删除
    VHOST_STAGE=$(mktemp)
    sed -e "s|__NGINX_LISTEN__|${NGINX_LISTEN}|g" \
        -e "s|__NGINX_PORT__|${NGINX_PORT}|g" \
        -e "s|__VMESS_PORT__|${VMESS_PORT}|g" \
        -e "s|__TROJAN_PORT__|${TROJAN_PORT}|g" \
        -e "s|__VMESS_WSPATH__|${VMESS_WSPATH}|g" \
        -e "s|__TROJAN_WSPATH__|${TROJAN_WSPATH}|g" \
        "${VHOST_TPL}" > "${VHOST_STAGE}"
    if [ -n "${HTTPS_INCLUDE}" ]; then
        sed "s|__HTTPS_INCLUDE__|${HTTPS_INCLUDE}|" "${VHOST_STAGE}" > "${VHOST_OUT}"
    else
        sed "/__HTTPS_INCLUDE__/d" "${VHOST_STAGE}" > "${VHOST_OUT}"
    fi
    rm -f "${VHOST_STAGE}"

    if [ "${NGINX_HTTPS_PORT}" != "0" ]; then
        echo "[entrypoint] nginx vhost 渲染完成 (HTTP ${NGINX_LISTEN}:${NGINX_PORT} / HTTPS ${NGINX_LISTEN}:${NGINX_HTTPS_PORT})"
    else
        echo "[entrypoint] nginx vhost 渲染完成 (HTTP ${NGINX_LISTEN}:${NGINX_PORT}, HTTPS 未启用)"
    fi
fi

# ---- 渲染 WAF 域名放行规则 --------------------------------------------------
if [ -x /data/nginx/conf/waf/render-waf.sh ]; then
    /data/nginx/conf/waf/render-waf.sh || echo "[entrypoint] render-waf 失败, 继续启动"
fi

# ---- 启动 supervisord (前台, PID1) ------------------------------------------
echo "[entrypoint] 启动 supervisord ..."
# -n 同时作为命令行兜底，防止配置文件中的 nodaemon 设置被覆盖为后台模式。
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
