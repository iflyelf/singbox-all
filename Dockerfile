# =============================================================================
# sing-box all-in-one 单容器融合镜像
#   基底: iflyelf/sing-box 风格 (ubuntu:resolute + supervisor)
#   集成: sing-box(vmess/trojan) + conduitvpn(住宅IP出口) + cloudflared(隧道入口)
#         + nginx(coraza WAF, 复用 iflyelf/nginx 现成编译产物)
#   守护: supervisord (PID1) 统一管理全部进程, 进程间走 127.0.0.1 loopback
# =============================================================================

#############################
#   Stage: nginxstage       #
#   复用 iflyelf/nginx 现成的 coraza nginx 编译产物, 不重新编译
#   可通过 --build-arg NGINX_IMAGE=... 覆盖
#############################
ARG NGINX_IMAGE=iflyelf/nginx:latest
FROM ${NGINX_IMAGE} AS nginxstage

#############################
#   Stage: builder          #
#   ubuntu:resolute + Go, 编译 sing-box / conduitvpn / cloudflared
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

# 版本: sing-box 锁定, cloudflared/conduitvpn 始终使用最新
ARG SINGBOX_VERSION=v1.13.19
ENV SINGBOX_VERSION=$SINGBOX_VERSION

ARG PKG_DEPS="git curl wget ca-certificates build-essential pkg-config"
ENV PKG_DEPS=$PKG_DEPS

# ***** 安装构建依赖 *****
RUN --mount=type=cache,target=/var/lib/apt/,sharing=locked \
    set -eux && \
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

# ***** 编译 sing-box (锁定版本) *****
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/opt/golang/pkg/mod \
    set -eux && \
    git clone -b $SINGBOX_VERSION --depth 1 --progress https://github.com/SagerNet/sing-box.git /src/sing-box && \
    cd /src/sing-box && \
    export COMMIT=$(git rev-parse --short HEAD) && \
    export VERSION=$(go run ./cmd/internal/read_tag) && \
    go mod download && \
    mkdir -p /go/bin && \
    go build -v -trimpath -tags 'with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,badlinkname,tfogo_checklinkname0' \
        -o /go/bin/sing-box \
        -ldflags "-s -buildid= -X \"github.com/sagernet/sing-box/constant.Version=$VERSION\" -checklinkname=0" \
        ./cmd/sing-box && \
    /go/bin/sing-box version

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

# 运行时依赖: 基础工具 + supervisor + nginx/coraza 运行库
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
    supervisor \
    coreutils \
    gettext-base \
    libpcre2-8-0 \
    libxml2 \
    libxslt1.1 \
    libgd3 \
    libgeoip1t64 \
    libmecab2 \
    zlib1g \
    libssl3 \
    locales"
ENV PKG_DEPS=$PKG_DEPS

RUN --mount=type=cache,target=/var/lib/apt/,sharing=locked \
    set -eux && \
    sed -i 's@URIs: http://[a-z.]*\.ubuntu\.com/ubuntu/@URIs: https://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list.d/ubuntu.sources && \
    touch /etc/apt/apt.conf.d/99verify-peer.conf && echo >>/etc/apt/apt.conf.d/99verify-peer.conf "Acquire { https::Verify-Peer false }" && \
    apt-get update -qqy && apt-get upgrade -qqy && \
    apt-get install -qqy --no-install-recommends $PKG_DEPS --option=Dpkg::Options::=--force-confdef && \
    apt-get -qqy --no-install-recommends autoremove --purge && \
    apt-get -qqy --no-install-recommends autoclean && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone && \
    locale-gen zh_CN.UTF-8 && localedef -f UTF-8 -i zh_CN zh_CN.UTF-8 || true

# ***** 拷贝编译产物 *****
COPY --from=builder /go/bin/sing-box    /usr/bin/sing-box
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
# WAF: 仅覆盖自定义文件, 不动 owasp-crs/ 与 crs-setup.conf
COPY ["./conf/nginx/waf/coraza.conf",             "/data/nginx/conf/waf/coraza.conf"]
COPY ["./conf/nginx/waf/coraza-recommended.conf", "/data/nginx/conf/waf/coraza-recommended.conf"]
COPY ["./conf/nginx/waf/detectiononly.conf",      "/data/nginx/conf/waf/detectiononly.conf"]
COPY ["./conf/nginx/waf/render-waf.sh",           "/data/nginx/conf/waf/render-waf.sh"]

# ***** 初始化: nginx 用户/软链/日志/权限 *****
RUN set -eux && \
    # 注册 libcoraza.so 到动态链接库缓存
    ldconfig && \
    # nginx 用户
    (addgroup --system --quiet nginx || true) && \
    (adduser --quiet --system --disabled-login --ingroup nginx --home /data/nginx --no-create-home nginx || true) && \
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
    # nginx 配置自检
    nginx -t || true

# ***** 端口 *****
# 80: cloudflared 回源 / 直连; 8787: conduitvpn 管理台; 7928: 本地代理(仅容器内)
EXPOSE 80 8787

WORKDIR /etc/sing-box
STOPSIGNAL SIGQUIT
ENTRYPOINT ["docker-entrypoint.sh"]

