#!/bin/bash
# =============================================================================
# gen-links.sh  生成 vmess / trojan 单条分享链接 + base64 一键导入订阅
#   隧道域名来源: LINK_DOMAIN 优先; 否则从 cloudflared 日志抓 trycloudflare.com
#   优选域名: PREFER_DOMAIN 设置时, 连接地址(vmess add / trojan server)使用它,
#             而 host / sni 仍用真实隧道域名 (Cloudflare 优选 IP 标准做法)。
#   输出: OUT_DIR/links.txt (可读) 、 OUT_DIR/sub.txt (base64 订阅) 、 stdout 日志
#   用法: gen-links.sh [--wait]
#     --wait  轮询等待隧道域名就绪 (supervisor genlinks 用)
# =============================================================================
set -eu

: "${VMESS_UUID:=f011c012-5f1d-418c-9494-d24d77a9d8f9}"
: "${VMESS_NAME:=xiaonuo}"
: "${VMESS_WSPATH:=/xiaonuo/vmess}"
: "${TROJAN_PWD:=ysyh!9Sky}"
: "${TROJAN_NAME:=xiaonuo}"
: "${TROJAN_WSPATH:=/xiaonuo/trojan}"
: "${LINK_DOMAIN:=}"
# 优选域名 (Cloudflare 优选 IP 对应的域名/CNAME), 留空则连接地址也用隧道域名
: "${PREFER_DOMAIN:=}"
: "${CF_LOG:=/tmp/cloudflared.log}"
: "${OUT_DIR:=/data}"

WAIT=0
[ "${1:-}" = "--wait" ] && WAIT=1

# ---- 确定隧道域名 -----------------------------------------------------------
detect_domain() {
    if [ -n "$LINK_DOMAIN" ]; then
        printf '%s' "$LINK_DOMAIN"
        return 0
    fi
    # 从 cloudflared 日志抓取 quick tunnel 随机域名
    if [ -f "$CF_LOG" ]; then
        grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null \
            | tail -n1 | sed 's#https://##'
        return 0
    fi
    return 0
}

DOMAIN=""
if [ "$WAIT" = "1" ] && [ -z "$LINK_DOMAIN" ]; then
    echo "[gen-links] 等待 cloudflared 隧道域名就绪 ..."
    i=0
    while [ $i -lt 60 ]; do
        DOMAIN=$(detect_domain)
        [ -n "$DOMAIN" ] && break
        i=$((i + 1))
        sleep 3
    done
else
    DOMAIN=$(detect_domain)
fi

if [ -z "$DOMAIN" ]; then
    echo "[gen-links] 未能获取隧道域名 (LINK_DOMAIN 为空且未抓到 trycloudflare 域名)。跳过链接生成。"
    exit 0
fi

# 连接地址: 有优选域名则用优选域名, 否则用隧道域名
ADDR="${PREFER_DOMAIN:-$DOMAIN}"

echo "[gen-links] 隧道域名(host/sni): $DOMAIN"
echo "[gen-links] 连接地址(add/server): $ADDR"

# ---- 编码工具 ---------------------------------------------------------------
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
# URL 编码 (仅对常见保留字符), 用于 trojan 密码与 path
urlenc() {
    printf '%s' "$1" | sed \
        -e 's/%/%25/g' -e 's/ /%20/g' -e 's/!/%21/g' -e 's/#/%23/g' \
        -e 's/\$/%24/g' -e 's/&/%26/g' -e "s/'/%27/g" -e 's/(/%28/g' \
        -e 's/)/%29/g' -e 's/+/%2B/g' -e 's/,/%2C/g' -e 's#/#%2F#g' \
        -e 's/:/%3A/g' -e 's/;/%3B/g' -e 's/=/%3D/g' -e 's/?/%3F/g' \
        -e 's/@/%40/g'
}

# ---- vmess 链接 (base64 JSON) -----------------------------------------------
# add=优选域名; host/sni=隧道域名。附带 alpn/fp/insecure/vcn/pcs 兼容字段。
VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "${VMESS_NAME}-vmess",
  "add": "${ADDR}",
  "port": "443",
  "id": "${VMESS_UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${DOMAIN}",
  "path": "${VMESS_WSPATH}",
  "tls": "tls",
  "sni": "${DOMAIN}",
  "alpn": "",
  "fp": "",
  "insecure": "0",
  "vcn": "",
  "pcs": ""
}
EOF
)
VMESS_LINK="vmess://$(b64 "$VMESS_JSON")"

# ---- trojan 链接 ------------------------------------------------------------
# server=优选域名; host/sni=隧道域名。密码与 path 做 URL 编码。
TROJAN_PWD_ENC=$(urlenc "$TROJAN_PWD")
TROJAN_PATH_ENC=$(urlenc "$TROJAN_WSPATH")
TROJAN_LINK="trojan://${TROJAN_PWD_ENC}@${ADDR}:443?security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${TROJAN_PATH_ENC}#${TROJAN_NAME}-trojan"

mkdir -p "$OUT_DIR"

# ---- 输出可读链接 -----------------------------------------------------------
{
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 隧道域名(host/sni): $DOMAIN"
    echo "# 连接地址(add/server): $ADDR"
    echo "# 端口 443 / TLS 由 Cloudflare 边缘终止"
    echo ""
    echo "$VMESS_LINK"
    echo "$TROJAN_LINK"
} > "$OUT_DIR/links.txt"

# ---- 输出 base64 订阅 (客户端一键导入) --------------------------------------
SUB_PLAIN=$(printf '%s\n%s\n' "$VMESS_LINK" "$TROJAN_LINK")
b64 "$SUB_PLAIN" > "$OUT_DIR/sub.txt"

echo "================= 分享链接 ================="
echo "$VMESS_LINK"
echo "$TROJAN_LINK"
echo "================= 订阅(base64) ============="
cat "$OUT_DIR/sub.txt"; echo ""
echo "============================================"
echo "[gen-links] 已写入 $OUT_DIR/links.txt 与 $OUT_DIR/sub.txt"
