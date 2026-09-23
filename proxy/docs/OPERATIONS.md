# TProxy 运维说明（核心代理层）

适用：计划 A 交付的 DNS 劫持 + TLS 终结 + 系统包透明缓存。

## 日常操作

```bash
cd /opt/TProxy/proxy
docker compose ps                              # 查看状态
docker compose logs -f tengine                 # 查看日志
docker compose exec tengine nginx -s reload    # 改配置后热重载
./tests/acceptance.sh                          # 一键自检
```

## 新增一个上游仓库（三处改动）

透明缓存要求「劫持域名可枚举，且 tengine 有对应 server 块、CA 有对应证书」，缺一不可：

1. `dnsmasq/dnsmasq.conf` 加 `address=/<域名>/192.168.0.18`
2. `ca/domains.txt` 加域名，然后 `cd ca && ./gen-cert.sh <域名>`
3. `tengine/conf.d/os-repo.conf` 的 `server_name` 列表加上该域名

改完执行：

```bash
docker compose restart dnsmasq
docker compose exec tengine nginx -s reload
```

> ⚠️ 遗漏证书会导致该域名 TLS 握手失败（nginx 找不到 `$ssl_server_name.crt`）；
> 遗漏 server_name 会导致请求落到兜底块返回 444。

## 缓存查看与清理

```bash
docker exec v3-tengine du -sh /var/cache/tproxy/os      # 占用
docker exec v3-tengine sh -c 'rm -rf /var/cache/tproxy/os/*'   # 清空
```

## 关键配置速查

| 项 | 值 | 说明 |
|---|---|---|
| 缓存 TTL（元数据） | 10 分钟 | `repodata/*.xml`、`Packages.gz`、`Release` |
| 缓存 TTL（制品） | 365 天 | `.rpm` `.deb` `.dsc` `.tar.*` `.zst` |
| 上游 DNS（dnsmasq） | `223.5.5.5`、`223.6.6.6` | **禁用 `202.99.192.68`**（运营商劫持） |
| nginx resolver | `223.5.5.5`、`223.6.6.6` | 必须用公共 DNS，见下方排查表 |
| 内网域名 | `nt08.sxsy` → `192.168.0.38` + `192.168.0.48` | 见 `dnsmasq/hosts` |

## 故障排查

| 现象 | 排查方向 |
|---|---|
| 客户端证书报错 | 根 CA 未安装，或域名不在 `ca/domains.txt` |
| 请求 502 | 上游不可达；`docker compose logs tengine` 查看具体错误 |
| 缓存恒为 MISS | `proxy_cache_path` 挂载失败；确认 `${CACHE_BASE}/nginx` 存在且可写 |
| DNS 不生效 | 客户端未指向 `192.168.0.18`；确认 UDP/TCP 53 未被占用 |
| **请求超时/健康检查失败** | **`default_server` 兜底块缺失或 healthcheck 未打 `/healthz`** |
| **回源解析到本机** | **nginx `resolver` 被误改为本机 dnsmasq** —— 会形成代理自环 |

## 两个必须知道的机制

**1. 为什么 nginx 的 `resolver` 不能用本机 dnsmasq**

dnsmasq 已把上游域名劫持到 `192.168.0.18`。若 nginx 用它解析上游域名，
会得到代理自己的地址，回源变成请求自身 —— 死循环。

**2. 为什么必须有 `default_server` 兜底**

未匹配 `server_name` 的请求（如 `Host: 127.0.0.1`）会落到第一个 server 块，
而它的 `proxy_pass $scheme://$host` 会同样代回自身。兜底块用 `return 444`
直接关闭连接，`/healthz` 供健康检查。

## 备份要点

| 对象 | 位置 | 说明 |
|---|---|---|
| **根 CA 私钥** | `ca/tproxy-ca.key` | **不入库**，丢失则所有客户端需重装 CA。必须离线备份 |
| 配置文件 | git 仓库 | 已版本控制 |
| 缓存数据 | `${CACHE_BASE}` | 可重建，无需备份 |
