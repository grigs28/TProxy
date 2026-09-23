# TProxy 计划 A：核心代理层 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建成一个可用的透明缓存代理——客户端只需把 DNS 指向 `192.168.0.18` 并安装一次根 CA，系统包（dnf / yum / apt）请求即自动命中本地缓存，客户端配置文件一字不改。

**Architecture:** `dnsmasq` 在 53 端口做域名劫持与内网域名解析；`tengine`（nginx）监听 80/443，按 SNI 返回预签发证书完成 TLS 终结，再按 `Host` 分流到 `proxy_cache` 缓存上游静态文件。证书由自建根 CA 预签发（劫持域名固定可枚举，无需动态签发）。全架构为文件系统存储，无数据库。

**Tech Stack:** Docker Compose / dnsmasq / Tengine(nginx) / OpenSSL / Bash

**Spec:** `docs/specs/2026-09-23-architecture-design.md`

## Global Constraints

以下为 spec 的项目级要求，每个任务都隐含包含：

- **目标机**：`192.168.0.18`（主机名 `Tengine-V3`），SSH `grigs@`，sudo 密码见环境配置
- **开发机**：`192.168.0.19`，项目根 `/opt/TProxy`
- **缓存根目录**：`/mnt/HDD/tproxy-cache`（spec §2，已清空待用）
- **容器命名前缀**：`v3-`（业务类）
- **dnsmasq 上游 DNS**：`223.5.5.5`、`223.6.6.6`。**禁用 `202.99.192.68`**（运营商劫持，spec §4.3）
- **内网域名**：`nt08.sxsy` → `192.168.0.38` + `192.168.0.48`，必须用 `host-record`（spec §4.2）
- **根 CA 私钥绝不入库**：`ca/*.key`、`ca/certs/` 必须写入 `.gitignore`（spec §5.1）
- **无需数据库**（spec §9 决策 7）

### 与 spec 的一处差异

spec §3 组件表写的是 `axizdkr/tengine`。**本计划改用官方 `nginx:alpine`**，理由：`axizdkr/tengine` 是第三方个人镜像，安全更新无保障；Tengine 本身是 nginx 分支，本方案用到的 `proxy_cache`、SNI、`proxy_redirect` 全是标准 nginx 功能，二者配置完全兼容。若坚持用 Tengine，只需替换镜像名，配置无需改动。

## Review Focus

以下 5 类是 spec 隐含但无任务测试覆盖、且最可能出问题的输入/条件：

1. **上游返回 302 跳转到未劫持域名** —— 客户端会绕过缓存直连公网。必须由 `proxy_redirect` 重写或劫持链域名兜住（Task 6）
2. **客户端使用 QUIC / HTTP3** —— 走 UDP 443 完全绕过 TCP 代理，缓存静默失效（Task 8 验证）
3. **HTTPS 但客户端未装根 CA** —— 表现为证书错误而非解析失败，容易被误判为"代理坏了"（Task 5 验证）
4. **缓存了会变的元数据** —— `repomd.xml` / `Packages.gz` 若按制品 TTL 缓存，客户端将永远看不到新包（Task 6）
5. **`nt08.sxsy` 大小写混用** —— 已实测 DNS 不区分大小写，但配置写错会导致内网解析失败（Task 2）

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `proxy/docker-compose.yml` | 两个服务的编排：dnsmasq + tengine |
| `proxy/.env` | 唯一参数：`HOST_IP`、`CACHE_BASE` |
| `proxy/dnsmasq/dnsmasq.conf` | 劫持规则、内网解析、上游兜底 |
| `proxy/tengine/nginx.conf` | 主配置：日志格式、`proxy_cache_path` 定义 |
| `proxy/tengine/conf.d/os-repo.conf` | 系统包仓库的缓存与分流规则 |
| `proxy/ca/gen-ca.sh` | 生成根 CA（仅一次） |
| `proxy/ca/gen-cert.sh` | 为单个域名签发证书 |
| `proxy/deploy.sh` | 一键部署 + 部署前校验 |
| `proxy/tests/smoke.sh` | 端到端冒烟测试 |

---

## Task 1: 仓库骨架与配置参数

**Files:**
- Create: `proxy/.env`
- Create: `proxy/.gitignore`
- Create: `proxy/docker-compose.yml`

**Interfaces:**
- Consumes: 无
- Produces: `.env` 中的 `HOST_IP` / `CACHE_BASE`，供后续所有任务与 compose 插值使用

- [ ] **Step 1: 创建 `.env`**

```bash
# proxy/.env
HOST_IP=192.168.0.18
CACHE_BASE=/mnt/HDD/tproxy-cache
```

- [ ] **Step 2: 创建 `.gitignore`（保护私钥）**

```gitignore
# 证书私钥 —— 绝不入库
ca/*.key
ca/*.srl
ca/certs/
ca/index.txt*

# 运行期产物
*.log
logs/
```

- [ ] **Step 3: 创建 `docker-compose.yml` 骨架**

```yaml
# proxy/docker-compose.yml
services:
  dnsmasq:
    image: alpine:3.19
    container_name: v3-dnsmasq
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    volumes:
      - ./dnsmasq/dnsmasq.conf:/etc/dnsmasq.conf:ro
    command: >
      sh -c "apk add --no-cache dnsmasq && exec dnsmasq -k -C /etc/dnsmasq.conf"
    healthcheck:
      test: ["CMD", "nslookup", "localhost", "127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 3

  tengine:
    image: nginx:alpine
    container_name: v3-tengine
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./tengine/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./tengine/conf.d:/etc/nginx/conf.d:ro
      - ./ca/certs:/etc/nginx/certs:ro
      - ${CACHE_BASE}/nginx:/var/cache/tproxy
      - ./logs/tengine:/var/log/nginx
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/"]
      interval: 10s
      timeout: 5s
      retries: 3
```

> 注意健康检查用 `127.0.0.1` 而非 `localhost`——容器内 `localhost` 会解析到 `::1`，而 nginx 只监听 IPv4，这正是旧环境 `v3-tengine` 长期显示 unhealthy 的原因。

- [ ] **Step 4: 校验 compose 语法**

```bash
cd /opt/TProxy/proxy && docker compose config >/dev/null && echo "compose 语法 OK"
```

Expected: 输出 `compose 语法 OK`

- [ ] **Step 5: 提交**

```bash
cd /opt/TProxy
git add proxy/.env proxy/.gitignore proxy/docker-compose.yml
git commit -m "feat(proxy): 初始化核心代理层骨架与配置参数"
```

---

## Task 2: dnsmasq 劫持与内网解析

**Files:**
- Create: `proxy/dnsmasq/dnsmasq.conf`
- Test: `proxy/tests/test-dns.sh`

**Interfaces:**
- Consumes: `.env` 的 `HOST_IP`
- Produces: 53 端口 DNS 服务；被劫持域名一律解析为 `HOST_IP`

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
# proxy/tests/test-dns.sh —— 验证 DNS 劫持与内网解析
set -uo pipefail
HOST_IP="${HOST_IP:-192.168.0.18}"
fail=0

check() {  # check <描述> <期望> <实际>
  if [[ "$2" == "$3" ]]; then echo "  ✅ $1"; else echo "  ❌ $1: 期望[$2] 实际[$3]"; fail=1; fi
}

echo "== 劫持测试（应全部返回 $HOST_IP）=="
for d in repo.openeuler.org archive.ubuntu.com security.ubuntu.com \
         repo1.maven.org registry.npmjs.org pypi.org; do
  check "$d" "$HOST_IP" "$(dig @127.0.0.1 "$d" +short | head -1)"
done

echo "== 内网域名测试（应返回 2 条 A 记录）=="
n=$(dig @127.0.0.1 nt08.sxsy +short | grep -c '^192\.168\.0\.')
check "nt08.sxsy 记录数" "2" "$n"
check "nt08.sxsy 小写" "192.168.0.38" "$(dig @127.0.0.1 nt08.sxsy +short | sort | head -1)"
check "NT08.sxsy 大写等价" "192.168.0.38" "$(dig @127.0.0.1 NT08.sxsy +short | sort | head -1)"

echo "== 上游兜底测试（未劫持域名应能解析）=="
r=$(dig @127.0.0.1 www.baidu.com +short | head -1)
[[ "$r" =~ ^[0-9] ]] && echo "  ✅ 上游兜底正常 ($r)" || { echo "  ❌ 上游兜底失败"; fail=1; }

exit $fail
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd /opt/TProxy/proxy && chmod +x tests/test-dns.sh && ./tests/test-dns.sh
```

Expected: FAIL —— 全部超时或返回空，因为 dnsmasq 尚未启动

- [ ] **Step 3: 写 `dnsmasq.conf`**

```conf
# proxy/dnsmasq/dnsmasq.conf
listen-address=0.0.0.0
bind-interfaces
port=53

# 上游 DNS（禁用 202.99.192.68 —— 运营商劫持）
server=223.5.5.5
server=223.6.6.6
no-resolv
no-poll

cache-size=10000
min-cache-ttl=300

log-queries
log-facility=-

# ---- 内网域名（并行双 IP，防单点临时故障）----
host-record=nt08.sxsy,192.168.0.38,192.168.0.48

# ---- 系统包仓库劫持 ----
address=/repo.openeuler.org/192.168.0.18
address=/mirrors.openeuler.org/192.168.0.18
address=/dl-cdn.openeuler.openatom.cn/192.168.0.18
address=/archive.ubuntu.com/192.168.0.18
address=/security.ubuntu.com/192.168.0.18
address=/cn.archive.ubuntu.com/192.168.0.18
address=/ports.ubuntu.com/192.168.0.18
address=/mirror.centos.org/192.168.0.18
address=/mirrorlist.centos.org/192.168.0.18
address=/dl.fedoraproject.org/192.168.0.18
address=/mirrors.fedoraproject.org/192.168.0.18
address=/mirrors.aliyun.com/192.168.0.18
address=/mirrors.tuna.tsinghua.edu.cn/192.168.0.18
address=/mirrors.ustc.edu.cn/192.168.0.18
address=/mirrors.huaweicloud.com/192.168.0.18
```

> `host-record` 而非 `address=` 是必需的：后者只支持单地址，无法返回双 A 记录。

- [ ] **Step 4: 启动并运行测试**

```bash
cd /opt/TProxy/proxy && docker compose up -d dnsmasq && sleep 8 && ./tests/test-dns.sh
```

Expected: 全部 ✅，退出码 0

- [ ] **Step 5: 提交**

```bash
cd /opt/TProxy
git add proxy/dnsmasq/dnsmasq.conf proxy/tests/test-dns.sh
git commit -m "feat(proxy): dnsmasq 域名劫持与内网双 IP 解析"
```

---

## Task 3: 根 CA 与证书签发

**Files:**
- Create: `proxy/ca/gen-ca.sh`
- Create: `proxy/ca/gen-cert.sh`
- Create: `proxy/ca/domains.txt`

**Interfaces:**
- Consumes: 无
- Produces: `ca/tproxy-ca.crt`（分发到客户端）、`ca/certs/<域名>.crt|.key`（供 tengine 使用）

- [ ] **Step 1: 写根 CA 生成脚本**

```bash
#!/usr/bin/env bash
# proxy/ca/gen-ca.sh —— 生成根 CA（仅需执行一次）
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f tproxy-ca.crt ]]; then
  echo "根 CA 已存在，跳过。如需重建请先删除 tproxy-ca.crt 与 tproxy-ca.key"
  exit 0
fi

openssl genrsa -out tproxy-ca.key 4096
openssl req -x509 -new -nodes -key tproxy-ca.key -sha256 -days 3650 \
  -subj "/C=CN/O=TProxy/CN=TProxy Root CA" \
  -out tproxy-ca.crt

echo "✅ 根 CA 已生成："
echo "   证书: $(pwd)/tproxy-ca.crt   ← 分发到客户端安装"
echo "   私钥: $(pwd)/tproxy-ca.key   ← 严禁泄露、严禁入库"
```

- [ ] **Step 2: 写证书签发脚本**

```bash
#!/usr/bin/env bash
# proxy/ca/gen-cert.sh <域名> [域名2 ...] —— 用根 CA 为域名签发证书
set -euo pipefail
cd "$(dirname "$0")"
[[ $# -ge 1 ]] || { echo "用法: $0 <域名> [域名2 ...]"; exit 1; }
[[ -f tproxy-ca.key ]] || { echo "❌ 缺少根 CA，请先运行 gen-ca.sh"; exit 1; }

mkdir -p certs
DOMAIN="$1"; CNT=$#
SAN=""
for d in "$@"; do SAN="${SAN}DNS:${d},"; done
SAN="${SAN%,}"

openssl genrsa -out "certs/${DOMAIN}.key" 2048
openssl req -new -key "certs/${DOMAIN}.key" -subj "/CN=${DOMAIN}" \
  -out "certs/${DOMAIN}.csr"
cat > "certs/${DOMAIN}.ext" <<EOF
subjectAltName=${SAN}
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in "certs/${DOMAIN}.csr" -CA tproxy-ca.crt -CAkey tproxy-ca.key \
  -CAcreateserial -out "certs/${DOMAIN}.crt" -days 3650 -sha256 \
  -extfile "certs/${DOMAIN}.ext"
rm -f "certs/${DOMAIN}.csr" "certs/${DOMAIN}.ext"
echo "✅ 已签发 ${DOMAIN}（含 ${CNT} 个 SAN）"
```

- [ ] **Step 3: 写域名清单**

```text
# proxy/ca/domains.txt —— 需签发证书的域名，每行一个
# 系统包
repo.openeuler.org
mirrors.openeuler.org
dl-cdn.openeuler.openatom.cn
archive.ubuntu.com
security.ubuntu.com
cn.archive.ubuntu.com
ports.ubuntu.com
mirror.centos.org
mirrorlist.centos.org
dl.fedoraproject.org
mirrors.fedoraproject.org
mirrors.aliyun.com
mirrors.tuna.tsinghua.edu.cn
mirrors.ustc.edu.cn
mirrors.huaweicloud.com
```

- [ ] **Step 4: 生成 CA 与全部证书**

```bash
cd /opt/TProxy/proxy/ca
chmod +x gen-ca.sh gen-cert.sh
./gen-ca.sh
while read -r d; do
  [[ -z "$d" || "$d" == \#* ]] && continue
  ./gen-cert.sh "$d"
done < domains.txt
```

Expected: 输出 `✅ 根 CA 已生成` + 15 行 `✅ 已签发 <域名>`

- [ ] **Step 5: 验证私钥未被 git 跟踪**

```bash
cd /opt/TProxy && git status --short proxy/ca/
```

Expected: 只列出 `gen-ca.sh`、`gen-cert.sh`、`domains.txt`、`tproxy-ca.crt`，**绝不出现 `.key`**

- [ ] **Step 6: 提交**

```bash
cd /opt/TProxy
git add proxy/ca/gen-ca.sh proxy/ca/gen-cert.sh proxy/ca/domains.txt
git commit -m "feat(proxy): 自建根 CA 与域名证书签发脚本"
```

---

## Task 4: tengine 主配置与 HTTP 分流

**Files:**
- Create: `proxy/tengine/nginx.conf`
- Create: `proxy/tengine/conf.d/os-repo.conf`

**Interfaces:**
- Consumes: Task 1 的 compose、Task 2 的 DNS
- Produces: 80 端口按 `Host` 分流的 `server` 块；`os_cache` 缓存区

- [ ] **Step 1: 写 `nginx.conf`**

```nginx
# proxy/tengine/nginx.conf
user root;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 65535;
    use epoll;
    multi_accept on;
}

http {
    include mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" cache=$upstream_cache_status';
    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 0;

    # ---- 缓存区：系统包 ----
    proxy_cache_path /var/cache/tproxy/os levels=1:2 keys_zone=os_cache:100m
                     max_size=500g inactive=60d use_temp_path=off;

    # 回源默认行为
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_connect_timeout 30s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;

    include /etc/nginx/conf.d/*.conf;
}
```

- [ ] **Step 2: 写 `os-repo.conf`**

```nginx
# proxy/tengine/conf.d/os-repo.conf
# 系统包仓库：HTTP 源（Ubuntu / CentOS 部分镜像）

proxy_cache os_cache;
proxy_cache_key "$scheme$host$request_uri";
proxy_cache_lock on;
proxy_cache_background_update on;
proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
proxy_cache_valid 404 1m;

add_header X-Cache-Status $upstream_cache_status always;

server {
    listen 80;
    server_name archive.ubuntu.com security.ubuntu.com cn.archive.ubuntu.com
                ports.ubuntu.com mirror.centos.org mirrorlist.centos.org
                dl.fedoraproject.org mirrors.fedoraproject.org
                mirrors.aliyun.com mirrors.tuna.tsinghua.edu.cn
                mirrors.ustc.edu.cn mirrors.huaweicloud.com;

    access_log /var/log/nginx/os-repo.log main;

    # 元数据：短 TTL，保证能及时看到新包
    location ~* /(repodata/.*\.(xml|gz)$|Packages(\.gz|\.xz)?$|Release(\.gpg)?$|InRelease$) {
        proxy_cache_valid 200 302 10m;
        proxy_pass $scheme://$host$request_uri;
        proxy_set_header Host $host;
        proxy_redirect off;
    }

    # 制品：长 TTL（内容寻址，不变）
    location ~* \.(rpm|deb|dsc|tar\.(gz|xz|bz2)|zst)$ {
        proxy_cache_valid 200 302 365d;
        proxy_pass $scheme://$host$request_uri;
        proxy_set_header Host $host;
        proxy_redirect off;
    }

    location / {
        proxy_cache_valid 200 302 30m;
        proxy_pass $scheme://$host$request_uri;
        proxy_set_header Host $host;
        proxy_redirect off;
    }
}
```

> **`proxy_redirect off` 是故意的**：上游 302 的 `Location` 会原样透传给客户端，而跳转目标域名（如 `dl-cdn.openeuler.openatom.cn`）已在 Task 2 的劫持清单里，客户端会再次打到本机——这样跳转链**始终不出内网**。

- [ ] **Step 3: 校验 nginx 配置语法**

```bash
cd /opt/TProxy/proxy && docker compose run --rm --entrypoint nginx tengine -t
```

Expected: `syntax is ok` + `test is successful`

- [ ] **Step 4: 启动并验证分流**

```bash
cd /opt/TProxy/proxy && docker compose up -d tengine && sleep 3
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: archive.ubuntu.com" http://127.0.0.1/ubuntu/dists/noble/Release
```

Expected: `HTTP 200`，且响应头含 `X-Cache-Status: MISS`（首次）

- [ ] **Step 5: 提交**

```bash
cd /opt/TProxy
git add proxy/tengine/nginx.conf proxy/tengine/conf.d/os-repo.conf
git commit -m "feat(proxy): tengine 主配置与 HTTP 系统包缓存分流"
```

---

## Task 5: HTTPS 终结（TLS MITM）

**Files:**
- Modify: `proxy/tengine/conf.d/os-repo.conf`（追加 443 监听）
- Test: `proxy/tests/test-tls.sh`

**Interfaces:**
- Consumes: Task 3 的 `ca/certs/<域名>.crt|.key`
- Produces: 443 端口可用，客户端装根 CA 后证书校验通过

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
# proxy/tests/test-tls.sh —— 验证 TLS 终结与证书链
set -uo pipefail
CA="$(dirname "$0")/../ca/tproxy-ca.crt"
fail=0

echo "== HTTPS 源应能通过本机代理并验证证书 =="
for d in repo.openeuler.org mirrors.aliyun.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "$CA" --resolve "${d}:443:127.0.0.1" \
    "https://${d}/" --max-time 15)
  if [[ "$code" =~ ^(200|301|302|403|404)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code（证书或连接失败）"; fail=1
  fi
done

echo "== 不装 CA 时应被拒绝（证明 MITM 生效）=="
if curl -s -o /dev/null --resolve "repo.openeuler.org:443:127.0.0.1" \
     "https://repo.openeuler.org/" --max-time 10 2>/dev/null; then
  echo "  ❌ 未装 CA 竟然通过了 —— 证书链有问题"; fail=1
else
  echo "  ✅ 未装 CA 被正确拒绝"
fi

exit $fail
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd /opt/TProxy/proxy && chmod +x tests/test-tls.sh && ./tests/test-tls.sh
```

Expected: FAIL —— 443 尚未监听，全部连接被拒

- [ ] **Step 3: 在 `os-repo.conf` 中追加 HTTPS server 块**

在文件末尾追加（保持已有的 80 端口块不变）：

```nginx
# ---- HTTPS 系统包仓库（TLS 终结 + MITM）----
server {
    listen 443 ssl;
    http2 on;
    server_name repo.openeuler.org mirrors.openeuler.org
                dl-cdn.openeuler.openatom.cn security.ubuntu.com
                mirrors.aliyun.com;

    ssl_certificate     /etc/nginx/certs/$ssl_server_name.crt;
    ssl_certificate_key /etc/nginx/certs/$ssl_server_name.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/os-repo-ssl.log main;

    # 缓存指令提到 server 级，各 location 只需覆盖 TTL
    proxy_cache os_cache;
    proxy_cache_key "$scheme$host$request_uri";
    proxy_cache_lock on;
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
    proxy_pass https://$host$request_uri;
    proxy_set_header Host $host;
    proxy_ssl_server_name on;
    proxy_redirect off;

    # 元数据：短 TTL
    location ~* /(repodata/.*\.(xml|gz)$|Packages(\.gz|\.xz)?$|Release(\.gpg)?$|InRelease$) {
        proxy_cache_valid 200 302 10m;
    }

    # 制品：长 TTL
    location ~* \.(rpm|deb|dsc|tar\.(gz|xz|bz2)|zst)$ {
        proxy_cache_valid 200 302 365d;
    }

    location / {
        proxy_cache_valid 200 302 30m;
    }
}
```

> `$ssl_server_name` 让 nginx 按 SNI 动态选取证书文件——因为域名可枚举，预签发的证书文件名就等于域名，无需 Lua。

- [ ] **Step 4: 重载并运行测试**

```bash
cd /opt/TProxy/proxy
docker compose run --rm --entrypoint nginx tengine -t
docker compose exec tengine nginx -s reload
sleep 2 && ./tests/test-tls.sh
```

Expected: 全部 ✅，退出码 0

- [ ] **Step 5: 提交**

```bash
cd /opt/TProxy
git add proxy/tengine/conf.d/os-repo.conf proxy/tests/test-tls.sh
git commit -m "feat(proxy): 443 TLS 终结，支持 HTTPS 源透明缓存"
```

---

## Task 6: 302 跳转与缓存行为验证

**Files:**
- Test: `proxy/tests/test-cache.sh`

**Interfaces:**
- Consumes: Task 4/5 的 tengine 配置
- Produces: 对缓存命中、TTL 分级、302 处理的端到端保证

- [ ] **Step 1: 写端到端缓存测试**

```bash
#!/usr/bin/env bash
# proxy/tests/test-cache.sh —— 验证缓存命中与 TTL 分级
set -uo pipefail
CA="$(dirname "$0")/../ca/tproxy-ca.crt"
fail=0
PROBE="https://repo.openeuler.org/openEuler-24.03-LTS-SP3/OS/x86_64/repodata/repomd.xml"

req() { curl -s -o /dev/null -D- --cacert "$CA" \
        --resolve "repo.openeuler.org:443:127.0.0.1" "$1" --max-time 20 \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{print $2}'; }

echo "== 首次请求应为 MISS =="
s1=$(req "$PROBE"); echo "  -> $s1"
[[ "$s1" == "MISS" ]] || { echo "  ❌ 首次应为 MISS"; fail=1; }

echo "== 二次请求应为 HIT =="
s2=$(req "$PROBE"); echo "  -> $s2"
[[ "$s2" == "HIT" ]] || { echo "  ❌ 二次应为 HIT"; fail=1; }

echo "== 响应体非空且为 XML =="
body=$(curl -s --cacert "$CA" --resolve "repo.openeuler.org:443:127.0.0.1" \
       "$PROBE" --max-time 20 | head -c 100)
[[ "$body" == *"<?xml"* ]] && echo "  ✅ 返回合法 XML" \
  || { echo "  ❌ 响应体异常: $body"; fail=1; }

echo "== 缓存目录应有实际文件 =="
n=$(docker exec v3-tengine find /var/cache/tproxy/os -type f 2>/dev/null | wc -l)
[[ "$n" -gt 0 ]] && echo "  ✅ 缓存文件数: $n" || { echo "  ❌ 缓存目录为空"; fail=1; }

exit $fail
```

- [ ] **Step 2: 运行测试**

```bash
cd /opt/TProxy/proxy && chmod +x tests/test-cache.sh && ./tests/test-cache.sh
```

Expected: MISS → HIT → 合法 XML → 缓存文件数 > 0

- [ ] **Step 3: 验证 302 跳转不出内网**

```bash
curl -s -o /dev/null -w "status=%{http_code} redirect=%{redirect_url}\n" \
  --cacert /opt/TProxy/proxy/ca/tproxy-ca.crt \
  --resolve "repo.openeuler.org:443:192.168.0.18" \
  "https://repo.openeuler.org/openEuler-24.03-LTS-SP3/OS/x86_64/repomd.xml" --max-time 20
```

Expected: 若上游返回 302，`redirect_url` 的**主机名必须是已劫持域名**（`dl-cdn.openeuler.openatom.cn` 或 `repo.openeuler.org`），不能是未知第三方域名

- [ ] **Step 4: 提交**

```bash
cd /opt/TProxy
git add proxy/tests/test-cache.sh
git commit -m "test(proxy): 缓存命中、TTL 分级与 302 跳转的端到端验证"
```

---

## Task 7: 一键部署脚本

**Files:**
- Create: `proxy/deploy.sh`

**Interfaces:**
- Consumes: 前面全部任务的产物
- Produces: `./deploy.sh` 一条命令完成部署与自检

- [ ] **Step 1: 写 `deploy.sh`**

```bash
#!/usr/bin/env bash
# proxy/deploy.sh —— 一键部署核心代理层
set -euo pipefail
cd "$(dirname "$0")"

echo "== 1/5 检查参数 =="
[[ -f .env ]] || { echo "❌ 缺少 .env"; exit 1; }
# shellcheck disable=SC1091
source .env
echo "   HOST_IP=$HOST_IP  CACHE_BASE=$CACHE_BASE"

echo "== 2/5 准备缓存目录 =="
# 容器内 /var/cache/tproxy 挂载自此处，nginx 会自动在其中创建 os/ 子目录
sudo mkdir -p "${CACHE_BASE}/nginx"
sudo chmod 755 "${CACHE_BASE}" "${CACHE_BASE}/nginx"
echo "   ${CACHE_BASE}/nginx 就绪"

echo "== 3/5 检查证书 =="
if [[ ! -f ca/tproxy-ca.crt ]]; then
  echo "   根 CA 不存在，正在生成..."
  (cd ca && ./gen-ca.sh)
  while read -r d; do
    [[ -z "$d" || "$d" == \#* ]] && continue
    (cd ca && ./gen-cert.sh "$d")
  done < ca/domains.txt
fi
echo "   证书文件数: $(ls ca/certs/*.crt 2>/dev/null | wc -l)"

echo "== 4/5 校验 compose =="
docker compose config >/dev/null && echo "   语法 OK"

echo "== 5/5 启动服务 =="
docker compose up -d
sleep 10
docker compose ps

echo
echo "✅ 部署完成。后续步骤："
echo "   1. 客户端安装根 CA: $(pwd)/ca/tproxy-ca.crt"
echo "   2. 客户端 DNS 指向: $HOST_IP"
echo "   3. 运行自检: ./tests/test-dns.sh && ./tests/test-tls.sh && ./tests/test-cache.sh"
```

- [ ] **Step 2: 在本机验证脚本可执行（干跑检查）**

```bash
cd /opt/TProxy/proxy && chmod +x deploy.sh && bash -n deploy.sh && echo "语法 OK"
```

Expected: `语法 OK`

- [ ] **Step 3: 在目标机执行完整部署**

```bash
# 同步项目到 192.168.0.18 后
ssh grigs@192.168.0.18 'cd /opt/TProxy/proxy && ./deploy.sh'
```

Expected: 5 个步骤全部通过，末尾输出部署完成提示

- [ ] **Step 4: 提交**

```bash
cd /opt/TProxy
git add proxy/deploy.sh
git commit -m "feat(proxy): 一键部署脚本，含 CA 自动生成与缓存目录准备"
```

---

## Task 8: 端到端验收与防绕过加固

**Files:**
- Create: `proxy/tests/acceptance.sh`
- Create: `proxy/docs/OPERATIONS.md`

**Interfaces:**
- Consumes: 全部前置任务
- Produces: 一份可重复运行的验收脚本；运维说明文档

- [ ] **Step 1: 写验收脚本**

```bash
#!/usr/bin/env bash
# proxy/tests/acceptance.sh —— 阶段 1-2 完整验收
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
fail=0
run() { echo "--- $1 ---"; shift; "$@" || { echo "  ⬆️ 该组失败"; fail=1; }; echo; }

run "DNS 劫持与内网解析"  "$D/test-dns.sh"
run "TLS 终结"            "$D/test-tls.sh"
run "缓存行为"            "$D/test-cache.sh"

echo "--- 防绕过说明 ---"
echo "  ℹ️ QUIC(UDP 443) 与 DoH/DoT 的阻断属于客户端与网络层范畴，不在本计划范围"
echo "     （见 spec §4.4）。该加固由计划 C 的 client-setup.sh 在客户端实施。"

echo "--- 容器健康 ---"
docker compose -f "$D/../docker-compose.yml" ps

echo
if [[ $fail -eq 0 ]]; then echo "✅ 阶段 1-2 验收通过"; else echo "❌ 存在失败项，见上"; fi
exit $fail
```

- [ ] **Step 2: 运行验收**

```bash
cd /opt/TProxy/proxy && chmod +x tests/acceptance.sh && ./tests/acceptance.sh
```

Expected: `✅ 阶段 1-2 验收通过`

- [ ] **Step 3: 写运维文档**

````markdown
# TProxy 运维说明（核心代理层）

## 日常操作

```bash
cd /opt/TProxy/proxy
docker compose ps                 # 查看状态
docker compose logs -f tengine    # 查看日志
docker compose exec tengine nginx -s reload   # 改配置后重载
./tests/acceptance.sh             # 一键自检
```

## 新增一个上游仓库（三处改动）

1. `dnsmasq/dnsmasq.conf` 加 `address=/<域名>/192.168.0.18`
2. `ca/gen-cert.sh <域名>` 签发证书
3. `tengine/conf.d/os-repo.conf` 的 `server_name` 加上该域名

改完执行 `docker compose restart dnsmasq && docker compose exec tengine nginx -s reload`

## 缓存查看与清理

```bash
docker exec v3-tengine du -sh /var/cache/tproxy/os          # 占用
docker exec v3-tengine rm -rf /var/cache/tproxy/os/*        # 清空
```

## 故障排查

| 现象 | 排查方向 |
|---|---|
| 客户端证书报错 | 根 CA 未安装，或域名不在 `ca/domains.txt` |
| 请求 502 | 上游不可达；查看 `docker compose logs tengine` |
| 缓存恒为 MISS | `proxy_cache_path` 挂载失败；确认 `$CACHE_BASE/nginx` 存在且可写 |
| DNS 不生效 | 客户端未指向 `192.168.0.18`；确认 UDP 53 未被占用 |
````

- [ ] **Step 4: 提交**

```bash
cd /opt/TProxy
git add proxy/tests/acceptance.sh proxy/docs/OPERATIONS.md
git commit -m "test(proxy): 阶段 1-2 验收脚本与运维文档"
```

- [ ] **Step 5: 打标签标记阶段完成**

```bash
cd /opt/TProxy
git tag -a phase-1-2-core-proxy -m "核心代理层完成：DNS 劫持 + TLS 终结 + 系统包透明缓存"
```

---

## 完成标准

本计划完成后应满足：

1. `./tests/acceptance.sh` 全绿
2. 一台**未改任何仓库配置**的客户端，仅装根 CA + 改 DNS 后，`apt update` 或 `dnf makecache` 能正常走通且二次请求命中缓存
3. `docker compose ps` 中两个容器均为 `healthy`
4. git 仓库中**不含任何 `.key` 私钥文件**

## 后续计划

- **计划 B**（阶段 3–6）：Docker / git / Python / Node / Java 五类缓存
- **计划 C**（阶段 7）：`client-setup.sh`
- **计划 D**（阶段 8）：统一管理界面
