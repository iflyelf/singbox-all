# singbox-all

sing-box + conduitvpn + cloudflared + nginx 四合一单容器镜像。

- **入口**：Cloudflare 隧道，宿主机无需公网 IP、无需开放任何入站端口
- **出口**：conduitvpn 自动接入 VPNGate 住宅 IP，节点失效自动切换
- **协议**：vmess-ws、trojan-ws（经 nginx 反代，带 coraza WAF）
- **守护**：容器内 supervisor 统一管理全部进程，崩溃自动重启

```
客户端 --https--> Cloudflare --> cloudflared --> nginx:80 --> sing-box --> conduitvpn --> VPNGate 住宅IP --> 目标站点
```

---

## 一、部署

### 1. 前置要求

- Linux 宿主机，已安装 Docker 与 Docker Compose v2
- 内核已启用 TUN 设备（`/dev/net/tun` 存在）

```bash
# 检查 TUN 设备
ls -l /dev/net/tun

# 若不存在则加载模块
sudo modprobe tun
```

### 2. 获取项目

```bash
git clone https://github.com/iflyelf/singbox-all.git
cd singbox-all
```

### 3. 准备配置

```bash
cp .env.example .env
```

编辑 `.env`，**至少修改以下几项**：

| 变量                 | 说明                                                |
| -------------------- | --------------------------------------------------- |
| `VMESS_UUID`       | vmess 的 UUID，务必换成自己的（`uuidgen` 可生成） |
| `TROJAN_PWD`       | trojan 密码                                         |
| `UI_PASSWORD`      | conduitvpn 管理台密码，**必须 ≥16 字符**     |
| `LOCAL_PROXY_PASS` | 本地代理密码，**必须 ≥16 字符**              |

> 两个密码不足 16 字符时 conduitvpn 会拒绝启动。

### 4. 启动

```bash
docker compose up -d
```

首次启动需拉取并测速 VPNGate 节点，约 1～3 分钟后隧道进入可用状态。

### 5. 确认运行状态

```bash
# 五个进程应均为 RUNNING（genlinks 为一次性任务，完成后显示 EXITED 属正常）
docker exec singbox supervisorctl status

# 查看启动日志
docker compose logs -f
```

日志中出现下面两行说明就绪：

```
webui listening ... path=/xxxxxxxx/ auth="login required"     # conduitvpn 就绪
https://xxxx-xxxx-xxxx.trycloudflare.com                      # 隧道域名
```

---

## 二、使用

### 获取客户端连接信息

容器启动后会自动生成分享链接与订阅，保存在宿主机 `./data/` 目录：

```bash
# 查看 vmess / trojan 分享链接
cat ./data/links.txt

# 查看一键导入订阅（base64）
cat ./data/sub.txt
```

也可以从日志中直接查看：

```bash
docker compose logs | grep -A5 '分享链接'
```

### 导入客户端

- **单条链接**：复制 `links.txt` 里的 `vmess://` 或 `trojan://`，在客户端选择「从剪贴板导入」
- **一键导入**：复制 `sub.txt` 的全部内容，在客户端选择「导入订阅」或粘贴订阅内容

支持 v2rayN、Nekobox、sing-box、Clash Meta 等常见客户端。

### 重新生成链接

使用 quick tunnel 时，**每次重启容器域名都会变化**，需重新生成链接：

```bash
docker exec singbox gen-links.sh
cat ./data/links.txt
```

### 访问 conduitvpn 管理台

管理台默认只监听 `127.0.0.1:8787`，不对公网开放。

**方式一：SSH 端口转发**（推荐，无需额外配置）

```bash
# 在本地电脑执行
ssh -L 8787:127.0.0.1:8787 用户名@服务器IP
```

然后浏览器打开 `http://127.0.0.1:8787`。管理台路径是随机的，从日志里取：

```bash
docker compose logs | grep 'webui listening'
```

**方式二：经 Cloudflare 命名隧道**

在 Cloudflare Zero Trust 面板给隧道添加一条 Public Hostname，指向 `http://127.0.0.1:8787`，建议再叠加 Cloudflare Access 做二次鉴权。

**方式三：临时直接暴露到公网（容器内操作，不改镜像）**

临时把管理台改为监听 `0.0.0.0`，在容器内重启 conduitvpn 即可，无需重建容器：

```bash
docker exec singbox sh -c '
supervisorctl stop conduitvpn
sleep 2
UI_HOST=0.0.0.0 \
LOCAL_PROXY_HOST=127.0.0.1 \
NETWORK_MODE=host \
UI_USER=admin \
UI_PASSWORD="Chqmyg#2024Moon!" \
LOCAL_PROXY_USER=proxy \
LOCAL_PROXY_PASS="Chqmyg#2024Moon!" \
HY2_PORT=0 \
nohup /usr/bin/conduitvpn --data-dir /data/conduitvpn > /tmp/conduit-manual.log 2>&1 &
sleep 8
ss -lntp | grep ":8787" || true
grep "webui listening" /tmp/conduit-manual.log | tail -1
'
```

确认监听为 `0.0.0.0:8787` 后，浏览器访问：

```
http://服务器公网IP:8787/<日志里的随机path>/
```

随机路径从日志获取：

```bash
docker logs singbox | grep "webui listening"
```

⚠️ 此方式把管理台暴露在公网所有网卡，仅靠密码保护。用完立即恢复为仅本机监听：

```bash
docker exec singbox supervisorctl restart conduitvpn
```

（supervisor 重启会用回容器默认的 `UI_HOST=127.0.0.1`，仅本机可达。）

管理台可以查看当前住宅 IP、节点延迟、切换指定国家或锁定节点、查看实时日志。

### 验证出口是否为住宅 IP

```bash
docker exec singbox sh -c \
  'curl -fsS --socks5-hostname 127.0.0.1:7928 \
  --proxy-user "$LOCAL_PROXY_USER:$LOCAL_PROXY_PASS" \
  https://api.ipify.org'
```

返回的应是 VPNGate 节点 IP，而非你服务器的 IP。

---

## 三、常用运维命令

```bash
# 更新到最新镜像
docker compose pull && docker compose up -d

# 重启
docker compose restart

# 停止并删除容器（保留 ./data 数据）
docker compose down

# 查看实时日志
docker compose logs -f

# 单独重启某个进程
docker exec singbox supervisorctl restart conduitvpn
docker exec singbox supervisorctl restart nginx

# 进入容器
docker exec -it singbox bash
```

---

## 四、按需调整

### 使用固定域名（推荐长期使用）

quick tunnel 域名随机且每次重启变化。改用命名隧道可获得固定域名：

1. 在 Cloudflare Zero Trust → Networks → Tunnels 创建隧道，复制 token
2. 编辑 `.env`：

```bash
TUNNEL_TOKEN=你的隧道token
LINK_DOMAIN=你的固定域名
```

3. 在面板给隧道添加 Public Hostname，指向 `http://127.0.0.1:80`
4. 重启：`docker compose up -d`

### 开放 80 端口直连（不经 Cloudflare）

编辑 `.env`：

```bash
NGINX_LISTEN=0.0.0.0
LINK_DOMAIN=你的服务器IP或域名
```

重启后可直连 80 端口。此时端口暴露在公网，请自行配置防火墙。

### 修改对外端口（端口冲突时）

宿主机 80 端口被占用时，改用其他端口：

```bash
NGINX_PORT=8080
```

cloudflared 回源地址会自动跟随，无需额外配置；直连模式下客户端链接端口需相应调整。

### WAF 放行自定义域名

使用自有域名时，把域名加入放行列表，避免 WAF 拦截 WebSocket 流量：

```bash
WAF_ALLOW_DOMAINS=vmess.example.com,trojan.example.com
```

`trycloudflare.com` 已默认放行。

### 修改协议端口与路径

```bash
VMESS_PORT=6601
VMESS_WSPATH=/xiaonuo/vmess
TROJAN_PORT=6602
TROJAN_WSPATH=/xiaonuo/trojan
```

修改后重启容器，nginx 分流规则与客户端链接会自动同步更新。

---

## 五、故障排查

| 现象                 | 排查方向                                                                     |
| -------------------- | ---------------------------------------------------------------------------- |
| 容器反复重启         | `docker compose logs` 查看；常见原因是密码不足 16 字符                     |
| `links.txt` 未生成 | 隧道域名还没就绪，等待后执行`docker exec singbox gen-links.sh`             |
| 客户端连不上         | 确认链接是最新的（重启后域名会变）；检查`supervisorctl status`             |
| 出口 IP 不是住宅 IP  | 隧道可能仍在切换节点，查看管理台状态或`docker compose logs \| grep conduit` |
| 提示 TUN 设备不可用  | 宿主机执行`sudo modprobe tun`                                              |

代理流量出站只走 conduitvpn，**隧道不可用时连接会失败而不会退回服务器本机 IP**，这是防止真实 IP 泄漏的预期行为。

### 选择出站模式

默认只走 conduitvpn 住宅 IP：

```env
SINGBOX_FALLBACK=none
```

此模式下所有流量经 VPNGate 住宅 IP 出口；VPNGate 不可用时连接失败，绝不使用本机直连，防止真实 IP 泄漏。

如果要直接使用本机线路（不经 VPNGate），改为：

```env
SINGBOX_FALLBACK=direct
```

此模式为**纯直连**：出站只有 `direct`，直接走本机公网 IP，完全不连 conduitvpn/VPNGate，也没有 urltest 选路。出口即本机 IP，**不是住宅 IP**。

修改后重新创建容器：

```bash
docker compose up -d --force-recreate
```

---

## 六、配置项速查

| 变量                                        | 默认值                    | 说明                                             |
| ------------------------------------------- | ------------------------- | ------------------------------------------------ |
| `VMESS_PORT` / `VMESS_WSPATH`           | 6601 /`/xiaonuo/vmess`  | vmess 端口与 WS 路径                             |
| `VMESS_UUID`                              | —                        | vmess UUID，务必自行更换                         |
| `TROJAN_PORT` / `TROJAN_WSPATH`         | 6602 /`/xiaonuo/trojan` | trojan 端口与 WS 路径                            |
| `TROJAN_PWD`                              | —                        | trojan 密码                                      |
| `UI_USER` / `UI_PASSWORD`               | admin / —                | 管理台账号密码（密码 ≥16 字符）                 |
| `UI_HOST`                                 | 127.0.0.1                 | 管理台监听地址                                   |
| `LOCAL_PROXY_USER` / `LOCAL_PROXY_PASS` | proxy / —                | 本地代理凭据（密码 ≥16 字符）                   |
| `LOCAL_PROXY_HOST` / `LOCAL_PROXY_PORT` | 127.0.0.1 / 7928          | 本地代理监听                                     |
| `SINGBOX_FALLBACK`                        | none                      | `none` 只走住宅IP；`direct` 纯直连(本机IP)   |
| `NGINX_LISTEN`                            | 127.0.0.1                 | nginx 监听地址，`0.0.0.0` 开放公网             |
| `NGINX_PORT`                              | 80                        | nginx 对外端口，冲突时可改，cloudflared 自动跟随 |
| `NETWORK_MODE`                            | host                      | conduitvpn 路由模式，host 网络下须为 host        |
| `TUNNEL_TOKEN`                            | 空                        | 留空走 quick tunnel，填值走命名隧道              |
| `LINK_DOMAIN`                             | 空                        | 隧道域名（host/sni），留空自动抓取，填值优先使用 |
| `PREFER_DOMAIN`                           | 空                        | 优选域名，填值后连接地址走 Cloudflare 优选 IP    |
| `WAF_ALLOW_DOMAINS`                       | 空                        | WAF 放行域名，逗号分隔                           |
| `HY2_PORT`                                | 0                         | hysteria2，隧道不支持 UDP 故关闭                 |
