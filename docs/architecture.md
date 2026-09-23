# 架构总览

## 三层结构

`192.168.0.18` 上当前运行的容器分成三拨，**互不相干**：

1. **镜像代理层**（`v3-*`，来自 `/opt/v3/tproxy/docker-compose.yml`）—— 本项目主体
2. **数据库底座**（`sys-*`，来自 `/opt/v3-proxy/`）—— 服务于另一套制品站
3. **独立应用**（`gpustack`、`one-api`、`web-search`、`cc-proxy`、`sbot-web`）—— 与本项目无关

## 容器命名规则

本项目 docker 容器统一使用两类前缀：

- `v3-` —— 业务/服务类容器（`v3-tengine`、`v3-nexus`、`v3-reg-*`、`v3-gitcache`、`v3-dnsmasq`）
- `sys-` —— 基础中间件容器（`sys-postgres`、`sys-redis`）

**新开容器按此命名。** 注意：命名统一不代表同一个 compose 文件，
`sys-*` 的数据卷实际位于 `/opt/v3-proxy/data/`。

## 镜像代理层容器清单

### 入口

| 容器 | 镜像 | 端口 | 说明 |
|---|---|---|---|
| `v3-tengine` | `axizdkr/tengine:latest` | host 网络，**80** | 总入口，按 `Host` 头分流 |

### 缓存代理（`registry:2`，均为 proxy 模式）

| 容器 | 上游 remoteurl | 监听 | 数据目录 | 状态 |
|---|---|---|---|---|
| `v3-reg-quay` | `https://quay.io` | 5000 | `.../registry/data/quay` | 正常 |
| `v3-reg-docker` | `https://registry-1.docker.io` | 5001 | `.../registry/data/docker` | **崩溃循环** |
| `v3-reg-gcr` | `https://gcr.io` | 5002 | `.../registry/data/gcr` | **崩溃循环** |
| `v3-reg-ghcr` | `https://ghcr.io` | 5003 | `.../registry/data/ghcr` | 正常 |
| `v3-reg-k8s-gcr` | `https://k8s.gcr.io` | 5004 | `.../registry/data/k8s-gcr` | **崩溃循环** |
| `v3-reg-k8s-io` | `https://registry.k8s.io` | 5005 | `.../registry/data/k8s-io` | 正常 |
| `v3-reg-mcr` | `https://mcr.microsoft.com` | 5006 | `.../registry/data/mcr` | 正常 |

> 数据目录前缀均为 `/mnt/HDD/tproxy-cache/`。
> 三个崩溃容器的原因见 [known-issues.md](known-issues.md#1-三个-registry-容器无限重启)。

### 其他

| 容器 | 镜像 | 说明 |
|---|---|---|
| `v3-dnsmasq` | `alpine:3.18`（运行时 `apk add dnsmasq`） | DNS 劫持，**整套的关键**；53/tcp+udp |
| `v3-gitcache` | `acache/gitcache:local` | git 仓库缓存代理，缓存 `/mnt/HDD/tproxy-cache/git`（已用 564M） |
| `v3-nexus` | `sonatype/nexus3:3.70.1` | 制品仓库（maven/npm 等），8081；内存占用约 39%，是这套里最重的 |

## 数据流

```
客户端 (docker pull registry-1.docker.io/xxx)
   │  DNS 查询
   ▼
v3-dnsmasq ── 把 registry-1.docker.io 等域名劫持为 192.168.0.18
   │
   ▼
v3-tengine :80 ── 按 Host 头匹配 conf.d/*.conf
   │
   ▼
v3-reg-xxx :500X (registry:2 proxy 模式)
   │  命中缓存 → 直接返回
   │  未命中   → 回源 remoteurl
   ▼
/mnt/HDD/tproxy-cache/registry/data/<name>
```

## 关键配置文件

实际生效的配置全部在 `/opt/v3/tproxy/` 下：

| 配置 | 路径 |
|---|---|
| tengine 主配置 | `/opt/v3/tproxy/conf/tengine/nginx.conf` |
| tengine 分流规则 | `/opt/v3/tproxy/conf/tengine/conf.d/registry-*.conf`（7 个） |
| 各 registry | `/opt/v3/tproxy/conf/registry/<name>/config.yml` |
| dnsmasq | `/opt/v3/tproxy/conf/dnsmasq/dnsmasq.conf` |
| dnsmasq 静态 hosts | `/opt/v3/tproxy/data/dnsmasq/hosts` |

dnsmasq 劫持的域名：`docker.io`、`registry-1.docker.io`、`production.cloudflare.docker.com`、
`quay.io`、`gcr.io`、`ghcr.io`、`k8s.gcr.io`、`registry.k8s.io`、`mcr.microsoft.com`，
以及内部域名 `nexus.local`、`docker.nexus.local`。

## 数据库底座（`sys-*`）

归属 `/opt/v3-proxy/` 项目，**不是** `v3-*` 那套的配套：

| 容器 | 镜像 | 端口 | 数据卷 |
|---|---|---|---|
| `sys-postgres` | `postgres:15` | 5432 | `/opt/v3-proxy/data/postgres_data` |
| `sys-redis` | `redis:7` | 6379 | `/opt/v3-proxy/data/redis_data` |

- PostgreSQL 中现有业务库：`pulp`、`gitea`（默认库为 `pulp`）
- 凭据见 `/opt/v3-proxy/` 下的环境配置（**勿写入文档**）
- `/opt/v3-proxy/` 下另有 `init_pupl.sh`、`ins_db.sh`、`kolla-ansible/`，以及
  `set_pip.sh` / `set_npm.sh` / `set_dnf.sh` / `set_wget.sh` / `set_docker.sh`
  —— 一整套「把客户端各包管理器全指向本机」的接管脚本

> ⚠️ 当前 `pulp`、`gitea`、`harbor`、`adguard` 的**容器均不存在**，
> 数据库起来了却无应用连接，处于空转状态。
