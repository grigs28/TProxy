# 新增一个上游仓库

透明缓存要求「域名被劫持 + 有对应证书 + tengine 有分流规则」三者齐备，缺一不可。

> 管理界面是**只读**的（刻意如此，避免与手工编辑互相覆盖），
> 所以新增上游走本文档的流程。

## 三类改动

以新增 `example.com` 为例：

### 1. DNS 劫持

`dnsmasq/dnsmasq.conf` 追加：

```conf
address=/example.com/192.168.0.18
```

### 2. 签发证书

```bash
cd ca
echo "example.com" >> domains.txt
./gen-cert.sh example.com
```

### 3. tengine 分流

`tengine/conf.d/<类型>.conf` 的 `server_name` 列表加上 `example.com`。

若是全新类型，需另建 conf 文件并定义 `proxy_cache_path`（见 `nginx.conf` 中的现有例子）。

## 使改动生效

```bash
cd /opt/TProxy/proxy
docker compose restart dnsmasq tengine
```

> ⚠️ **必须用 `restart` 而非仅 `nginx -s reload`**：
> dnsmasq.conf 与 conf.d 都是 `:ro` 文件挂载，内容变更不会让 docker 重新挂载。
> 更根本的是 **bind mount 绑定的是挂载时刻的 inode** —— 用 `rsync`（非 `--inplace`）
> 同步会让容器继续读到旧文件，表现为「配置改了、也 reload 了，却没有生效」。
> 本项目的 `sync-to-target.sh` 已强制 `--inplace`。

## 验证

```bash
./tests/preflight.sh          # 配置体检：劫持是否生效、证书是否存在
./tests/test-<类型>.sh        # 该类缓存的专项测试
```

## ⚠️ 不要用 deploy.sh 做增量

`deploy.sh` 的证书生成被 `if [[ ! -f ca/tproxy-ca.crt ]]` 守卫 ——
**CA 已存在时它不会签新证书**。往 `domains.txt` 加域名后跑 `deploy.sh`
不会生效，容易误判为「加了域名没用」。

新增上游请按本文档的三步手工流程，或先手动跑 `ca/gen-cert.sh`。

## 各类型的特殊点

| 类型 | 注意 |
|---|---|
| Docker | 上游走 `map $host $docker_upstream` 选择；新增上游还需在 compose 中加 registry 实例 |
| git | 转发给 gitcache 时**必须补 `$host` 前缀**（`/域名/owner/repo`），否则 gitcache panic |
| Node.js | 需 `proxy_hide_header Set-Cookie` + `proxy_ignore_headers Set-Cookie`，否则被 CF 的 bot cookie 挡住缓存 |
| Java | 元数据/SNAPSHOT 的 location **必须排在 release 制品之前**（nginx 正则按出现顺序匹配） |
| 系统包 | 注意元数据与制品的 TTL 分级；元数据正则需覆盖 `.zst` 等压缩索引 |
