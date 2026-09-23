# TProxy 客户端接入

一条命令把 Linux 机器接入 TProxy 透明缓存。接入后**无需修改任何仓库/镜像/工具配置**，
六类制品（系统包 / Docker / git / Python / Node.js / Java）自动命中本地缓存。

## 两个版本

| 版本 | 位置 | 用途 |
|---|---|---|
| **多文件版** | `client-setup.sh` + `lib/` | 本地直接运行，结构清晰、便于调试 |
| **自包含版** | `dist/tp.client.sh` | 供**脚本分发平台**下发到集群节点 |

两者功能等价。区别在于分发平台的硬性要求：

> **脚本必须自包含**，只能依赖 `bas.sh` 和系统自带工具，不能假设同目录存在其他文件。

所以 `dist/tp.client.sh` 把三个 `lib/` 模块合并进了单文件，并改用分发平台的
`print_*` 输出函数（支持中英翻译）。

### 修改流程

**先改本地，再复制到发布平台**：

```bash
# 1. 改本地这一份
vim client/dist/tp.client.sh

# 2. 复制到发布平台（本机是 NAS 的 SMB 挂载，写入即同步）
cp client/dist/tp.client.sh /mnt/79-sxiad/grigs/tp/tp.client.sh

# 3. 验证平台可访问
curl -sI http://192.168.0.79/sxiad/grigs/tp/tp.client.sh | head -1
```

**不要在发布平台上直接改** —— 那里没有版本控制，改动不可回滚，且下次从本地
复制会覆盖掉。

## 用法

```bash
# 标准接入（从服务端下载根 CA）
sudo ./client-setup.sh

# 服务端不可达时，手动拷入 CA
sudo ./client-setup.sh --ca /path/to/tproxy-ca.crt

# 指定其他服务端
sudo ./client-setup.sh --server 192.168.0.18

# 回滚
sudo ./client-setup.sh --rollback
```

## 它做了什么

| 步骤 | 内容 |
|---|---|
| 1 | 配置 DNS：`192.168.0.18` → `223.5.5.5` → `119.29.29.29`（串行，带公网兜底） |
| 2 | 下载根 CA |
| 3 | 装入系统信任库 + Docker + Java + 运行时（conda 等）|
| 4 | 自检 |

## 注意事项

**Ubuntu 会关闭 systemd-resolved** —— 它**并行**查询多个 DNS 取最快返回，
公网结果会抢在 `.18` 之前，使劫持彻底失效。若需保留它，请改用仅指向 `.18` 的单 DNS
配置（代价是失去公网兜底）。

**需要重启的服务**：
```bash
systemctl restart docker     # Docker 证书目录生效
```

**Firefox 需手动导入**根 CA —— 它不读系统信任库。

## 未自动实施的可选加固

以下策略影响整机网络行为，脚本**不会**自动执行，由你按需决定：

```bash
# 阻断 QUIC（UDP 443）—— 否则客户端可能走 HTTP/3 绕过 TCP 代理
iptables -A OUTPUT -p udp --dport 443 -j REJECT

# 阻断 DoT（853）—— 否则加密 DNS 会绕过 dnsmasq 劫持
iptables -A OUTPUT -p tcp --dport 853 -j REJECT
iptables -A OUTPUT -p udp --dport 853 -j REJECT
```

> 不加这两条，缓存仍可用，但存在被绕过的可能（客户端走 QUIC/DoH 时不命中缓存）。
> 注意客户端此时已解析到 `.18`，QUIC 到 `.18` 的 UDP 443 无监听、多数栈会回退 TCP；
> 真正的绕过路径是 **DoH + 直连真实 IP**，故 DoT/DoH 的阻断比 QUIC 更关键。

## 回滚

`sudo ./client-setup.sh --rollback` 会：
- 从备份恢复 `/etc/resolv.conf`（备份在 `/var/backups/tproxy-client/`）
- 从系统信任库移除根 CA
- 移除 Docker 证书目录中的 CA

**需手动处理**：Java cacerts 的删除、以及若原先启用了 systemd-resolved 则需重新启用。

## 故障排查（实机踩过的坑）

| 现象 | 原因与处理 |
|---|---|
| `curl: (52) Empty reply from server` 下载 CA 时 | 服务端的 `default_server` 未提供 `/tproxy-ca.crt` 端点（客户端访问 IP 会落入兜底返回 444） |
| 某域名不命中缓存、其他域名正常 | **宿主 `/etc/hosts` 里有该域名的记录** —— dnsmasq 读 hosts 且其优先级高于 `address=`，需删除 |
| 服务端自测全绿但客户端 `No route to host` | **防火墙未放行 443/tcp**（`firewall-cmd --list-ports` 常开了 80 却漏 443） |
| `curl` 报 `unknown CA`，但 `/usr/bin/curl` 正常 | 该 curl 来自 conda 等自带 CA bundle 的运行时，不读系统信任库 —— 已由 `install_runtime_ca()` 处理，需重启该运行时 |
| 接入后仍能上公网但缓存不生效 | DNS 未生效：确认客户端 DNS 指向 `.18`，且未被 systemd-resolved 接管 |

> 服务端侧可先运行 `proxy/tests/preflight.sh` 做配置体检（监听/防火墙/hosts 冲突/
> 劫持生效/容器健康/证书覆盖）。
