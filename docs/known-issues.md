# 已知问题

记录于 2026-09-23，基于对 `192.168.0.18` 的实际探查。

---

## 1. 三个 registry 容器无限重启

**现象**：`docker ps` 中 `v3-reg-docker`、`v3-reg-gcr`、`v3-reg-k8s-gcr` 的
`Up` 时间只有几秒到几十秒，与其他容器的 `Up 6 days` 形成鲜明对比。

**重启计数**（截至 2026-09-23）：

| 容器 | RestartCount |
|---|---|
| `v3-reg-docker` | 19246 |
| `v3-reg-gcr` | 17635 |
| `v3-reg-k8s-gcr` | 17635 |

近 10 分钟内仍 panic 19 次，已持续 3 个多月。

**根因**：不是配置错误——这三个与正常的四个（quay / ghcr / mcr / k8s-io）配置
**完全一致**（含 DNS 设置）。真正原因是 `registry:2` 在 proxy 模式启动时会主动
探测上游 `/v2/`，而这四个上游在国内网络下**不可达**，探测超时导致启动即 panic：

```
panic: Get "https://registry-1.docker.io/v2/": dial tcp 69.63.176.15:443: i/o timeout
```

调用栈位置：`registry/handlers/app.go:324`（`NewApp`）→ `registry/registry.go:161`。

- `registry-1.docker.io`、`gcr.io`、`k8s.gcr.io` —— 不可达 → panic
- `quay.io`、`ghcr.io`、`mcr.microsoft.com`、`registry.k8s.io` —— 可直连 → 正常

`restart: unless-stopped` 会不断拉起，形成崩溃循环。

**注意一个设计矛盾**：`v3-dnsmasq` 把 `registry-1.docker.io` 劫持到 `.18` 正是为了
绕开不可达问题，但容器自身配了公共 DNS（`223.5.5.5` 等），**绕过了 dnsmasq**，
直接解析到不可达的真实 IP。若反过来把容器 DNS 指向 dnsmasq，则会解析到 `.18`
→ tengine → `127.0.0.1:5001` → **代理自己**，形成死循环，同样不通。

**建议**：先确认这三个上游是否有可用的出网通道（代理）。
若无，直接停掉并 `restart: no`，避免每天数千次无效重启白耗资源。

---

## 2. `v3-tengine` 显示 unhealthy 是假警报

**现象**：`v3-tengine` 状态为 `Up 6 days (unhealthy)`，健康检查日志：

```
wget: can't connect to remote host: Connection refused
```

**根因**：健康检查命令为 `wget -q --spider http://localhost/`，而容器内
`localhost` 解析到 `::1`（IPv6），tengine 的 nginx 只监听 IPv4
（`0.0.0.0:80`，无 `[::]:80`），因此连接被拒。

**服务本身完全正常**，实测：

```
curl -H "Host: quay.io" http://127.0.0.1/v2/   →  HTTP 200
```

**建议**：把健康检查改为 `http://127.0.0.1/` 即可消除误报。

---

## 3. 缓存全空，应用层空转

**现象一**：所有 registry 缓存目录均为 0 字节：

```
0  /mnt/HDD/tproxy-cache/registry/data/{docker,gcr,ghcr,k8s-gcr,k8s-io,mcr,quay}
0  /mnt/HDD/tproxy-cache/nginx
564M  /mnt/HDD/tproxy-cache/git      ← 仅 git 缓存在真实干活
```

说明镜像代理层基本没被实际使用过，或从未命中过缓存。

**现象二**：`sys-postgres` / `sys-redis` 在运行，但依赖它们的应用容器
（`pulp`、`gitea`、`harbor`、`adguard`）**一个都不存在**，数据库空转。

**建议**：确认这套代理当前是否还有使用者。若已废弃，考虑整体下线以释放
`v3-nexus` 占用的内存（约 39%）与三个崩溃容器的 CPU 开销。

---

## 4. 新旧配置并存，易改错文件

**现象**：`/opt/v3/` 下同时存在多份同名服务的配置，**实际生效的只有
`/opt/v3/tproxy/` 那一份**。

典型陷阱——dnsmasq 有两份配置，内容不同：

| 文件 | 劫持指向 | 是否生效 |
|---|---|---|
| `/opt/v3/tproxy/conf/dnsmasq/dnsmasq.conf` | `192.168.0.18` | ✅ **实际生效** |
| `/opt/v3/dnsmasq/conf/dnsmasq.conf` | `192.168.0.36` | ❌ 旧配置，已废弃 |

同理，`/opt/v3/tengine/`、`/opt/v3/dnsmasq/`、`/opt/v3/gitcache.bak/`、
`/opt/v3/pulp.bak.*/`、`/opt/v3/tproxy.001/`、`/opt/v3/tproxy.002/`、
`/opt/v3/tproxy.bak/` 等目录均属遗留。

**建议**：改任何配置前，先确认容器的实际挂载来源：

```bash
docker inspect <容器名> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
```

确认无误后再改，避免改了不生效的文件。
