#!/bin/sh
# =============================================================================
# render-waf.sh  (POSIX sh, Compose / K8s 通用)
#   从环境变量 WAF_ALLOW_DOMAINS (逗号分隔) 生成 detectiononly.conf
#   对匹配的 Host 整域放行 (ctl:ruleEngine=DetectionOnly), 避免 WAF 拦截
#   代理 WebSocket 载荷。固定放行 cloudflare quick tunnel 域名。
#
#   自定义规则 ID 使用 9000000+ 段, 避免与 CRS 官方规则冲突。
# =============================================================================
set -eu

OUT="${WAF_RULE_FILE:-/data/nginx/conf/waf/detectiononly.conf}"
EXTRA="${WAF_ALLOW_DOMAINS:-}"

{
    echo "# ============================================================================="
    echo "# 自动生成, 请勿手动编辑。由 render-waf.sh 依据 WAF_ALLOW_DOMAINS 渲染。"
    echo "# ============================================================================="
    echo ""
    echo "# 固定放行: cloudflare quick tunnel 随机域名"
    cat <<'EOF'
SecRule REQUEST_HEADERS:Host "@rx (?:^|[.])trycloudflare\.com(?::[0-9]+)?$" \
    "id:9000001,phase:1,pass,nolog,t:lowercase,ctl:ruleEngine=DetectionOnly"
EOF
    echo ""

    if [ -n "$EXTRA" ]; then
        echo "# 环境变量 WAF_ALLOW_DOMAINS 追加放行"
        id=9000010
        # 逗号分隔遍历
        OLDIFS=$IFS
        IFS=','
        for d in $EXTRA; do
            # 去首尾空白
            d=$(printf '%s' "$d" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$d" ] && continue
            # 转义正则点号
            esc=$(printf '%s' "$d" | sed 's/\./\\./g')
            printf 'SecRule REQUEST_HEADERS:Host "@rx (?:^|[.])%s(?::[0-9]+)?$" \\\n' "$esc"
            printf '    "id:%s,phase:1,pass,nolog,t:lowercase,ctl:ruleEngine=DetectionOnly"\n' "$id"
            id=$((id + 1))
        done
        IFS=$OLDIFS
    fi
} > "$OUT"

echo "[render-waf] 已生成 $OUT (WAF_ALLOW_DOMAINS='${EXTRA}')"
