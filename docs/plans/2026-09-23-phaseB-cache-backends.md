# TProxy 计划 B：五类缓存后端 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在计划 A 的透明代理骨架上，加上 Docker / git / Python / Node.js / Java 五类制品的缓存，让客户端对这五类源同样「改 DNS 即命中缓存」。

**Architecture:** 复用计划 A 建立的「dnsmasq 劫持 → tengine 443 TLS 终结 → 按 Host 分流」骨架。Docker 走 `registry:2` proxy 模式（原样透传 `/v2/` 路径）；git 走 `gitcache`；Python / Node / Java 复用 `proxy_cache`。每类新增三处：劫持域名、CA 证书、tengine server 块。

**Tech Stack:** Docker Compose / dnsmasq / nginx / registry:2 / gitcache（Go 自建）

**Spec:** `docs/specs/2026-09-23-architecture-design.md`

## Global Constraints

- **前置**：计划 A 已完成并验收通过（`phase-1-2-core-proxy` 标签）
- **目标机**：`192.168.0.18`，SSH `grigs@`，sudo 密码见环境配置
- **开发机**：`192.168.0.19`，项目根 `/opt/TProxy`
- **测试必须在目标机执行**（`.19` 写 → rsync 到 `.18` → `.18` 上跑）
- **缓存根目录**：`/mnt/HDD/tproxy-cache`，子目录按类型分
- **容器命名**：`v3-` 前缀
- **新增上游 = 三处改动**：`dnsmasq.conf` 劫持 + `ca/gen-cert.sh` 签证书 + `conf.d/` 的 `server_name`
- **私钥绝不入库**（`ca/*.key`、`ca/certs/`）
- **`proxy_pass` 只能出现在 `location` 内**
- **nginx `resolver` 必须是公共 DNS**（`223.5.5.5`），不能用本机 dnsmasq——否则回源解析到代理自身形成死循环
- **测试脚本不得清空生产缓存**（计划 A 的教训）

### 上游可达性前提（已实测 2026-09-23）

`.18` 出网经 `.17` 网关，国外源已可达：

| 源 | 实测 |
|---|---|
| `registry-1.docker.io/v2/` | **401**（v2 API 正常响应，需认证） |
| `repo1.maven.org` | 200 (1.8s) |
| `pypi.org` | 200 (5.2s) |
| `github.com` | 200 (12.0s) |

> ⚠️ 计划 A 时 `registry-1.docker.io` 不可达（`i/o timeout`），是 `registry:2` 反复 panic 的根因。
> 现经 `.17` 网关出网 + DNS 修正，该前提已消除。

## Review Focus

五类计划测试不覆盖、最可能出问题的输入/条件：

1. **`registry:2` proxy 遇到上游 401/403** —— Docker Hub 要求 token 认证，若代理不透传认证流程，客户端会拿到 401 而非镜像
2. **maven 的 `maven-metadata.xml` 与 SNAPSHOT 被缓存** —— 缓存后客户端永远拿不到新版本，构建静默使用旧依赖
3. **npm 的元数据响应带 `Content-Encoding: gzip`** —— 若 nginx 对压缩响应按内容缓存而客户端声明不支持，会解压失败
4. **git 的 smart-HTTP 协商响应被误缓存** —— `POST /git-upload-pack` 是动态响应，若落入 proxy_cache 会返回错误 packfile
5. **大文件传输中断** —— rpm/deb/whl/jar 动辄数百 MB，`proxy_read_timeout` 不足会导致缓存写入半截文件

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `proxy/tengine/conf.d/registry.conf` | Docker 各上游的 443 分流（新增） |
| `proxy/tengine/conf.d/git.conf` | github / gitlab 分流（新增） |
| `proxy/tengine/conf.d/python.conf` | PyPI 缓存（新增） |
| `proxy/tengine/conf.d/nodejs.conf` | npm 缓存（新增） |
| `proxy/tengine/conf.d/java.conf` | Maven 缓存（新增） |
| `proxy/dnsmasq/dnsmasq.conf` | 扩展劫持清单（修改） |
| `proxy/docker-compose.yml` | 新增 registry / gitcache 服务（修改） |
| `proxy/gitcache/Dockerfile` | 已有，gitcache 构建上下文 |
| `proxy/tests/test-docker.sh` 等 | 各类型测试（新增） |

---

## Task 1: Docker 镜像缓存

**Files:**
- Create: `proxy/tengine/conf.d/registry.conf`
- Modify: `proxy/dnsmasq/dnsmasq.conf`
- Modify: `proxy/docker-compose.yml`
- Modify: `proxy/ca/domains.txt`
- Create: `proxy/tests/test-docker.sh`

**Interfaces:**
- Consumes: 计划 A 的 tengine 443 骨架、`os_cache` 之外的独立缓存区
- Produces: `registry:2` 服务（按上游分组）、`registry_cache` 缓存区

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
# proxy/tests/test-docker.sh —— 验证 Docker 镜像缓存透明可用
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0

# Docker Registry v2 API：/v2/ 返回 200 或 401 都表示 registry 正常工作
echo "== Docker 上游应能通过代理访问 =="
for d in registry-1.docker.io quay.io ghcr.io; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "$CA" --resolve "${d}:443:${TARGET}" \
    "https://${d}/v2/" --max-time 25 2>/dev/null) || code="000"
  if [[ "$code" =~ ^(200|401|403)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code（registry 未正常工作）"
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then echo "DOCKER-ALL-PASS"; else echo "DOCKER-HAS-FAILURE"; fi
exit $fail
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd /opt/TProxy/proxy && chmod +x tests/test-docker.sh && ./tests/test-docker.sh
```

Expected: FAIL —— 尚无 registry 服务、域名未劫持

- [ ] **Step 3: dnsmasq 加入 Docker 上游劫持**

在 `proxy/dnsmasq/dnsmasq.conf` 的「系统包仓库劫持」段之后追加：

```conf
# ---- Docker 镜像仓库劫持 ----
address=/registry-1.docker.io/192.168.0.18
address=/auth.docker.io/192.168.0.18
address=/production.cloudflare.docker.com/192.168.0.18
address=/quay.io/192.168.0.18
address=/gcr.io/192.168.0.18
address=/ghcr.io/192.168.0.18
address=/k8s.gcr.io/192.168.0.18
address=/registry.k8s.io/192.168.0.18
address=/mcr.microsoft.com/192.168.0.18
```

- [ ] **Step 4: 扩展 `ca/domains.txt` 并签发证书**

在 `proxy/ca/domains.txt` 追加：

```
registry-1.docker.io
auth.docker.io
production.cloudflare.docker.com
quay.io
gcr.io
ghcr.io
k8s.gcr.io
registry.k8s.io
mcr.microsoft.com
```

然后：

```bash
cd /opt/TProxy/proxy/ca
grep -v '^#' domains.txt | grep -v '^$' | while read -r d; do
  [[ -f "certs/${d}.crt" ]] || ./gen-cert.sh "$d"
done
ls certs/*.crt | wc -l
```

Expected: 证书总数从 15 增加到 24

- [ ] **Step 5: 写 tengine 的 Docker 分流配置**

`proxy/tengine/conf.d/registry.conf`：

```nginx
# Docker 镜像缓存分流
# registry:2 的 proxy 模式原样透传 /v2/ 路径，因此无需重写 URL

proxy_cache registry_cache;
proxy_cache_key "$scheme$host$request_uri";
proxy_cache_lock on;
proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
proxy_set_header Host $host;
proxy_ssl_server_name on;
proxy_redirect off;

server {
    listen 443 ssl;
    http2 on;
    server_name registry-1.docker.io auth.docker.io
                production.cloudflare.docker.com
                quay.io gcr.io ghcr.io k8s.gcr.io
                registry.k8s.io mcr.microsoft.com;

    ssl_certificate     /etc/nginx/certs/$ssl_server_name.crt;
    ssl_certificate_key /etc/nginx/certs/$ssl_server_name.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/registry.log main;
    client_max_body_size 0;

    # 大幅度放宽超时：镜像层动辄数百 MB
    proxy_connect_timeout 30s;
    proxy_send_timeout 1800s;
    proxy_read_timeout 1800s;

    location /v2/ {
        # blob 与 manifest 内容寻址，可长期缓存
        proxy_cache_valid 200 301 302 365d;
        proxy_cache_valid 401 403 1m;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header Host $host;
        proxy_pass https://$host$request_uri;
    }

    location / {
        proxy_cache off;              # 非 /v2/ 路径不缓存
        proxy_pass https://$host$request_uri;
    }
}
```

- [ ] **Step 6: compose 增加 registry 与 gitcache 服务**

在 `proxy/docker-compose.yml` 的 `services:` 下追加（**注意端口与旧环境的差异：这次用 host 网络，端口不冲突**）：

```yaml
  registry-docker:
    image: registry:2
    container_name: v3-reg-docker
    restart: unless-stopped
    network_mode: host
    environment:
      - REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io
      - REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry
      - REGISTRY_HTTP_ADDR=127.0.0.1:5001
      - REGISTRY_HTTP_SECRET=tproxy-shared-secret
    volumes:
      - ${CACHE_BASE}/registry/docker:/var/lib/registry
    dns:
      - 223.5.5.5
      - 223.6.6.6
```

> **关键**：`REGISTRY_HTTP_ADDR` 与宿主机端口必须一致（旧环境写 `ports: "5001:5000"` 而容器监听 5001，导致宿主 5001 映射到无人监听的容器 5000）。本计划统一用 host 网络 + `127.0.0.1:5001`，**彻底规避该类错配**。

- [ ] **Step 7: tengine 转发到本机 registry**

修改 `proxy/tengine/conf.d/registry.conf` 的 `location /v2/`，把上游改为本机 registry（其余上游暂直连）：

```nginx
    # Docker Hub 走本机 registry:2 缓存
    location /v2/ {
        proxy_cache_valid 200 301 302 365d;
        proxy_buffering off;
        proxy_request_buffering off;
        if ($host = "registry-1.docker.io") {
            proxy_pass http://127.0.0.1:5001;
        }
        proxy_pass https://$host$request_uri;
    }
```

> ⚠️ nginx 的 `if` 在 `location` 中限制多，若 `proxy_pass` 在 `if` 内报错，改用 `map` 生成上游变量：
> `map $host $registry_upstream { registry-1.docker.io http://127.0.0.1:5001; default https://$host; }`
> 然后 `proxy_pass $registry_upstream$request_uri;`

- [ ] **Step 8: 启动并运行测试**

```bash
cd /opt/TProxy/proxy
docker compose up -d registry-docker
docker compose exec tengine nginx -t && docker compose exec tengine nginx -s reload
sleep 8 && ./tests/test-docker.sh
```

Expected: `DOCKER-ALL-PASS`

- [ ] **Step 9: 端到端验证（实际拉取一个镜像）**

```bash
# 在 .18 上，用 curl 走代理拉取 manifest
curl -s -o /dev/null -w "%{http_code}\n" \
  --cacert /opt/TProxy/proxy/ca/tproxy-ca.crt \
  --resolve registry-1.docker.io:443:127.0.0.1 \
  "https://registry-1.docker.io/v2/library/alpine/manifests/latest" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" --max-time 30
```

Expected: `401`（需先取 token，属正常）；随后带 `Authorization` 再试应得 `200`

- [ ] **Step 10: 提交**

```bash
cd /opt/TProxy
git add proxy/dnsmasq/dnsmasq.conf proxy/ca/domains.txt \
        proxy/tengine/conf.d/registry.conf proxy/docker-compose.yml proxy/tests/test-docker.sh
git commit -m "feat(proxy): Docker 镜像缓存（registry:2 + 域名劫持 + TLS 分流）"
```

---

## Task 2: git 仓库缓存

**Files:**
- Create: `proxy/tengine/conf.d/git.conf`
- Modify: `proxy/dnsmasq/dnsmasq.conf`
- Modify: `proxy/docker-compose.yml`
- Modify: `proxy/ca/domains.txt`
- Create: `proxy/tests/test-git.sh`

**Interfaces:**
- Consumes: `proxy/gitcache/Dockerfile`（已存在）
- Produces: `gitcache` 服务（端口 4999）

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
# proxy/tests/test-git.sh —— 验证 git 缓存代理
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0

echo "== git 智能 HTTP 端点应可达 =="
for d in github.com gitlab.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "$CA" --resolve "${d}:443:${TARGET}" \
    "https://${d}/" --max-time 25 2>/dev/null) || code="000"
  if [[ "$code" =~ ^(200|301|302|404)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code"
    fail=1
  fi
done

echo "== gitcache 服务应监听 =="
if docker exec v3-tengine sh -c 'wget -q -O- http://127.0.0.1:4999/ >/dev/null 2>&1'; then
  echo "  ✅ gitcache 有响应"
else
  echo "  ❌ gitcache 无响应"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "GIT-ALL-PASS"; else echo "GIT-HAS-FAILURE"; fi
exit $fail
```

- [ ] **Step 2: 运行确认失败**

```bash
cd /opt/TProxy/proxy && chmod +x tests/test-git.sh && ./tests/test-git.sh
```

Expected: FAIL

- [ ] **Step 3: dnsmasq 加入 git 域名**

```conf
# ---- Git 仓库劫持 ----
address=/github.com/192.168.0.18
address=/gitlab.com/192.168.0.18
address=/gitee.com/192.168.0.18
```

- [ ] **Step 4: 签发证书**

`ca/domains.txt` 追加 `github.com`、`gitlab.com`、`gitee.com`，重跑签发循环。

- [ ] **Step 5: compose 加入 gitcache（本地构建）**

```yaml
  gitcache:
    build:
      context: ./gitcache
      dockerfile: Dockerfile
    image: tproxy/gitcache:local
    container_name: v3-gitcache
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${CACHE_BASE}/git:/var/gitcache
    command: ["-b", "/var/gitcache", "-p", "4999"]
    dns:
      - 223.5.5.5
      - 223.6.6.6
```

- [ ] **Step 6: 写 tengine 的 git 分流**

`proxy/tengine/conf.d/git.conf`：

```nginx
# Git 智能 HTTP 代理
# ⚠️ POST /git-upload-pack 是动态协商响应，绝不能缓存
server {
    listen 443 ssl;
    http2 on;
    server_name github.com gitlab.com gitee.com;

    ssl_certificate     /etc/nginx/certs/$ssl_server_name.crt;
    ssl_certificate_key /etc/nginx/certs/$ssl_server_name.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/git.log main;
    client_max_body_size 0;

    proxy_connect_timeout 30s;
    proxy_send_timeout 1800s;
    proxy_read_timeout 1800s;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_set_header Host $host;
    proxy_ssl_server_name on;

    # git 协议端点 → gitcache（动态响应，不缓存）
    location ~ ^/[^/]+/[^/]+(\.git)?/(info/refs|git-upload-pack|git-receive-pack) {
        proxy_pass http://127.0.0.1:4999;
        proxy_set_header Host $host;
        proxy_cache off;
    }

    # 其余（含 Release 等静态文件）→ 上游，可缓存
    location / {
        proxy_cache git_cache;
        proxy_cache_valid 200 302 7d;
        proxy_pass https://$host$request_uri;
    }
}
```

同时在 `nginx.conf` 加缓存区：

```nginx
    proxy_cache_path /var/cache/tproxy/git levels=1:2 keys_zone=git_cache:50m
                     max_size=50g inactive=30d use_temp_path=off;
```

- [ ] **Step 7: 启动并测试**

```bash
cd /opt/TProxy/proxy
docker compose up -d --build gitcache
docker compose exec tengine nginx -t && docker compose exec tengine nginx -s reload
sleep 5 && ./tests/test-git.sh
```

Expected: `GIT-ALL-PASS`

- [ ] **Step 8: 提交**

```bash
cd /opt/TProxy
git add proxy/dnsmasq/dnsmasq.conf proxy/ca/domains.txt \
        proxy/tengine/conf.d/git.conf proxy/tengine/nginx.conf \
        proxy/docker-compose.yml proxy/tests/test-git.sh
git commit -m "feat(proxy): git 仓库缓存（gitcache + 动态端点不缓存）"
```

---

## Task 3: Python (PyPI) 缓存

**Files:**
- Create: `proxy/tengine/conf.d/python.conf`
- Modify: `proxy/dnsmasq/dnsmasq.conf`、`proxy/ca/domains.txt`、`proxy/tengine/nginx.conf`
- Create: `proxy/tests/test-python.sh`

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
# proxy/tests/test-python.sh —— 验证 PyPI 缓存
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0
RESOLVE=(--resolve "pypi.org:443:${TARGET}" --resolve "files.pythonhosted.org:443:${TARGET}")

cache_status() {
  curl -sL -o /dev/null -D- --cacert "$CA" "${RESOLVE[@]}" "$1" --max-time 25 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{s=$2} END{print s}'
}

echo "== PyPI simple 索引应可达 =="
for d in pypi.org files.pythonhosted.org; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
    --resolve "${d}:443:${TARGET}" "https://${d}/" --max-time 25 2>/dev/null) || code="000"
  [[ "$code" =~ ^(200|301|302|404)$ ]] && echo "  ✅ $d -> HTTP $code" || { echo "  ❌ $d -> HTTP $code"; fail=1; }
done

echo "== simple 索引应走短 TTL（容忍后台更新窗口）=="
s=""
for i in 1 2 3 4 5; do
  s=$(cache_status "https://pypi.org/simple/pip/")
  echo "  第 $i 次 -> ${s:-无}"
  [[ "$s" == "HIT" ]] && break
  sleep 3
done
[[ "$s" == "HIT" ]] || { echo "  ❌ 5 次后仍未 HIT"; fail=1; }

if [[ $fail -eq 0 ]]; then echo "PYTHON-ALL-PASS"; else echo "PYTHON-HAS-FAILURE"; fi
exit $fail
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: dnsmasq 与证书**

```conf
# ---- Python 包索引劫持 ----
address=/pypi.org/192.168.0.18
address=/files.pythonhosted.org/192.168.0.18
address=/pypi.tuna.tsinghua.edu.cn/192.168.0.18
```

`ca/domains.txt` 追加同样三个域名并签发。

- [ ] **Step 4: nginx.conf 加缓存区**

```nginx
    proxy_cache_path /var/cache/tproxy/python levels=1:2 keys_zone=py_cache:50m
                     max_size=100g inactive=60d use_temp_path=off;
```

- [ ] **Step 5: 写 `proxy/tengine/conf.d/python.conf`**

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name pypi.org files.pythonhosted.org pypi.tuna.tsinghua.edu.cn;

    ssl_certificate     /etc/nginx/certs/$ssl_server_name.crt;
    ssl_certificate_key /etc/nginx/certs/$ssl_server_name.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/python.log main;
    client_max_body_size 0;
    proxy_connect_timeout 30s;
    proxy_read_timeout 1800s;
    proxy_set_header Host $host;
    proxy_ssl_server_name on;
    proxy_redirect off;
    proxy_cache py_cache;
    proxy_cache_key "$scheme$host$request_uri";
    proxy_cache_lock on;
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;

    # simple 索引：短 TTL（新版本发布必须及时可见）
    location ~ ^/simple/ {
        proxy_cache_valid 200 302 5m;
        proxy_pass https://$host$request_uri;
    }

    # 包文件：长 TTL（内容寻址，文件名含版本与哈希）
    location ~* \.(whl|tar\.gz|zip|egg)$ {
        proxy_cache_valid 200 302 365d;
        proxy_pass https://$host$request_uri;
    }

    location / {
        proxy_cache_valid 200 302 10m;
        proxy_pass https://$host$request_uri;
    }
}
```

- [ ] **Step 6: 重载并测试**

```bash
cd /opt/TProxy/proxy
docker compose exec tengine nginx -t && docker compose exec tengine nginx -s reload
docker compose restart dnsmasq
sleep 5 && ./tests/test-python.sh
```

Expected: `PYTHON-ALL-PASS`

- [ ] **Step 7: 提交**

```bash
cd /opt/TProxy
git add proxy/dnsmasq/dnsmasq.conf proxy/ca/domains.txt proxy/tengine/nginx.conf \
        proxy/tengine/conf.d/python.conf proxy/tests/test-python.sh
git commit -m "feat(proxy): Python (PyPI) 缓存（索引短 TTL / 包文件长 TTL）"
```

---

## Task 4: Node.js (npm) 缓存

**Files:**
- Create: `proxy/tengine/conf.d/nodejs.conf`
- Modify: 上述同名文件 + `nginx.conf`
- Create: `proxy/tests/test-nodejs.sh`

- [ ] **Step 1–2: 写失败测试并确认失败**

测试要点同 Python，但目标为 `registry.npmjs.org`，探测路径 `/express`。

> ⚠️ npm 的元数据响应可能带 `Content-Encoding: gzip`。测试需带 `--compressed`，
> 否则 curl 不解压会导致 JSON 解析失败——这本身就是要覆盖的失败模式。

```bash
#!/usr/bin/env bash
# proxy/tests/test-nodejs.sh —— 验证 npm 缓存
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0
RESOLVE=(--resolve "registry.npmjs.org:443:${TARGET}")

echo "== 元数据可获取且能正确解压 =="
body=$(curl -sL --compressed --cacert "$CA" "${RESOLVE[@]}" \
  "https://registry.npmjs.org/express" --max-time 25 2>/dev/null | head -c 200)
if [[ "$body" == *'"name"'* ]]; then
  echo "  ✅ 返回合法 JSON（gzip 解压正常）"
else
  echo "  ❌ 响应异常: ${body:0:80}"
  fail=1
fi

echo "== 缓存应能进入 HIT =="
s=""
for i in 1 2 3 4 5; do
  s=$(curl -sL -o /dev/null -D- --compressed --cacert "$CA" "${RESOLVE[@]}" \
      "https://registry.npmjs.org/express" --max-time 25 2>/dev/null \
      | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{v=$2} END{print v}')
  echo "  第 $i 次 -> ${s:-无}"
  [[ "$s" == "HIT" ]] && break
  sleep 3
done
[[ "$s" == "HIT" ]] || { echo "  ❌ 5 次后仍未 HIT"; fail=1; }

if [[ $fail -eq 0 ]]; then echo "NODEJS-ALL-PASS"; else echo "NODEJS-HAS-FAILURE"; fi
exit $fail
```

- [ ] **Step 3: dnsmasq 与证书**

```conf
# ---- Node.js 包索引劫持 ----
address=/registry.npmjs.org/192.168.0.18
address=/registry.npmmirror.com/192.168.0.18
address=/nodejs.org/192.168.0.18
```

- [ ] **Step 4: nginx.conf 加缓存区**

```nginx
    proxy_cache_path /var/cache/tproxy/nodejs levels=1:2 keys_zone=npm_cache:50m
                     max_size=100g inactive=60d use_temp_path=off;
```

- [ ] **Step 5: 写 `proxy/tengine/conf.d/nodejs.conf`**

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name registry.npmjs.org registry.npmmirror.com nodejs.org;

    ssl_certificate     /etc/nginx/certs/$ssl_server_name.crt;
    ssl_certificate_key /etc/nginx/certs/$ssl_server_name.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/nodejs.log main;
    client_max_body_size 0;
    proxy_connect_timeout 30s;
    proxy_read_timeout 1800s;
    proxy_set_header Host $host;
    proxy_ssl_server_name on;
    proxy_redirect off;
    proxy_cache npm_cache;
    proxy_cache_key "$scheme$host$request_uri";
    proxy_cache_lock on;
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;

    # 包 tarball：长 TTL
    location ~* \.tgz$ {
        proxy_cache_valid 200 302 365d;
        proxy_pass https://$host$request_uri;
    }

    # 元数据 JSON：短 TTL
    location / {
        proxy_cache_valid 200 302 10m;
        proxy_pass https://$host$request_uri;
    }
}
```

- [ ] **Step 6: 重载并测试**

```bash
cd /opt/TProxy/proxy
docker compose exec tengine nginx -t && docker compose exec tengine nginx -s reload
docker compose restart dnsmasq
sleep 5 && ./tests/test-nodejs.sh
```

Expected: `NODEJS-ALL-PASS`

- [ ] **Step 7: 提交**

```bash
cd /opt/TProxy
git add proxy/dnsmasq/dnsmasq.conf proxy/ca/domains.txt proxy/tengine/nginx.conf \
        proxy/tengine/conf.d/nodejs.conf proxy/tests/test-nodejs.sh
git commit -m "feat(proxy): Node.js (npm) 缓存（含 gzip 元数据解压验证）"
```

---

## Task 5: Java (Maven) 缓存

**Files:**
- Create: `proxy/tengine/conf.d/java.conf`
- Modify: 同上 + `nginx.conf`
- Create: `proxy/tests/test-java.sh`

- [ ] **Step 1–2: 写失败测试并确认失败**

```bash
#!/usr/bin/env bash
# proxy/tests/test-java.sh —— 验证 Maven 缓存
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0
RESOLVE=(--resolve "repo1.maven.org:443:${TARGET}")

cache_status() {
  curl -sL -o /dev/null -D- --cacert "$CA" "${RESOLVE[@]}" "$1" --max-time 25 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{s=$2} END{print s}'
}

echo "== Maven Central 可达 =="
code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" "${RESOLVE[@]}" \
  "https://repo1.maven.org/maven2/" --max-time 25 2>/dev/null) || code="000"
[[ "$code" =~ ^(200|301|302|404)$ ]] && echo "  ✅ HTTP $code" || { echo "  ❌ HTTP $code"; fail=1; }

echo "== release 制品应可缓存（不长于 365d）=="
s=""
for i in 1 2 3 4 5; do
  s=$(cache_status "https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.9/slf4j-api-2.0.9.pom")
  echo "  第 $i 次 -> ${s:-无}"
  [[ "$s" == "HIT" ]] && break
  sleep 3
done
[[ "$s" == "HIT" ]] || { echo "  ❌ release 制品未命中缓存"; fail=1; }

echo "== maven-metadata.xml 必须【不被缓存】=="
m=""
for i in 1 2; do
  m=$(cache_status "https://repo1.maven.org/maven2/org/slf4j/slf4j-api/maven-metadata.xml")
  echo "  第 $i 次 -> ${m:-无}"
  sleep 1
done
if [[ "$m" == "HIT" ]]; then
  echo "  ❌ maven-metadata.xml 被缓存了 —— 客户端将永远看不到新版本"
  fail=1
else
  echo "  ✅ maven-metadata.xml 未被缓存（状态: ${m:-无}）"
fi

if [[ $fail -eq 0 ]]; then echo "JAVA-ALL-PASS"; else echo "JAVA-HAS-FAILURE"; fi
exit $fail
```

- [ ] **Step 3: dnsmasq 与证书**

```conf
# ---- Java 制品仓库劫持 ----
address=/repo1.maven.org/192.168.0.18
address=/repo.maven.apache.org/192.168.0.18
address=/maven.aliyun.com/192.168.0.18
```

- [ ] **Step 4: nginx.conf 加缓存区**

```nginx
    proxy_cache_path /var/cache/tproxy/java levels=1:2 keys_zone=mvn_cache:50m
                     max_size=100g inactive=60d use_temp_path=off;
```

- [ ] **Step 5: 写 `proxy/tengine/conf.d/java.conf`**

```nginx
# Maven 制品缓存
# ⚠️ 关键：maven-metadata.xml 与 SNAPSHOT 绝不能缓存 —— 它们的内容会变，
# 缓存后客户端将永远解析不到新版本，且构建不会报错（静默使用旧依赖）。
server {
    listen 443 ssl;
    http2 on;
    server_name repo1.maven.org repo.maven.apache.org maven.aliyun.com;

    ssl_certificate     /etc/nginx/certs/$ssl_server_name.crt;
    ssl_certificate_key /etc/nginx/certs/$ssl_server_name.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/java.log main;
    client_max_body_size 0;
    proxy_connect_timeout 30s;
    proxy_read_timeout 1800s;
    proxy_set_header Host $host;
    proxy_ssl_server_name on;
    proxy_redirect off;
    proxy_cache mvn_cache;
    proxy_cache_key "$scheme$host$request_uri";
    proxy_cache_lock on;
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;

    # ① 元数据与快照：绝不缓存（必须放在最前，nginx 正则按出现顺序匹配）
    location ~* (maven-metadata\.xml|-[0-9.]+-SNAPSHOT) {
        proxy_cache off;
        proxy_pass https://$host$request_uri;
    }

    # ② release 制品：长 TTL（坐标含版本号，内容不变）
    location ~* \.(jar|pom|war|aar|module|asc|sha1|md5)$ {
        proxy_cache_valid 200 302 365d;
        proxy_pass https://$host$request_uri;
    }

    # ③ 其余（目录索引等）
    location / {
        proxy_cache off;
        proxy_pass https://$host$request_uri;
    }
}
```

- [ ] **Step 6: 重载并测试**

```bash
cd /opt/TProxy/proxy
docker compose exec tengine nginx -t && docker compose exec tengine nginx -s reload
docker compose restart dnsmasq
sleep 5 && ./tests/test-java.sh
```

Expected: `JAVA-ALL-PASS`（含「maven-metadata.xml 未被缓存」断言）

- [ ] **Step 7: 提交**

```bash
cd /opt/TProxy
git add proxy/dnsmasq/dnsmasq.conf proxy/ca/domains.txt proxy/tengine/nginx.conf \
        proxy/tengine/conf.d/java.conf proxy/tests/test-java.sh
git commit -m "feat(proxy): Java (Maven) 缓存（元数据与 SNAPSHOT 不缓存）"
```

---

## Task 6: 五类缓存总验收与文档

**Files:**
- Modify: `proxy/tests/acceptance.sh`（加入新的 5 个测试）
- Modify: `proxy/docs/OPERATIONS.md`（补充五类缓存的运维说明）

- [ ] **Step 1: 扩展验收脚本**

在 `acceptance.sh` 的 5 组之后追加：

```bash
run "Docker 镜像缓存"  "$D/test-docker.sh"
run "git 仓库缓存"     "$D/test-git.sh"
run "Python 缓存"      "$D/test-python.sh"
run "Node.js 缓存"     "$D/test-nodejs.sh"
run "Java 缓存"        "$D/test-java.sh"
```

- [ ] **Step 2: 运行完整验收**

```bash
cd /opt/TProxy/proxy && ./tests/acceptance.sh
```

Expected: 10 组全绿，`ACCEPTANCE-PASS`

- [ ] **Step 3: 更新 OPERATIONS.md**

补充：
- 六类缓存的目录与 TTL 速查表
- 「新增一个上游」的三处改动（已在计划 A 写明，补充 Docker/git 的特殊点）
- maven 元数据不缓存的**原因说明**（避免后人"优化"时误加缓存）

- [ ] **Step 4: 提交并打标签**

```bash
cd /opt/TProxy
git add proxy/tests/acceptance.sh proxy/docs/OPERATIONS.md
git commit -m "test(proxy): 五类缓存总验收与运维文档更新"
git tag -a phase-3-6-cache-backends -m "五类缓存后端完成：Docker/git/Python/Node.js/Java"
```

---

## 完成标准

1. `./tests/acceptance.sh` 10 组测试全绿
2. 两个原有容器 + registry + gitcache 均 `healthy`
3. 客户端只改 DNS + 装根 CA，六类制品（系统包 + 五类）均能透明命中缓存
4. git 仓库中不含任何 `.key` 私钥

## 后续计划

- **计划 C**（阶段 7）：`client-setup.sh`
- **计划 D**（阶段 8）：统一管理界面
