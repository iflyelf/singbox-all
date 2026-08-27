# =============================================================================
# singbox-all 单容器融合镜像
#   基底: ubuntu:resolute + supervisor
#   复用现成编译产物: sing-box (iflyelf/sing-box) + nginx/coraza (iflyelf/nginx)
#   源码编译(始终最新): conduitvpn(住宅IP出口) + cloudflared(隧道入口)
#   守护: supervisord (PID1) 统一管理全部进程, 进程间走 127.0.0.1 loopback
# =============================================================================

# 全局 ARG: 复用的现成镜像 (须在第一个 FROM 之前声明, 才能被各 FROM 引用)
# 可通过 --build-arg NGINX_IMAGE=... / SINGBOX_IMAGE=... 覆盖
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
#   ubuntu:resolute + Go, 编译 conduitvpn / cloudflared (始终最新版)
#############################
FROM --platform=$BUILDPLATFORM ubuntu:resolute AS builder
LABEL maintainer="iflyelf"

ARG TZ=Asia/Shanghai
ENV TZ=$TZ
ARG LANG=zh_CN.UTF-8
ENV LANG=$LANG
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=$DEBIAN_FRONTEND

# GO 环境
ARG GO_VERSION=1.27.0
ENV GO_VERSION=$GO_VERSION
ARG GOROOT=/opt/go
ENV GOROOT=$GOROOT
ARG GOPATH=/opt/golang
ENV GOPATH=$GOPATH
ENV PATH=$PATH:$GOROOT/bin:$GOPATH/bin
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=$GOPROXY

ARG TARGETOS TARGETARCH
ARG GO111MODULE=on
ENV GO111MODULE=$GO111MODULE
ARG CGO_ENABLED=0
ENV CGO_ENABLED=$CGO_ENABLED
ENV GOOS=$TARGETOS
ENV GOARCH=$TARGETARCH

# 版本: cloudflared/conduitvpn 始终使用最新 (sing-box 复用现成镜像, 不在此编译)
ARG PKG_DEPS="git curl wget ca-certificates build-essential pkg-config"
ENV PKG_DEPS=$PKG_DEPS

# ***** 安装构建依赖 *****
RUN set -eux && \
    sed -i 's@URIs: http://[a-z.]*\.ubuntu\.com/ubuntu/@URIs: https://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list.d/ubuntu.sources && \
    touch /etc/apt/apt.conf.d/99verify-peer.conf && echo >>/etc/apt/apt.conf.d/99verify-peer.conf "Acquire { https::Verify-Peer false }" && \
    apt-get update -qqy && apt-get install -qqy --no-install-recommends $PKG_DEPS && \
    rm -rf /var/lib/apt/lists/*

# ***** 安装 golang *****
RUN set -eux && \
    wget --no-check-certificate https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz -O /tmp/go.tar.gz && \
    tar zxf /tmp/go.tar.gz -C /opt && \
    mkdir -pv $GOPATH/bin $GOPATH/src $GOPATH/pkg && \
    ln -sf /opt/go/bin/go /usr/bin/go && ln -sf /opt/go/bin/gofmt /usr/bin/gofmt && \
    go version

# ***** 编译 conduitvpn (最新版, Go stdlib only) *****
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/opt/golang/pkg/mod \
    set -eux && \
    git clone --depth 1 --progress https://github.com/sarices/conduitvpn.git /src/conduitvpn && \
    cd /src/conduitvpn && \
    go build -v -trimpath -ldflags "-s -w" -o /go/bin/conduitvpn ./cmd/conduitvpn && \
    /go/bin/conduitvpn --help >/dev/null 2>&1 || true

# ***** 编译 cloudflared (最新版) *****
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/opt/golang/pkg/mod \
    set -eux && \
    git clone --depth 1 --progress https://github.com/cloudflare/cloudflared.git /src/cloudflared && \
    cd /src/cloudflared && \
    VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev) && \
    go build -v -trimpath \
        -ldflags "-s -w -X main.Version=$VERSION" \
        -o /go/bin/cloudflared ./cmd/cloudflared && \
    /go/bin/cloudflared --version || true

##########################################
#   Stage: 运行镜像                        #
##########################################
FROM ubuntu:resolute
LABEL maintainer="iflyelf"

ARG TZ=Asia/Shanghai
ENV TZ=$TZ
ARG LANG=zh_CN.UTF-8
ENV LANG=$LANG
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=$DEBIAN_FRONTEND

ARG NGINX_DIR=/data/nginx
ENV NGINX_DIR=$NGINX_DIR

# 运行时依赖: 以 nginx-docker 已验证的依赖包为准, 另加 supervisor/openvpn。
# 使用 *-dev 包是为了复用 nginx-docker 在 ubuntu:resolute 中验证过的包名;
# 它们同时提供 nginx/coraza 所需的运行库, 避免使用 resolute 中不存在的旧包名。
ARG PKG_DEPS="\
    bash \
    ca-certificates \
    tzdata \
    curl \
    wget \
    jq \
    iproute2 \
    iptables \
    net-tools \
    procps \
    psmisc \
    lsof \
    adduser \
    python3 \
    supervisor \
    coreutils \
    gettext-base \
    openvpn \
    openssl \
    libssl-dev \
    zlib1g-dev \
    libpcre2-dev \
    libxml2-dev \
    libxslt1-dev \
    libgd-dev \
    libgeoip-dev \
    locales"
ENV PKG_DEPS=$PKG_DEPS

# 不使用 apt cache mount: 多架构并发 + sharing=locked 会导致 lists 索引不完整,
# 曾出现 "Package has no installation candidate" 而 supervisor/openvpn 静默漏装。
RUN set -eux && \
    sed -i 's@URIs: http://[a-z.]*\.ubuntu\.com/ubuntu/@URIs: https://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list.d/ubuntu.sources && \
    touch /etc/apt/apt.conf.d/99verify-peer.conf && echo >>/etc/apt/apt.conf.d/99verify-peer.conf "Acquire { https::Verify-Peer false }" && \
    apt-get update -qqy && apt-get upgrade -qqy && \
    apt-get install -qqy --no-install-recommends $PKG_DEPS --option=Dpkg::Options::=--force-confdef && \
    apt-get -qqy --no-install-recommends autoremove --purge && \
    apt-get -qqy --no-install-recommends autoclean && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone && \
    ( locale-gen zh_CN.UTF-8 && localedef -f UTF-8 -i zh_CN zh_CN.UTF-8 || true )

# ***** 拷贝编译产物 *****
# sing-box: 复用 iflyelf/sing-box 现成产物, 不重新编译
COPY --from=singboxstage /usr/bin/sing-box /usr/bin/sing-box
# conduitvpn / cloudflared: builder 阶段源码编译 (始终最新版)
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
COPY ["./conf/nginx/cache.conf",     "/data/nginx/conf/cache.conf"]
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

# ***** 端口 (host 网络模式下 EXPOSE 仅作文档说明) *****
# 80: nginx (NGINX_LISTEN 控制回环/公网); 8787: conduitvpn 管理台(默认回环)
# 7928: 本地代理(回环); 入口默认统一走 cloudflared 隧道
EXPOSE 80 8787

WORKDIR /etc/sing-box
STOPSIGNAL SIGQUIT
ENTRYPOINT ["docker-entrypoint.sh"]
