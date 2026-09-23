# 代理缓存方案调研

调研日期：2026-09-23
主题：docker / git / npm / dnf 四类代理缓存，当前是否有比现有实现更好的方案。

## 现有实现

| 类别 | 当前方案 | 状态 |
|---|---|---|
| Docker 镜像 | 7 个独立 `registry:2`（proxy 模式）+ tengine 按 Host 分流 | 其中 3 个崩溃循环 |
| Git | `acache/gitcache` + tengine 转发 | 唯一有实际缓存（564M） |
| npm / dnf | 无 | 未部署（Nexus/Pulp 已装但空转） |

---

## Docker 镜像代理

| 方案 | 特点 | 适用 |
|---|---|---|
| **registry:2**（现用） | 最简单稳定，但功能裸：无保留策略、无 UI、故障不可见 | 单上游、临时场景 |
| **Zot** | 单二进制单配置，资源占用极低；支持 `keepTags`/`pulledWithin` 保留策略与 GC | 替代裸 registry:2 的首选 |
| **Harbor** | 漏洞扫描、细粒度 RBAC、镜像复制齐全；但臃肿、吃资源、通常需 K8s | 中大型企业 |
| **Nexus OSS** | 多格式（Docker+npm+yum+pypi）；纯 Docker 场景算 overkill | 需统一管多格式 |

**Zot 的已知缺陷**：首次拉取会下载镜像的**所有架构**（浪费空间）；大镜像可能超时（EOF）需重试；**上游断线时不服务已缓存镜像**。

## npm

**Verdaccio** 在轻量场景明显占优：Node 实现，约 10MB 内存，零配置启动，支持私有包发布、公共包缓存代理、权限控制与插件扩展。仅支持 npm。

需与 Maven/Docker 统一管理时才选 **Nexus**（hosted/proxy/group 三种仓库类型，但配置繁琐、资源占用大）。

## dnf / yum

- **Pulp** —— 已存在于本项目。GPL-2.0 自由软件，无 EULA、无配额限制，支持 air-gapped 安装，格式覆盖最全（rpm/deb/python/npm/容器/Maven 等），RBAC 按插件细分（160+ 角色）。内容模型为 Remote / Repository / Publication / Distribution 四段式，支持不复制文件而发布多视图。
  - 代价：UI 相对年轻，CLI 与 REST API 是主要入口；社区有运维反馈称其**复杂且脆弱**，适合基础设施类仓库而非 DevOps 高频场景。
- **Nexus** proxy repository —— 配置直观，但社区有观点认为它"不适合这个问题域"。
- **reposync + createrepo + nginx** —— 最原始，但也最可控、最稳。

## git

**关键结论：Nginx 的 `proxy_cache` 对 Git 智能 HTTP 基本无效。**

原因：`git fetch` 是协商式协议——客户端声明自己已有哪些对象，服务端针对该请求**实时计算 packfile**（`POST /git-upload-pack`），不存在可缓存的静态响应。因此 tengine 对 git 流量起的是转发作用，真正缓存的是 gitcache。

| 方案 | 机制 | 评价 |
|---|---|---|
| **gitcache**（现用） | 惰性：首次请求回源并建镜像，后续本地服务 | 简单可用 |
| **git-cache-proxy** | 只读代理；每次请求先增量 `git fetch` 再服务，故总能返回所请求的 ref；并发客户端合并为单次上游 fetch；LFS 对象按内容寻址跨仓库共享 | 更完善 |
| **Gitea / GitLab pull-mirror** | 定时全量镜像 | 非惰性，有滞后，且会在本地留存完整副本（敏感仓库合规风险） |
| **nginx proxy_cache** | 通用 HTTP 缓存 | 对 clone/fetch 无效，仅能加速 Release 等静态文件 |

**git-cache-proxy 基准数据**（64MB 仓库 / 模拟 20Mbit/s / 60ms RTT）：

| 场景 | 耗时 | 传输量 |
|---|---|---|
| 直连上游 | 28.1s | 64MB |
| 冷代理（首个请求） | 28.5s | 64MB |
| **热代理（后续请求）** | **0.6s** | **~0MB** |

---

## 三点判断

### 1. 最大的浪费是 Nexus 空转

`v3-nexus` 持续占用约 39% 内存，但六天内未被使用过。Nexus OSS 单个实例即可覆盖 docker proxy + npm proxy + yum proxy + pypi——即现有 7 个 `registry:2` 加上尚未部署的 npm/dnf 代理。已有能力未被利用。

### 2. 换软件治不了当前的病

三个 registry 崩溃的直接原因是：

```
panic: Get "https://registry-1.docker.io/v2/": dial tcp 69.63.176.15:443: i/o timeout
```

上游 `registry-1.docker.io`、`gcr.io`、`k8s.gcr.io` 不可达。Zot 在这一点上与 registry:2 相同（文档明确说明上游断线时不服务缓存）。**这是出网通道问题，不是选型问题**——应先解决通道，再谈更换软件。

### 3. tengine + dnsmasq 的透明劫持架构是优势

客户端零配置即可命中缓存。更换为 Harbor/Nexus 后若要保留此特性，需继续用 tengine 做 Host 转发到其后端端口。不能依赖 `registry-mirrors`——该配置**仅对 Docker Hub 生效**，其他上游（ghcr/quay/k8s 等）需要每个节点单独配置 `/etc/docker/certs.d/*/hosts.toml`。

---

## 来源

- [利用 ZOT 搭建个人 docker 镜像仓库](https://blog.csdn.net/weixin_42727069/article/details/161492070)
- [部署 Zot Registry 作为 Docker 容器镜像私有化仓库](https://blog.gazer.win/essay/deploy-zot-registry-as-private-docker-container-image-repository.html)
- [Anyone have recommendations for an image cache? (Hacker News)](https://news.ycombinator.com/item?id=45367980)
- [Docker 镜像加速与安全：镜像代理与私有仓库实战指南](https://cloud.baidu.com/article/3850510)
- [企业团队自建 npm 仓库](https://blog.csdn.net/weixin_58540586/article/details/147272430)
- [工程化实践：搭建 npm 私服](https://lianpf.github.io/posts/frontend-develop/how-to-build-npm-private-registry-with-verdaccio/)
- [Pulp: The 100% Open-Source Artifact Manager](https://undercodetesting.com/pulp-the-100-open-source-artifact-manager-thats-breaking-nexus-and-artifactorys-stranglehold-video/)
- [Yum/Apt Package Repository Management (Server Fault)](https://serverfault.com/questions/820493/yum-apt-package-repository-managament-mirrors-and-hosted-must-be-something-bet)
- [Caching git clones across a slow network](https://rolandsdev.blog/posts/caching-git-clones-across-a-slow-network/)
- [git-cache-proxy](https://lib.rs/crates/git-cache-proxy)
- [git-cloner/gitcache](https://github.com/git-cloner/gitcache)
