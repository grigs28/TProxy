# TProxy 架构设计方案

制定日期：2026-09-23
状态：待评审

## 1. 目标

内网客户端**零配置**（除一次性设置 DNS 与安装根 CA）即可透明命中缓存，
覆盖六类制品：**系统包（dnf/yum/apt）、git、Docker、Python、Node.js、Java**。

客户端不需要修改任何仓库地址、镜像地址或工具配置——只把 DNS 指向 `192.168.0.18`。

### 前提变更

`192.168.0.18` 当前**无实际使用**（无活跃连接），因此本次为**推倒重建**，
不再受历史遗留约束（旧的 7 个 registry 端口配置错误、3 个容器崩溃循环、
Nexus 空转等问题一并作废）。现有 `v3-*` 容器与镜像文件**全部删除**。

### 覆盖范围

| 项 | 范围 |
|---|---|
| 服务端 | `192.168.0.18` 单点 |
| **客户端** | **`192.168.0.0/16`** —— 整个内网段 |
| 制品 | 系统包（dnf/yum/apt）、git、Docker、Python、Node.js、Java |
| git 仓库 | 沿用 `github.com/grigs28/TProxy.git`，内容全新重写 |

## 2. 总体架构

```
┌────────────────────────────────────────────────────────────────────┐
│ 客户端   openEuler / Ubuntu / CentOS                                │
│ 一次性：① DNS → 192.168.0.18   ② 安装 TProxy 根 CA                  │
│ dnf / apt / yum / git / docker / pip / npm / mvn ── 全部零配置      │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
          ┌────────────────────┴────────────────────┐
          │ DNS :53                                 │ HTTP :80 / HTTPS :443
          ▼                                         ▼
 ┌────────────────────┐            ┌────────────────────────────────────┐
 │  dnsmasq           │            │  tengine                           │
 │  ① 域名劫持 → .18   │            │  ① SNI → 预签证书                   │
 │  ② 内网域名解析      │            │  ② TLS 终结（解密）                 │
 │  ③ 上游 DNS 兜底    │            │  ③ Host + Path 分流                 │
 └────────────────────┘            └───────────────┬────────────────────┘
                                                   │
    ┌──────────┬───────────┬──────────┬────────────┼──────────┐
    ▼          ▼           ▼          ▼            ▼          ▼
┌────────┐ ┌─────────┐ ┌────────┐ ┌─────────┐ ┌────────┐ ┌────────┐
│registry│ │proxy_   │ │proxy_  │ │proxy_   │ │gitcache│ │ 兜底   │
│:2 ×N   │ │cache    │ │cache   │ │cache    │ │        │ │直连上游│
│ docker │ │系统包    │ │Python  │ │Node.js  │ │ git    │ │        │
└───┬────┘ └────┬────┘ └───┬────┘ └────┬────┘ └───┬────┘ └───┬────┘
    └───────────┴──────────┴───────────┴──────────┴──────────┘
                              ▼
              /mnt/HDD/tproxy-cache/
              ├── registry/  ├── os/  ├── python/
              ├── nodejs/    ├── java/  ├── git/
              └── nginx/
```

**Nexus 已移除**（原占 2.7GB 内存、无任何 Java 构建需求、空转 6 天）。

### 3.1 管理界面（阶段 8，重新设计）

现有 `proxy-manager`（Flask + Vue3，约 4000 行）围绕**已废弃的** `generator` +
`hosts-master.txt` 方案设计，其核心 API（`/api/hosts-master`、配置生成）在新架构中
完全用不上，**不复用其代码，重新设计**。

功能范围：

| 功能 | 价值 |
|---|---|
| **缓存命中率统计** | 核心——判断缓存是否真正生效。旧系统正是因「看不见」而崩溃 1.7 万次无人察觉 |
| **劫持规则管理** | 新增上游目前需改 3 处（dnsmasq 域名 + tengine server 块 + 证书），表单化后为一步操作 |
| **证书管理** | CA 与各域名证书的生成、查看、到期提醒 |
| **服务状态总览** | 各后端健康状态、磁盘占用 |
| **日志查看** | — |
| **服务控制** | 重启各组件 |

持久化使用 **SQLite**（单文件，无需额外容器）。

## 3. 服务端组件

| 组件 | 镜像/形式 | 职责 |
|---|---|---|
| `dnsmasq` | alpine + dnsmasq | DNS 劫持、内网解析、上游兜底 |
| `tengine` | axizdkr/tengine | 80/443 入口、TLS 终结、分流、`proxy_cache` |
| `registry-*` | registry:2 | Docker 镜像缓存（按上游分组） |
| `gitcache` | 本地构建（`proxy/gitcache/Dockerfile`） | git 仓库缓存 |

## 4. DNS 层设计

### 4.1 劫持清单

| 类别 | 域名 |
|---|---|
| openEuler | `repo.openeuler.org`、`mirrors.openeuler.org`、`dl-cdn.openeuler.openatom.cn` |
| Ubuntu | `archive.ubuntu.com`、`security.ubuntu.com`、`cn.archive.ubuntu.com`、`ports.ubuntu.com` |
| CentOS / EPEL | `mirror.centos.org`、`mirrorlist.centos.org`、`dl.fedoraproject.org`、`mirrors.fedoraproject.org` |
| 国内镜像站 | `mirrors.aliyun.com`、`mirrors.tuna.tsinghua.edu.cn`、`mirrors.ustc.edu.cn`、`mirrors.huaweicloud.com` |
| Docker | `registry-1.docker.io`、`auth.docker.io`、`production.cloudflare.docker.com`、`quay.io`、`gcr.io`、`ghcr.io`、`k8s.gcr.io`、`registry.k8s.io`、`mcr.microsoft.com` |
| Python | `pypi.org`、`files.pythonhosted.org`、`pypi.tuna.tsinghua.edu.cn` |
| Node.js | `registry.npmjs.org`、`registry.npmmirror.com`、`nodejs.org` |
| Java | `repo1.maven.org`、`repo.maven.apache.org`、`maven.aliyun.com` |
| Git | `github.com`、`gitlab.com`、`gitee.com` |

### 4.2 内网域名解析

`nt08.sxsy` 为内网域名，**并行**指向 `192.168.0.38` 与 `192.168.0.48`——
两台同时在使用，配置两个 IP 是为防止其中一台临时故障：

```
host-record=nt08.sxsy,192.168.0.38,192.168.0.48
```

> ✅ **域名大小写不敏感**：`nt08.sxsy`、`NT08.sxsy`、`Nt08.SxSy` 三者完全等价
> （已在 `192.168.0.18` 实测验证，均返回同一结果）。配置写任一形式均可。
>
> ⚠️ **容错能力有限，需知悉**：`address=/.../` 语法只支持单个地址，必须改用
> `host-record` 才能返回多条 A 记录。dnsmasq 会同时返回两个 IP，但它
> **不具备健康检查能力**——即使其中一台已经故障，仍会继续把该 IP 返回给客户端。
> 客户端能否自动重试另一台取决于其自身实现（curl / 浏览器通常会，但无保证）。
> 因此这**不等于可靠的自动故障转移**，它提供的是「两台都正常时提高并发成功率」。
> 若要求确定性切换，需引入带健康检查的 DNS（如 CoreDNS + 健康检查插件）
> 或 keepalived 浮动 IP。

### 4.3 上游兜底

```
server=223.5.5.5          # 阿里，实测 3ms，结果干净
server=223.6.6.6          # 阿里备用，实测 2-4ms
no-resolv
```

未命中劫持规则的域名转发至上述上游。

> ⚠️ **不使用 `202.99.192.68`（山西联通）**：虽然实测延迟最低（2-4ms），
> 但运营商 DNS 存在劫持与污染问题（用户实测经验），不适合作为解析上游。
> 延迟优势不足以抵消正确性风险。

### 4.4 防护措施（防绕过）

| 措施 | 目的 |
|---|---|
| **丢弃 QUIC（UDP 443）** | 防止客户端走 HTTP/3 绕过 TCP 代理 |
| **封锁 DoT（853 端口）** | 防止加密 DNS 绕过劫持 |
| **封锁已知 DoH 服务商** | 同上 |

## 5. 入口层设计（tengine）

### 5.1 TLS 终结

采用**自签根 CA + 预生成域名证书**方案（劫持域名固定可枚举，无需动态签发）。

```
ca/
├── tproxy-ca.crt / .key     根 CA
└── certs/<域名>.crt|.key    预生成叶子证书
```

> 🔴 **`tproxy-ca.key` 必须严格保管，加入 `.gitignore`，绝不提交。**
> 持有者可伪造任意网站证书。

### 5.2 分流规则

按 `Host` + `Path` 分流至对应后端，保持上游原始路径不变（透明的前提）。

### 5.3 缓存策略

| 内容 | TTL | 理由 |
|---|---|---|
| `.rpm` `.deb` `.whl` `.tgz` `.jar`（release） | 永久 | 内容寻址，不变 |
| Docker blob | 永久 | 按 digest 寻址 |
| 仓库元数据（`repomd.xml`、`Packages.gz`） | 5–30 分钟 | 会更新 |
| PyPI simple 索引 / npm metadata | 5–10 分钟 | 会更新 |
| Docker manifest（tag） | 短 | tag 会移动 |
| **maven `maven-metadata.xml`** | **不缓存** | 缓存导致拿不到新版本 |
| **maven `-SNAPSHOT`** | **不缓存** | 同版本号内容会变 |

启用 `proxy_cache_lock` 合并并发回源，避免缓存击穿。

### 5.4 重定向处理

已实测：`repo.openeuler.org` → 302 → `dl-cdn.openeuler.openatom.cn`。

**实际实现是单层策略**：`proxy_redirect off` 让 302 原样透传，
**完全依赖劫持清单覆盖跳转链上的全部域名**，客户端会再次打到本机。

> ⚠️ 本节原先写的「双重兜底」（另加 `proxy_redirect` 重写 `Location`）
> **技术上不成立** —— 若上游跳到未知第三方域名，重写 `Location` 同样救不了
> （重写目标也不在劫持范围内）。实现选择如实反映：这是**一道单层防线**。

由此产生两个已知风险：

1. **metalink 类响应会绕过缓存** —— `mirrorlist.centos.org`、
   `mirrors.fedoraproject.org` 虽已被劫持，但其返回内容是**指向任意第三方镜像的清单**。
   客户端拿到清单后直连那些未劫持的域名：有外网的客户端静默绕过缓存，
   无外网的客户端直接失败（而内网正是本项目的前提，spec §1）。
2. **跳转目标变更无检测** —— 上游若改跳到未知域名，缓存被绕过且无任何告警。

**后续需求**：对缓存 MISS 率与回源域名做监控告警，列入计划 B 或计划 D。

## 6. 缓存后端映射

| 类型 | 客户端 | 后端 |
|---|---|---|
| 系统包 | `dnf`/`yum`/`apt` | nginx `proxy_cache` |
| Python | `pip` | nginx `proxy_cache` |
| Node.js | `npm`/`yarn`/`pnpm` | nginx `proxy_cache` |
| Docker | `docker pull` | `registry:2` |
| Git | `git clone` | `gitcache` |
| Java | `mvn` | nginx `proxy_cache`（特殊 TTL） |

## 7. 客户端接入脚本 `client-setup.sh`

### 7.1 职责

**脚本为单机形态**，在目标机器上执行一次即可完成接入。批量下发方式（Ansible、
装机流程、逐台执行等）由使用方自行处理，不在本方案范围内。

一条命令完成客户端接入：

| 步骤 | 内容 |
|---|---|
| ① 检测发行版 | Ubuntu / openEuler / CentOS |
| ② 配置 DNS | `192.168.0.18` → `223.5.5.5` → `119.29.29.29` |
| ③ 安装根 CA | 系统信任库 |
| ④ 工具级 CA | docker、Java（按需） |
| ⑤ 自检 | DNS 解析、证书验证、拉取测试 |

### 7.2 🔴 关键：多 DNS 与劫持的冲突

配了 3 个 DNS 后，「劫持」与「兜底」可能互相打架：

| 机制 | 多 DNS 行为 | 影响 |
|---|---|---|
| **glibc resolver**（dnf/apt/curl 默认） | **串行**：首个超时才试下一个 | ✅ 安全，劫持与兜底兼得 |
| **systemd-resolved**（Ubuntu 默认） | **并行查询，取最快返回** | 🔴 **公网 DNS 先返回真实 IP，劫持失效** |

**处理方式**：脚本在 Ubuntu 上**关闭 systemd-resolved**，改用静态
`/etc/resolv.conf`（glibc 串行），确保 `.18` 始终优先、且失败时能兜底。
这一步是方案能否生效的关键，不能省。

### 7.3 工具级 CA

系统信任库**不覆盖**以下工具，需单独处理：

| 工具 | 处理方式 |
|---|---|
| Docker | `/etc/docker/certs.d/<域名>/ca.crt` + 重启 docker |
| Java | `keytool -importcert` 导入 `$JAVA_HOME/lib/security/cacerts` |
| Firefox | 单独的证书库，需手动或用策略文件 |

## 8. 实施步骤

| 阶段 | 内容 | 依赖 |
|---|---|---|
| 0 | **清理旧环境**：删除全部 `v3-*` 容器及其镜像文件 | — |
| 1 | 服务端骨架：dnsmasq + tengine + 系统包缓存（先跑 http 源） | 阶段 0 |
| 2 | TLS 证书体系（CA + 预生成 + MITM） | 阶段 1 |
| 3 | Docker 缓存（registry:2） | 阶段 2 |
| 4 | git 缓存（gitcache） | — |
| 5 | Python / Node.js 缓存 | 阶段 2 |
| 6 | Java 缓存（maven，TTL 策略需谨慎） | 阶段 2 |
| 7 | `client-setup.sh` | 阶段 1 |
| 8 | **统一管理界面**（重新设计，见 3.1） | 阶段 1–7 |

## 9. 已确认决策

| # | 事项 | 结论 |
|---|---|---|
| 1 | **客户端范围** | `192.168.0.0/16` —— 覆盖整个内网段，非个别机器 |
| 2 | **`nt08.sxsy`** | 并行双 IP（`192.168.0.38` + `192.168.0.48`），防单点临时故障 |
| 3 | **Java 缓存** | 走透明 `proxy_cache`（须严格执行 5.3 的 TTL 策略） |
| 4 | **现有 `v3-*` 容器** | **全部删除，含镜像文件** |
| 5 | **git 仓库** | 沿用现有地址 `github.com/grigs28/TProxy.git`，但**内容全新重写** |
| 6 | **管理界面** | 要，**重新设计**（不复用旧 `proxy-manager` 代码），排在阶段 8 |
| 7 | **数据库** | **不需要**。全架构为文件系统存储；管理端如需持久化用 SQLite |

### 已知并接受的风险

- **`nt08.sxsy` 无自动故障转移**：见 4.2 节。经评估**接受此限制**（方案 c）——
  双 A 记录提供的是「两台正常时提高并发成功率」，不做健康检查、不自动摘除故障 IP。
  若日后实际运行发现切换不可靠，再评估升级为 CoreDNS（健康检查插件）
  或 keepalived 浮动 IP。
- **客户端批量部署不在本方案范围内**：`client-setup.sh` 为**单机脚本**形态，
  由使用方自行负责下发方式（Ansible / 装机流程 / 逐台执行等）。

## 10. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-09-23 | 初版。确定推倒重建、覆盖六类制品、移除 Nexus |
| 2026-09-23 | DNS 兜底弃用 `202.99.192.68`（运营商劫持），客户端序列改为 `18 / 223.5.5.5 / 119.29.29.29` |
| 2026-09-23 | 确认客户端范围 `192.168.0.0/16`、`nt08.sxsy` 并行双 IP、Java 走 `proxy_cache`、`v3-*` 全删含镜像文件 |
| 2026-09-23 | `nt08.sxsy` 容错接受现状（不做健康检查）；客户端脚本定为单机形态，批量下发由使用方自理 |
| 2026-09-23 | 管理界面确定重新设计（阶段 8）；确认全架构不需要数据库；`sys-postgres`/`sys-redis` 及 `v3-*` 容器、镜像、缓存数据均已清除 |
