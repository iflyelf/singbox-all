#!/bin/bash
# =============================================================================
# gen-links.sh  生成 vmess / trojan 单条分享链接 + base64 一键导入订阅
#   域名来源: LINK_DOMAIN 优先; 否则从 cloudflared 日志抓 trycloudflare.com
#   输出: /data/links.txt (可读) 、 /data/sub.txt (base64 订阅) 、 stdout 日志
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

echo "[gen-links] 使用域名: $DOMAIN"

# ---- b64: 无换行 base64 -----------------------------------------------------
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# ---- vmess 链接 (base64 JSON) -----------------------------------------------
VMESS_JSON=$(cat <<EOF
{"v":"2","ps":"${VMESS_NAME}-vmess","add":"${DOMAIN}","port":"443","id":"${VMESS_UUID}","aid":"0","scy":"auto","net":"ws","type":"none","host":"${DOMAIN}","path":"${VMESS_WSPATH}","tls":"tls","sni":"${DOMAIN}"}
EOF
)
VMESS_LINK="vmess://$(b64 "$VMESS_JSON")"

# ---- trojan 链接 ------------------------------------------------------------
# path 需 URL 编码 (/ 保留可读, 这里仅编码 # 等; path 无特殊字符直接用)
TROJAN_LINK="trojan://${TROJAN_PWD}@${DOMAIN}:443?type=ws&host=${DOMAIN}&path=${TROJAN_WSPATH}&security=tls&sni=${DOMAIN}#${TROJAN_NAME}-trojan"

mkdir -p "$OUT_DIR"

# ---- 输出可读链接 -----------------------------------------------------------
{
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 域名: $DOMAIN (端口 443 / TLS 由 Cloudflare 边缘终止, 回源 http://nginx:80)"
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
