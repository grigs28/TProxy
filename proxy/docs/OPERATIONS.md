# TProxy 运维说明

适用：DNS 劫持 + TLS 终结 + **六类制品透明缓存**（系统包 / Docker / git / Python / Node.js / Java）。

## 日常操作

```bash
cd /opt/TProxy/proxy
docker compose ps                              # 查看状态
docker compose logs -f tengine                 # 查看日志
docker compose exec tengine nginx -s reload    # 改配置后热重载（⚠️ 见下方陷阱）
./tests/acceptance.sh                          # 一键自检（10 组）
```

## 六类缓存速查

| 类型 | 后端 | 缓存位置 | 缓存策略 |
|---|---|---|---|
| 系统包 dnf/yum/apt | nginx `proxy_cache` | `os/` | 元数据 10m / 制品 365d |
| Docker | `registry:2` proxy | `registry/docker/` | registry 自管（TTL 168h） |
| git | `gitcache` | `git/` | gitcache 自管 |
| Python | nginx `proxy_cache` | `python/` | simple 索引 5m / 包文件 365d |
| Node.js | nginx `proxy_cache` | `nodejs/` | 元数据 10m / tarball 365d |
| Java | nginx `proxy_cache` | `java/` | release 365d / **元数据与 SNAPSHOT 不缓存** |

## ⚠️ 两个必须知道的陷阱

### 1. rsync 必须加 `--inplace`

Docker bind mount 绑定的是**挂载时刻的 inode**。`rsync -a` 替换文件时写临时文件再
rename，**改变了 inode**，于是容器内读到的仍是旧内容 —— 配置改完、`nginx -s reload`
也执行了，却完全没有生效。

- 同步一律用 `rsync -a --inplace ...`
- 若改了配置但行为未变，**先怀疑此事**，`docker compose restart <服务>` 可强制重新挂载

### 2. nginx 的 `resolver` 不能用本机 dnsmasq

dnsmasq 已把上游域名劫持到 `192.168.0.18`。若 nginx 用它解析上游，会拿到代理自身
地址，回源变成请求自己 —— 死循环。必须使用公共 DNS（`223.5.5.5`）。

同理，`default_server` 兜底块也不可省略：未匹配 `server_name` 的请求会落到第一个
server 块并被 `proxy_pass $host` 代回自身。

## 新增一个上游（三处改动）

| # | 改动 | 说明 |
|---|---|---|
| 1 | `dnsmasq/dnsmasq.conf` 加 `address=/<域名>/192.168.0.18` | 劫持 |
| 2 | `ca/domains.txt` 加域名，`cd ca && ./gen-cert.sh <域名>` | 证书 |
| 3 | `tengine/conf.d/<类型>.conf` 的 `server_name` 加域名 | 分流 |

改完：

```bash
docker compose restart dnsmasq
docker compose restart tengine      # 用 restart 而非仅 reload，规避 inode 陷阱
```

**各类型的特殊点**：

- **Docker**：上游走 `map $host $docker_upstream` 选择（Docker Hub → 本机 registry:2）
- **git**：转发给 gitcache 时**必须补 `$host` 前缀**（`/域名/owner/repo`），
  否则 gitcache 会 panic；非 git 路径要直连上游（gitcache 不是网页服务器）
- **Node.js**：需 `proxy_hide_header Set-Cookie` + `proxy_ignore_headers Set-Cookie`，
  否则 Cloudflare 的 bot cookie 会让缓存恒为 MISS
- **Java**：元数据/SNAPSHOT 的 location **必须排在 release 制品之前**
  （nginx 正则 location 按出现顺序匹配，先命中者胜出）

## 故障排查

| 现象 | 排查方向 |
|---|---|
| 客户端证书报错 | 根 CA 未安装，或域名不在 `ca/domains.txt` |
| 请求 502 | 上游不可达；`docker compose logs tengine`。若日志含 `too big header`，需加大 `proxy_buffer_size` |
| 缓存恒为 MISS | ① 响应带 `Set-Cookie`（需 ignore）② `${CACHE_BASE}/<类型>` 不可写 ③ 配置未生效（inode 陷阱） |
| **改配置后行为不变** | **inode 陷阱 —— 用 `docker compose restart` 而非仅 reload** |
| Docker 拉取失败 | `docker logs v3-reg-docker`；确认上游 `/v2/` 返回 401 而非超时 |
| git clone 失败 | `docker logs v3-gitcache`；若见 `parseHttpParams` panic，是 URL 少了域名前缀 |
| DNS 不生效 | 客户端未指向 `192.168.0.18`；UDP/TCP 53 被占 |
| 回源解析到本机 | nginx `resolver` 被误改为本机 dnsmasq |

## 关键配置速查

| 项 | 值 |
|---|---|
| 缓存根目录 | `/mnt/HDD/tproxy-cache` |
| dnsmasq 上游 | `223.5.5.5`、`223.6.6.6`（**禁用 `202.99.192.68`**，运营商劫持） |
| nginx resolver | `223.5.5.5`、`223.6.6.6` |
| 内网域名 | `nt08.sxsy` → `192.168.0.38` + `192.168.0.48`（见 `dnsmasq/hosts`） |
| registry 端口 | `127.0.0.1:5001`（仅本机） |
| gitcache 端口 | `127.0.0.1:4999`（仅本机） |

## 备份要点

| 对象 | 位置 | 说明 |
|---|---|---|
| **根 CA 私钥** | `ca/tproxy-ca.key` | **不入库**，丢失则所有客户端需重装 CA。必须离线备份 |
| 配置文件 | git 仓库 | 已版本控制 |
| 缓存数据 | `${CACHE_BASE}` | 可重建，无需备份 |
