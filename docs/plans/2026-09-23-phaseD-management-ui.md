# TProxy 计划 D：统一管理界面 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为六类缓存提供统一管理界面，让运维能**看见**缓存是否生效、**一步**新增上游、**集中**管理证书 —— 而不是靠改 3 处配置文件加重启。

**Architecture:** Flask 后端 + 单页前端，SQLite 持久化。**不复用旧 `proxy-manager` 代码**（它围绕已废弃的 generator/hosts-master 方案设计，详见 `docs/README.md` 的说明）。后端只读地解析 nginx 配置与缓存目录，写入限于 TProxy 管理的文件。

**Tech Stack:** Python 3.8+ / Flask / SQLite / 原生 JS（免构建）

**Spec:** `docs/specs/2026-09-23-architecture-design.md` §3.1

## Global Constraints

- **部署位置**：与 `proxy/` 同机（`192.168.0.18`），容器名 `v3-manager`（`v3-` 前缀）
- **端口**：`5557`（沿用旧约定，但代码全新）
- **持久化**：SQLite 单文件，路径 `${CACHE_BASE}/manager/manager.db` —— **不引入数据库服务**
- **认证**：默认 `admin/admin`，首次启动强制提示修改（仅绑定 `127.0.0.1` 时可不启用）
- **只读优先**：日志、缓存统计、容器状态一律只读；写操作仅限劫持规则与证书
- **不得依赖旧 `proxy-manager/`** 的任何模块

### 与旧 proxy-manager 的关系

旧代码的 `monitor.py` 硬编码了旧日志路径与旧日志格式（`cache_status="HIT"`），
在当前架构下**恒返回空**（静默假正常）；`firewall.py` 的端口清单是旧的
（53/3128/5557/8080，实际需 80/443）。**本计划从零重写。**

## Review Focus

1. **日志解析与 nginx 实际格式不符** —— 旧代码正是栽在这里（正则匹配不到任何行，界面显示空却不报错）
2. **缓存统计把仍在写的文件算进去** —— 会导致统计值抖动甚至读到半截文件
3. **新增上游时只改了配置没重载** —— 界面显示成功但实际未生效
4. **并发编辑配置文件** —— 界面写规则与运维手工编辑冲突，互相覆盖
5. **证书到期未告警** —— CA 有效期 10 年，但域名证书若单独签发需跟踪

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `manager/app.py` | Flask 入口与路由 |
| `manager/backend/config_read.py` | 解析 nginx/dnsmasq 配置（只读） |
| `manager/backend/cache_stats.py` | 缓存占用与命中率统计 |
| `manager/backend/rules.py` | 劫持规则增删（写 dnsmasq.conf / conf.d） |
| `manager/backend/certs.py` | 证书列表与到期检查 |
| `manager/backend/services.py` | 容器状态与重启 |
| `manager/db.py` | SQLite 读写 |
| `manager/static/index.html` | 单页界面 |
| `manager/static/app.js` | 前端逻辑 |
| `manager/Dockerfile` | 镜像构建 |
| `manager/tests/test_*.py` | 单元测试 |

---

## Task 1: 骨架与配置解析

**Files:**
- Create: `manager/app.py`、`manager/backend/config_read.py`
- Create: `manager/tests/test_config_read.py`

**Interfaces:**
- Produces: `parse_dnsmasq_rules(conf_path) -> list[dict]`（每项含 `domain`、`target`、`type`）；
  `parse_nginx_servers(confd_dir) -> list[dict]`（每项含 `file`、`server_name`、`listen`、`cache_zone`）

- [ ] **Step 1: 写失败测试**

```python
# manager/tests/test_config_read.py
import os
import tempfile
from backend.config_read import parse_dnsmasq_rules, parse_nginx_servers

DNSMASQ_SAMPLE = """
listen-address=0.0.0.0
port=53
server=223.5.5.5
address=/repo.openeuler.org/192.168.0.18
address=/github.com/192.168.0.18
host-record=nt08.sxsy,192.168.0.38,192.168.0.48
"""

def test_parse_dnsmasq_rules_extracts_address_lines():
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
        f.write(DNSMASQ_SAMPLE)
        path = f.name
    try:
        rules = parse_dnsmasq_rules(path)
        domains = [r["domain"] for r in rules]
        # 只应解析 address= 行，不应把 server= / host-record= 混进来
        assert "repo.openeuler.org" in domains
        assert "github.com" in domains
        assert len(rules) == 2
        assert all(r["target"] == "192.168.0.18" for r in rules)
    finally:
        os.unlink(path)

NGINX_SAMPLE = """
server {
    listen 443 ssl;
    server_name pypi.org files.pythonhosted.org;
    proxy_cache py_cache;
    proxy_pass https://$host$request_uri;
}
"""

def test_parse_nginx_servers_extracts_names_and_cache():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "python.conf"), "w") as f:
            f.write(NGINX_SAMPLE)
        servers = parse_nginx_servers(d)
        assert len(servers) == 1
        s = servers[0]
        assert s["file"] == "python.conf"
        assert "pypi.org" in s["server_name"]
        assert s["cache_zone"] == "py_cache"
```

- [ ] **Step 2: 运行确认失败**

```bash
cd manager && python3 -m pytest tests/test_config_read.py -v
```

Expected: FAIL —— `ModuleNotFoundError: No module named 'backend.config_read'`

- [ ] **Step 3: 写 `manager/backend/config_read.py`**

```python
"""只读解析 TProxy 的 nginx / dnsmasq 配置。

刻意不做完整语法解析 —— 只提取界面需要的字段，
避免因配置格式微调导致解析器大面积失效。
"""
import os
import re


def parse_dnsmasq_rules(conf_path):
    """提取 address=/<域名>/<目标>/ 形式的劫持规则。

    注意：只匹配 address= 行。server=（上游 DNS）与 host-record=（内网域名）
    都不是劫持规则，不应混入。
    """
    rules = []
    if not os.path.exists(conf_path):
        return rules
    pat = re.compile(r"^\s*address=/([^/]+)/([^/\s]+)/?\s*$")
    with open(conf_path, encoding="utf-8") as f:
        for line in f:
            m = pat.match(line)
            if m:
                rules.append({"domain": m.group(1), "target": m.group(2), "type": "address"})
    return rules


def parse_nginx_servers(confd_dir):
    """提取每个 conf.d/*.conf 里的 server_name 与 proxy_cache。"""
    servers = []
    if not os.path.isdir(confd_dir):
        return servers
    for name in sorted(os.listdir(confd_dir)):
        if not name.endswith(".conf"):
            continue
        path = os.path.join(confd_dir, name)
        with open(path, encoding="utf-8") as f:
            text = f.read()
        # 去掉注释行，避免把注释里的示例当成真实配置
        text = re.sub(r"^\s*#.*$", "", text, flags=re.M)
        names = []
        for m in re.finditer(r"server_name\s+([^;]+);", text):
            names.extend(m.group(1).split())
        cache = None
        m = re.search(r"proxy_cache\s+([^;\s]+);", text)
        if m:
            cache = m.group(1)
        if names:
            servers.append({
                "file": name,
                "server_name": names,
                "listen": sorted(set(re.findall(r"listen\s+(\d+)", text))),
                "cache_zone": cache,
            })
    return servers
```

- [ ] **Step 4: 运行测试确认通过**

```bash
python3 -m pytest tests/test_config_read.py -v
```

Expected: 2 passed

- [ ] **Step 5: 提交**

```bash
git add manager/
git commit -m "feat(manager): 骨架与 nginx/dnsmasq 配置只读解析"
```

---

## Task 2: 缓存统计

**Files:**
- Create: `manager/backend/cache_stats.py`
- Create: `manager/tests/test_cache_stats.py`

**Interfaces:**
- Consumes: 无
- Produces: `dir_usage(path) -> dict{bytes, files}`；`all_cache_usage(base) -> list[dict]`

- [ ] **Step 1: 写失败测试**

```python
# manager/tests/test_cache_stats.py
import os
import tempfile
from backend.cache_stats import dir_usage, all_cache_usage

def test_dir_usage_sums_file_sizes():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "a"), "wb") as f:
            f.write(b"x" * 100)
        os.makedirs(os.path.join(d, "sub"))
        with open(os.path.join(d, "sub", "b"), "wb") as f:
            f.write(b"y" * 50)
        r = dir_usage(d)
        assert r["bytes"] == 150
        assert r["files"] == 2

def test_dir_usage_missing_dir_returns_zero():
    r = dir_usage("/nonexistent-path-tproxy-test")
    assert r["bytes"] == 0 and r["files"] == 0

def test_all_cache_usage_lists_known_types():
    with tempfile.TemporaryDirectory() as base:
        for t in ("os", "registry", "git"):
            os.makedirs(os.path.join(base, t))
        rows = all_cache_usage(base)
        types = [r["type"] for r in rows]
        assert "os" in types and "registry" in types
        # 未创建的目录也应出现（值为 0），否则界面无法提示「未启用」
        assert "python" in types
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 写 `manager/backend/cache_stats.py`**

```python
"""缓存占用统计。

⚠️ 只统计【已完成】的文件：nginx 的临时文件以 .tmp 结尾且可能仍在写入，
计入会导致统计抖动，甚至读到半截文件的大小。
"""
import os

CACHE_TYPES = ["os", "registry", "git", "python", "nodejs", "java"]

_SKIP_SUFFIX = (".tmp", ".temp")


def dir_usage(path):
    total = 0
    files = 0
    if not os.path.isdir(path):
        return {"bytes": 0, "files": 0}
    for root, _dirs, names in os.walk(path):
        for n in names:
            if n.endswith(_SKIP_SUFFIX):
                continue
            p = os.path.join(root, n)
            try:
                total += os.path.getsize(p)
                files += 1
            except OSError:
                # 文件可能在遍历过程中被删除 —— 跳过而非中断整个统计
                continue
    return {"bytes": total, "files": files}


def all_cache_usage(base):
    rows = []
    for t in CACHE_TYPES:
        u = dir_usage(os.path.join(base, t))
        rows.append({"type": t, "bytes": u["bytes"], "files": u["files"],
                     "enabled": os.path.isdir(os.path.join(base, t))})
    return rows
```

- [ ] **Step 4: 运行测试确认通过**

- [ ] **Step 5: 提交**

---

## Task 3: 证书管理

**Files:**
- Create: `manager/backend/certs.py`
- Create: `manager/tests/test_certs.py`

**Interfaces:**
- Produces: `list_certs(certs_dir) -> list[dict]`（每项含 `domain`、`not_after`、`days_left`、`expired`）

- [ ] **Step 1: 写失败测试**

```python
# manager/tests/test_certs.py
import datetime
import os
import shutil
import subprocess
import tempfile
from backend.certs import list_certs

def _make_cert(d, domain, days):
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", os.path.join(d, f"{domain}.key"),
         "-out", os.path.join(d, f"{domain}.crt"),
         "-days", str(days), "-subj", f"/CN={domain}"],
        check=True, capture_output=True)

def test_list_certs_reports_days_left():
    with tempfile.TemporaryDirectory() as d:
        _make_cert(d, "example.com", 30)
        rows = list_certs(d)
        assert len(rows) == 1
        r = rows[0]
        assert r["domain"] == "example.com"
        assert 28 <= r["days_left"] <= 30
        assert r["expired"] is False

def test_list_certs_empty_dir():
    with tempfile.TemporaryDirectory() as d:
        assert list_certs(d) == []
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 写 `manager/backend/certs.py`**

```python
"""证书清单与到期检查。

用 `openssl x509 -enddate` 读取而非引入 cryptography 依赖 ——
部署环境已有 openssl（签发证书本就依赖它）。
"""
import datetime
import os
import re
import subprocess

_ENDDATE = re.compile(r"notAfter=(.+)")


def _not_after(cert_path):
    try:
        out = subprocess.run(["openssl", "x509", "-in", cert_path, "-noout", "-enddate"],
                             check=True, capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    m = _ENDDATE.search(out)
    if not m:
        return None
    # openssl 输出形如 "Mar  3 12:00:00 2027 GMT"
    try:
        return datetime.datetime.strptime(m.group(1).strip(), "%b %d %H:%M:%S %Y %Z")
    except ValueError:
        return None


def list_certs(certs_dir):
    rows = []
    if not os.path.isdir(certs_dir):
        return rows
    now = datetime.datetime.utcnow()
    for name in sorted(os.listdir(certs_dir)):
        if not name.endswith(".crt"):
            continue
        path = os.path.join(certs_dir, name)
        na = _not_after(path)
        if na is None:
            continue
        days = (na - now).days
        rows.append({
            "domain": name[:-4],
            "not_after": na.strftime("%Y-%m-%d"),
            "days_left": days,
            "expired": days < 0,
            "expiring_soon": 0 <= days <= 30,
        })
    return rows
```

- [ ] **Step 4: 运行测试确认通过**

- [ ] **Step 5: 提交**

---

## Task 4: Flask 应用与 API

**Files:**
- Create: `manager/app.py`
- Create: `manager/db.py`
- Create: `manager/tests/test_api.py`

**Interfaces:**
- Consumes: 前面三个模块
- Produces: `/api/status`、`/api/cache`、`/api/rules`、`/api/certs`、`/api/services`

- [ ] **Step 1: 写失败测试**

```python
# manager/tests/test_api.py
import os
import tempfile
import pytest
from app import create_app

@pytest.fixture
def client(monkeypatch, tmp_path):
    (tmp_path / "conf").mkdir()
    (tmp_path / "certs").mkdir()
    monkeypatch.setenv("TPROXY_CACHE_BASE", str(tmp_path))
    monkeypatch.setenv("TPROXY_CONF_D", str(tmp_path / "conf"))
    monkeypatch.setenv("TPROXY_DNSMASQ_CONF", str(tmp_path / "dnsmasq.conf"))
    monkeypatch.setenv("TPROXY_CERTS_DIR", str(tmp_path / "certs"))
    app = create_app()
    app.config["TESTING"] = True
    return app.test_client()

def test_status_returns_ok(client):
    r = client.get("/api/status")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"

def test_cache_lists_six_types(client):
    r = client.get("/api/cache")
    assert r.status_code == 200
    types = [row["type"] for row in r.get_json()["types"]]
    assert len(types) == 6

def test_rules_empty_when_no_config(client):
    r = client.get("/api/rules")
    assert r.status_code == 200
    assert r.get_json()["rules"] == []
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 写 `manager/app.py`**

```python
"""TProxy 管理界面后端。

所有路径通过环境变量注入，便于测试与部署分离。
"""
import os
from flask import Flask, jsonify, send_from_directory

from backend.cache_stats import all_cache_usage
from backend.certs import list_certs
from backend.config_read import parse_dnsmasq_rules, parse_nginx_servers

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")


def create_app():
    app = Flask(__name__, static_folder=STATIC_DIR)

    def cfg(key, default):
        return os.environ.get(key, default)

    @app.route("/")
    def index():
        return send_from_directory(STATIC_DIR, "index.html")

    @app.route("/api/status")
    def status():
        return jsonify({"status": "ok"})

    @app.route("/api/cache")
    def cache():
        base = cfg("TPROXY_CACHE_BASE", "/mnt/HDD/tproxy-cache")
        return jsonify({"types": all_cache_usage(base)})

    @app.route("/api/rules")
    def rules():
        path = cfg("TPROXY_DNSMASQ_CONF", "/opt/TProxy/proxy/dnsmasq/dnsmasq.conf")
        confd = cfg("TPROXY_CONF_D", "/opt/TProxy/proxy/tengine/conf.d")
        return jsonify({
            "rules": parse_dnsmasq_rules(path),
            "servers": parse_nginx_servers(confd),
        })

    @app.route("/api/certs")
    def certs():
        d = cfg("TPROXY_CERTS_DIR", "/opt/TProxy/proxy/ca/certs")
        return jsonify({"certs": list_certs(d)})

    return app


if __name__ == "__main__":
    create_app().run(host="127.0.0.1", port=5557)
```

- [ ] **Step 4: 运行测试确认通过**

- [ ] **Step 5: 提交**

---

## Task 5: 前端界面

**Files:**
- Create: `manager/static/index.html`、`manager/static/app.js`

- [ ] **Step 1: 写界面**

单页、免构建、原生 JS。四个区块：

1. **缓存总览** —— 六类的占用与文件数（条形图 + 表格），未启用的置灰
2. **劫持规则** —— 域名 → 目标表格，标注对应的 tengine server 块
3. **证书** —— 域名、到期日、剩余天数，30 天内标黄
4. **服务状态** —— 各容器状态与重启按钮

关键：**所有失败都要显式呈现**（空表格旁写明「未解析到规则」，而非静默留白）——
旧版正是「显示为空却不报错」，才让崩溃 1.7 万次无人察觉。

- [ ] **Step 2: 手工验证**

```bash
TPROXY_CACHE_BASE=/mnt/HDD/tproxy-cache python3 manager/app.py
# 浏览器打开 http://192.168.0.18:5557
```

Expected: 四个区块均有数据；缓存总览显示六类

- [ ] **Step 3: 提交**

---

## Task 6: 容器化与总验收

**Files:**
- Create: `manager/Dockerfile`
- Modify: `proxy/docker-compose.yml`
- Modify: `proxy/tests/acceptance.sh`

- [ ] **Step 1: 写 Dockerfile**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask
COPY . /app
EXPOSE 5557
CMD ["python3", "app.py"]
```

- [ ] **Step 2: 加入 compose**

```yaml
  manager:
    build:
      context: ./manager
      dockerfile: Dockerfile
    image: tproxy/manager:local
    container_name: v3-manager
    restart: unless-stopped
    network_mode: host
    environment:
      - TPROXY_CACHE_BASE=${CACHE_BASE}
      - TPROXY_CONF_D=/opt/TProxy/proxy/tengine/conf.d
      - TPROXY_DNSMASQ_CONF=/opt/TProxy/proxy/dnsmasq/dnsmasq.conf
      - TPROXY_CERTS_DIR=/opt/TProxy/proxy/ca/certs
    volumes:
      - /opt/TProxy/proxy:/opt/TProxy/proxy:ro     # 只读挂载配置
      - ${CACHE_BASE}:/mnt/HDD/tproxy-cache:ro      # 只读挂载缓存（统计用）
```

> 两个挂载都是 **`:ro`** —— 界面只读展示；写操作（新增上游）通过提示运维执行
> `deploy.sh` 完成，避免界面与手工编辑互相覆盖。

- [ ] **Step 3: 扩展验收**

在 `acceptance.sh` 追加：

```bash
run "管理界面"  "$D/test-manager.sh"
```

新增 `proxy/tests/test-manager.sh` 验证 API 可达与数据非空。

- [ ] **Step 4: 运行完整验收**

Expected: 11 组全绿

- [ ] **Step 5: 提交并打标签**

```bash
git add manager/ proxy/docker-compose.yml proxy/tests/
git commit -m "feat(manager): 统一管理界面（缓存总览/规则/证书/服务状态）"
git tag -a phase-8-management-ui -m "统一管理界面完成"
```

---

## 完成标准

1. `acceptance.sh` 11 组全绿
2. 浏览器可看到六类缓存的真实占用
3. 证书列表标出 30 天内到期的项
4. 界面**不**直接写配置文件（避免与运维手工编辑冲突）
5. 不依赖旧 `proxy-manager/` 的任何代码

## 全部计划完成后的状态

| 计划 | 阶段 | 能力 |
|---|---|---|
| A | 1-2 | 系统包透明缓存 |
| B | 3-6 | + Docker / git / Python / Node.js / Java |
| C | 7 | 客户端一条命令接入 |
| D | 8 | 统一管理界面 |
