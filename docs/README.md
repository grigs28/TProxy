# TProxy 项目文档

TProxy 项目的文档库：运行环境探查记录、方案调研，以及管理端文档。

## 快速事实

| 项 | 值 |
|---|---|
| 部署主机 | `192.168.0.18`（主机名 `Tengine-V3`） |
| 统一入口 | `http://192.168.0.18:80`（`v3-tengine`，按 `Host` 头分流） |
| 生效的 compose 目录 | `/opt/v3/tproxy/` |
| 缓存根目录 | `/mnt/HDD/tproxy-cache/` |
| 容器命名规则 | `v3-` 业务/服务类，`sys-` 基础中间件类 |

## 环境划分

| 环境 | 主机 | 说明 |
|---|---|---|
| **开发** | `192.168.0.19`（本机） | 开发工作区，`/opt/TProxy/` |
| **生产** | `192.168.0.18` | 运行本文档所述的全部容器 |

工作流：**在本机 `.19` 开发，开发完成后打成 docker 镜像交付给 `.18` 运行。**
不在生产机上直接改容器或配置。

## 它解决什么问题

内网机器（尤其 k8s 集群）无法直连公网镜像仓库。本项目在 `.18` 上起一套**缓存代理**：
客户端把 DNS 指向本机的 `v3-dnsmasq`，公网镜像域名被解析到 `.18`，请求打进 `v3-tengine`
的 80 端口，再按 `Host` 分流到对应的 `registry:2` 缓存代理，命中缓存直接返回，未命中才回源。

## 文档索引

**设计方案**（现行）

- [specs/2026-09-23-architecture-design.md](specs/2026-09-23-architecture-design.md) — TProxy 完整架构设计方案（待评审）

**运行环境记录**（对生产机 `192.168.0.18` 的探查，2026-09 状态）

- [architecture.md](architecture.md) — 架构总览、容器清单、端口与数据流
- [known-issues.md](known-issues.md) — 已知问题与排查结论
- [proxy-cache-research.md](proxy-cache-research.md) — docker / git / npm / dnf 代理缓存方案调研

**管理端文档**（原项目 `doc/` 目录，2026-09-23 迁入）

- [proxy-manager/README.md](proxy-manager/README.md) — Proxy Manager 功能说明
- [proxy-manager/API.md](proxy-manager/API.md) — RESTful API 接口文档
- [proxy-manager/DEPLOY.md](proxy-manager/DEPLOY.md) — 部署指南

> ⚠️ `proxy-manager/` 下三份为项目原有文档，部分信息已过期：路径写作 `/opt/proxy-manager/`
> （实际为 `/opt/TProxy/proxy-manager/`）、IP 示例为 `192.168.91.100`、API 表仅列 7 个端点
> （实际 30+）。**以代码为准。**

## 项目目录对照

| 路径 | 说明 |
|---|---|
| `/opt/v3/tproxy/` | **当前生效**的 compose 与配置（`v3-*` 那套） |
| `/opt/v3-proxy/` | `sys-postgres` / `sys-redis` 归属的项目，含客户端接管脚本 |
| `/opt/v3/` | 早期多方案试验遗留（tengine、dnsmasq、harbor、gitea、pulp 等多份配置并存） |

> ⚠️ `/opt/v3/` 下存在**已被取代的旧配置**，改配置前务必先确认挂载来源，详见
> [known-issues.md](known-issues.md#4-新旧配置并存易改错文件)。

## 关于本目录

本 `docs/` 目录位于 **`192.168.0.19:/opt/TProxy/`**（开发机），内容分三类：
运行环境探查记录、方案调研、管理端文档。

TProxy 项目源码原本存放于生产机 `192.168.0.18:/opt/TProxy/`，已于 2026-09-23
整体迁到本机作为开发基准；生产机上那份已重命名为 `/opt/TProxy.bak.20260923` 保留。
其原有的 `doc/` 目录（`API.md`、`DEPLOY.md`、`README.md`）同日迁入本目录下的
[`proxy-manager/`](proxy-manager/)，项目内不再保留 `doc/`。
