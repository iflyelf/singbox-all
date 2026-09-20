# =============================================================================
# singbox-all 单容器融合镜像 (多阶段构建)
#   builder(编译阶段) = iflyelf/ubuntu:latest
#       已预装 Go / 完整工具链, 无需再装 Go 与庞大依赖, 直接编译
#       conduitvpn(住宅IP出口) + cloudflared(隧道入口) 静态二进制。
#   runtime(运行阶段) = iflyelf/ubuntu:lite
#       仅拷贝编译产物 + 复用 iflyelf/sing-box、iflyelf/nginx 现成产物,
#       按需安装 supervisor/openvpn 与 nginx 运行库, 镜像更小。
#   守护: supervisord (PID1) 统一管理全部进程, 进程间走 127.0.0.1 loopback
# =============================================================================

# 全局 ARG: 复用的现成镜像 (须在第一个 FROM 之前声明, 才能被各 FROM 引用)
ARG NGINX_IMAGE=iflyelf/nginx:latest
ARG SINGBOX_IMAGE=iflyelf/sing-box:latest

#############################
#   Stage: nginxstage       #
#   复用 iflyelf/nginx 现成的 coraza nginx 编译产物, 不重新编译
#############################
FROM ${NGINX_IMAGE} AS nginxstage

#############################
#   Stage: singboxstage     #
#   复用 iflyelf/sing-box 现成的 sing-box 编译产物, 不重新编译
#############################
FROM ${SINGBOX_IMAGE} AS singboxstage

#############################
#   Stage: builder          #
#   iflyelf/ubuntu:latest + 预装 Go, 编译 conduitvpn / cloudflared
#############################
FROM --platform=$BUILDPLATFORM iflyelf/ubuntu:latest AS builder
LABEL maintainer="iflyelf"

ARG TZ=Asia/Shanghai
ENV TZ=$TZ
ARG LANG=zh_CN.UTF-8
ENV LANG=$LANG
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=$DEBIAN_FRONTEND

# Go 交叉编译环境 (Go 与工具链已由 iflyelf/ubuntu:latest 预装, 无需再装)
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=$GOPROXY
ARG TARGETOS TARGETARCH
ARG GO111MODULE=on
ENV GO111MODULE=$GO111MODULE
ARG CGO_ENABLED=0
ENV CGO_ENABLED=$CGO_ENABLED
ENV GOOS=$TARGETOS
ENV GOARCH=$TARGETARCH

# 版本锁定(由 update-version 工作流自动更新为最新稳定版)
ARG CONDUITVPN_VERSION=v0.2.0
ENV CONDUITVPN_VERSION=$CONDUITVPN_VERSION
ARG CLOUDFLARED_VERSION=2026.9.1
ENV CLOUDFLARED_VERSION=$CLOUDFLARED_VERSION

# ***** 编译 conduitvpn (Go stdlib only) *****
# 从 go.mod 读取 Go 版本并用 GOTOOLCHAIN 精确锁定, 避免基础镜像 Go 版本
# 过高导致的编译不兼容(如 go-json-experiment 的 undefined 错误)。
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/opt/golang/pkg/mod \
    set -eux && \
    git clone -b ${CONDUITVPN_VERSION} --depth 1 --progress https://github.com/sarices/conduitvpn.git /src/conduitvpn && \
    cd /src/conduitvpn && \
    GOVER=$(grep -oP '^go \K[0-9]+\.[0-9]+(\.[0-9]+)?' go.mod | head -1) && \
    export GOTOOLCHAIN=go${GOVER} && \
    echo "conduitvpn 要求 Go ${GOVER}, 锁定 GOTOOLCHAIN=${GOTOOLCHAIN}" && \
    go version && \
    go build -v -trimpath -ldflags "-s -w" -o /go/bin/conduitvpn ./cmd/conduitvpn && \
    /go/bin/conduitvpn --help >/dev/null 2>&1 || true

# ***** 编译 cloudflared *****
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/opt/golang/pkg/mod \
    set -eux && \
    git clone -b ${CLOUDFLARED_VERSION} --depth 1 --progress https://github.com/cloudflare/cloudflared.git /src/cloudflared && \
    cd /src/cloudflared && \
    GOVER=$(grep -oP '^go \K[0-9]+\.[0-9]+(\.[0-9]+)?' go.mod | head -1) && \
    export GOTOOLCHAIN=go${GOVER} && \
    echo "cloudflared 要求 Go ${GOVER}, 锁定 GOTOOLCHAIN=${GOTOOLCHAIN}" && \
    go version && \
    go build -v -trimpath \
        -ldflags "-s -w -X main.Version=${CLOUDFLARED_VERSION}" \
        -o /go/bin/cloudflared ./cmd/cloudflared && \
    /go/bin/cloudflared --version || true


##########################################
#   Stage: 运行镜像 (runtime)             #
##########################################
FROM iflyelf/ubuntu:lite
LABEL maintainer="iflyelf" \
      org.opencontainers.image.description="singbox-all (sing-box + nginx/coraza + conduitvpn + cloudflared), runtime on ubuntu:lite"

ARG TZ=Asia/Shanghai
ENV TZ=$TZ
ARG LANG=zh_CN.UTF-8
ENV LANG=$LANG
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=$DEBIAN_FRONTEND

ARG NGINX_DIR=/data/nginx
ENV NGINX_DIR=$NGINX_DIR
# nginx sbin 进 PATH; LuaJIT/coraza 共享库进库路径
ENV PATH=${NGINX_DIR}/sbin:/usr/local/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/lib

# ***** 运行阶段按需依赖 *****
# ubuntu:lite 已含 bash/zsh/vim/git/curl/wget/jq/iproute2/net-tools/procps/psmisc/
#   lsof/openssl/ca-certificates/tzdata/locales 等, 此处仅补装缺少的运行组件:
#   supervisor      -> 进程守护(PID1 统一管理)
#   openvpn         -> conduitvpn 依赖的 openvpn 运行
#   iptables        -> tun/透明代理场景
#   python3         -> 部分脚本/工具
#   gettext-base    -> envsubst 渲染配置模板
#   adduser         -> 创建 nginx 用户
#   nginx 运行库(与 iflyelf/nginx 一致):
#     libpcre2-8-0(正则) zlib1g(gzip) libgd3(image_filter)
#     libxml2-16(coraza WAF) libaio1t64(file-aio)
ARG RUNTIME_DEPS="\
    supervisor \
    openvpn \
    iptables \
    python3 \
    gettext-base \
    adduser \
    libpcre2-8-0 \
    zlib1g \
    libgd3 \
    libxml2-16 \
    libaio1t64"
ENV RUNTIME_DEPS=$RUNTIME_DEPS

# 不使用 apt cache mount: 多架构并发 + sharing=locked 会导致 lists 索引不完整,
# 曾出现 "Package has no installation candidate" 而 supervisor/openvpn 静默漏装。
RUN set -eux && \
    DEBIAN_FRONTEND=noninteractive apt-get update -qqy && apt-get upgrade -qqy && \
    DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends $RUNTIME_DEPS --option=Dpkg::Options::=--force-confdef && \
    # 逐个校验, 缺失则构建失败(避免静默发布坏镜像)
    for pkg in $RUNTIME_DEPS; do \
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then \
            echo "ERROR: 运行依赖未成功安装: $pkg" >&2 && exit 1; \
        fi; \
    done && \
    echo "运行依赖验证通过" && \
    DEBIAN_FRONTEND=noninteractive apt-get -qqy autoremove --purge && \
    DEBIAN_FRONTEND=noninteractive apt-get -qqy autoclean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* && \
    ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone

# ***** 拷贝编译产物 *****
# sing-box: 复用 iflyelf/sing-box 现成产物, 不重新编译
COPY --from=singboxstage /usr/bin/sing-box /usr/bin/sing-box
# conduitvpn / cloudflared: builder 阶段源码编译
COPY --from=builder /go/bin/conduitvpn  /usr/bin/conduitvpn
COPY --from=builder /go/bin/cloudflared /usr/bin/cloudflared

# ***** 拷贝 nginx (复用 iflyelf/nginx 现成 coraza 产物) *****
COPY --from=nginxstage /data/nginx            /data/nginx
COPY --from=nginxstage /usr/local/lib         /usr/local/lib
COPY --from=nginxstage /usr/local/share/lua   /usr/local/share/lua

# ***** 拷贝本项目配置与脚本 *****
COPY ["./docker-entrypoint.sh", "/usr/bin/"]
COPY ["./conf/sing-box", "/etc/sing-box"]
COPY ["./conf/supervisor", "/etc/supervisor"]
COPY ["./conf/gen-links.sh", "/usr/bin/gen-links.sh"]
COPY ["./conf/cloudflared-run.sh", "/usr/bin/cloudflared-run.sh"]
COPY ["./www", "/www"]

# nginx 配置: 仅覆盖本项目维护的文件, 保留镜像内 owasp-crs 规则集与 crs-setup.conf
COPY ["./conf/nginx/nginx.conf",     "/data/nginx/conf/nginx.conf"]
COPY ["./conf/nginx/gzip.conf",      "/data/nginx/conf/gzip.conf"]
COPY ["./conf/nginx/proxy.conf",     "/data/nginx/conf/proxy.conf"]
COPY ["./conf/nginx/php.conf",       "/data/nginx/conf/php.conf"]
COPY ["./conf/nginx/websocket.conf", "/data/nginx/conf/websocket.conf"]
COPY ["./conf/nginx/waf.conf",       "/data/nginx/conf/waf.conf"]
COPY ["./conf/nginx/vhost",          "/data/nginx/conf/vhost"]
COPY ["./conf/nginx/https.conf.template", "/data/nginx/conf/https.conf.template"]
COPY ["./conf/nginx/ssl",            "/data/nginx/conf/ssl"]
# WAF: 仅覆盖自定义文件, 不动 owasp-crs/ 与 crs-setup.conf
COPY ["./conf/nginx/waf/coraza.conf",             "/data/nginx/conf/waf/coraza.conf"]
COPY ["./conf/nginx/waf/coraza-recommended.conf", "/data/nginx/conf/waf/coraza-recommended.conf"]
COPY ["./conf/nginx/waf/detectiononly.conf",      "/data/nginx/conf/waf/detectiononly.conf"]
COPY ["./conf/nginx/waf/render-waf.sh",           "/data/nginx/conf/waf/render-waf.sh"]

# ***** 初始化: nginx 用户/软链/日志/权限 *****
RUN set -eux && \
    # 注册 libcoraza.so 到动态链接库缓存
    ldconfig && \
    # 移除基础镜像自带的 cache.conf (proxy_cache 会破坏 WebSocket 长连接)
    rm -f /data/nginx/conf/cache.conf && \
    # nginx 用户 (nginx.conf 使用 user nginx nginx)
    addgroup --system --quiet nginx && \
    adduser --quiet --system --disabled-login --ingroup nginx --home /data/nginx --no-create-home nginx && \
    # sbin 软链
    ln -sf ${NGINX_DIR}/sbin/* /usr/sbin/ && \
    # 日志目录与转发
    mkdir -p ${NGINX_DIR}/logs ${NGINX_DIR}/temp /etc/sing-box /var/log/supervisor && \
    ln -sf /dev/stdout ${NGINX_DIR}/logs/access.log && \
    ln -sf /dev/stderr ${NGINX_DIR}/logs/error.log && \
    # 权限
    chmod a+x /usr/bin/docker-entrypoint.sh /usr/bin/gen-links.sh /usr/bin/cloudflared-run.sh \
              /usr/bin/sing-box /usr/bin/conduitvpn /usr/bin/cloudflared \
              /data/nginx/conf/waf/render-waf.sh && \
    # 关键二进制自检: 缺失则直接让构建失败, 避免静默发布坏镜像
    command -v supervisord && command -v openvpn && command -v nginx && \
    command -v sing-box && command -v conduitvpn && command -v cloudflared && \
    getent passwd nginx && getent group nginx
    # 注: 不在此运行 nginx -t —— nginx.conf 依赖 entrypoint 运行时渲染的
    # vhost/waf 模板, 构建期这些文件尚未生成, 校验会失败。

# ***** 端口 (host 网络模式下 EXPOSE 仅作文档说明) *****
# 80: nginx (NGINX_LISTEN 控制回环/公网); 8787: conduitvpn 管理台(默认回环)
# 7928: 本地代理(回环); 入口默认统一走 cloudflared 隧道
EXPOSE 80 8787

WORKDIR /etc/sing-box
STOPSIGNAL SIGQUIT
# 入口(tini 作为 init, 优雅处理信号)
ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]
