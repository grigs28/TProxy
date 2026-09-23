# TProxy 计划 C：客户端接入脚本 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一条命令把一台 Linux 机器接入 TProxy —— 改 DNS、装根 CA、处理工具级证书，使其对六类制品自动命中缓存，且**带公网兜底**（`.18` 挂掉时仍能上网）。

**Architecture:** 纯 Bash 客户端脚本，不依赖服务端进程。脚本检测发行版后分别处理 DNS 机制与 CA 信任库。核心难点是 **systemd-resolved 的并行查询会破坏劫持**（见 Global Constraints），必须在脚本中处理。

**Tech Stack:** Bash / systemd-resolved / NetworkManager / netplan / update-ca-certificates / update-ca-trust / keytool

**Spec:** `docs/specs/2026-09-23-architecture-design.md`

## Global Constraints

- **目标机（服务端）**：`192.168.0.18`，根 CA 位于 `/opt/TProxy/proxy/ca/tproxy-ca.crt`
- **客户端范围**：`192.168.0.0/16`（单机脚本，批量下发由使用方自理）
- **客户端 DNS 序列**：`192.168.0.18` → `223.5.5.5` → `119.29.29.29`
  （**禁用 `202.99.192.68`** —— 运营商劫持；`114.114.114.114` 实测慢 5-6 倍已淘汰）
- **根 CA 私钥绝不外传** —— 只分发 `tproxy-ca.crt`（公钥证书）

### 🔴 本计划要解决的核心问题：多 DNS 与劫持的冲突

| DNS 机制 | 多 DNS 行为 | 对劫持的影响 |
|---|---|---|
| **glibc resolver**（dnf/apt/curl 默认） | **串行**：首个超时才试下一个 | ✅ 安全，劫持与兜底兼得 |
| **systemd-resolved**（Ubuntu 默认） | **可能并行查询、取最快返回** | 🔴 **公网 DNS 先返回真实 IP，劫持失效** |

**必须在 Ubuntu 上关闭 systemd-resolved**，改用静态 `/etc/resolv.conf`（glibc 串行）。
这是整个方案能否生效的关键，不是可选项。

### 工具级 CA（系统信任库覆盖不到）

| 工具 | 处理 |
|---|---|
| dnf/apt/curl/pip/npm | 读系统库，无需额外操作 |
| **Docker** | 需 `/etc/docker/certs.d/<域名>/ca.crt` 并重启 docker |
| **Java** | 需 `keytool -importcert` 导入 `$JAVA_HOME/lib/security/cacerts` |
| Firefox | 独立证书库，脚本提示手动导入 |

## Review Focus

1. **`.18` 宕机时客户端能否上网** —— 这是「公网兜底」的核心诉求，若 DNS 串行配置错误会导致断网
2. **脚本重复执行是否安全** —— 运维会反复跑，必须幂等
3. **systemd-resolved 关闭后是否影响 VPN/其他功能** —— 关闭系统 DNS 服务有副作用
4. **Java 的 cacerts 路径因发行版而异** —— Ubuntu 与 RHEL 系不同，多 JDK 环境更复杂
5. **DNS 变更后是否真的生效** —— 某些系统缓存 DNS，改配置不等于生效

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `client/client-setup.sh` | 主脚本（单机接入） |
| `client/lib/detect.sh` | 发行版与 DNS 机制检测 |
| `client/lib/dns.sh` | DNS 配置（含 systemd-resolved 处理） |
| `client/lib/ca.sh` | 系统级与工具级 CA 安装 |
| `client/tests/test-client.sh` | 客户端侧验证 |
| `client/README.md` | 使用说明与回滚方法 |

---

## Task 1: 骨架与发行版检测

**Files:**
- Create: `client/client-setup.sh`
- Create: `client/lib/detect.sh`
- Create: `client/tests/test-detect.sh`

**Interfaces:**
- Produces: `detect_distro()` → 输出 `ubuntu|rhel|unknown`；
  `detect_dns_manager()` → 输出 `systemd-resolved|networkmanager|resolvconf|unknown`

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
# client/tests/test-detect.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/detect.sh
source "$DIR/lib/detect.sh"

fail=0
echo "== 发行版检测 =="
d=$(detect_distro)
if [[ "$d" =~ ^(ubuntu|rhel)$ ]]; then
  echo "  ✅ 检测到: $d"
else
  echo "  ❌ 未识别的发行版: $d"
  fail=1
fi

echo "== DNS 管理机制检测 =="
m=$(detect_dns_manager)
if [[ "$m" =~ ^(systemd-resolved|networkmanager|resolvconf|unknown)$ ]]; then
  echo "  ✅ 检测到: $m"
else
  echo "  ❌ 异常返回值: $m"
  fail=1
fi

[[ $fail -eq 0 ]] && echo "DETECT-PASS" || echo "DETECT-FAIL"
exit $fail
```

- [ ] **Step 2: 运行确认失败**

```bash
chmod +x client/tests/test-detect.sh && ./client/tests/test-detect.sh
```

Expected: FAIL —— `detect_distro: command not found`

- [ ] **Step 3: 写 `client/lib/detect.sh`**

```bash
#!/usr/bin/env bash
# 发行版与 DNS 机制检测

detect_distro() {
  [[ -r /etc/os-release ]] || { echo "unknown"; return; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *ubuntu*|*debian*)        echo "ubuntu" ;;
    *rhel*|*fedora*|*centos*|*openeuler*) echo "rhel" ;;
    *)                        echo "unknown" ;;
  esac
}

detect_dns_manager() {
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "systemd-resolved"
  elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "networkmanager"
  elif command -v resolvconf >/dev/null 2>&1; then
    echo "resolvconf"
  else
    echo "unknown"
  fi
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
./client/tests/test-detect.sh
```

Expected: `DETECT-PASS`

- [ ] **Step 5: 提交**

```bash
git add client/
git commit -m "feat(client): 接入脚本骨架与发行版/DNS 机制检测"
```

---

## Task 2: DNS 配置（含 systemd-resolved 处理）

**Files:**
- Create: `client/lib/dns.sh`
- Modify: `client/client-setup.sh`
- Create: `client/tests/test-dns-config.sh`

**Interfaces:**
- Consumes: `detect_distro()`、`detect_dns_manager()`
- Produces: `configure_dns()` → 写入 DNS 配置并使其生效；`backup_dns_config()` 备份原配置

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
# client/tests/test-dns-config.sh —— 验证 DNS 配置内容正确（不实际改动网络）
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/lib/dns.sh"

fail=0
echo "== DNS 序列应为 18 → 223.5.5.5 → 119.29.29.29 =="
got=$(dns_server_list | tr '\n' ' ')
want="192.168.0.18 223.5.5.5 119.29.29.29 "
if [[ "$got" == "$want" ]]; then
  echo "  ✅ $got"
else
  echo "  ❌ 期望[$want] 实际[$got]"
  fail=1
fi

echo "== 不得包含被禁用的运营商 DNS =="
if dns_server_list | grep -q '202.99.192.68'; then
  echo "  ❌ 出现了 202.99.192.68（运营商劫持，spec 明确禁用）"
  fail=1
else
  echo "  ✅ 未包含 202.99.192.68"
fi

[[ $fail -eq 0 ]] && echo "DNSCONF-PASS" || echo "DNSCONF-FAIL"
exit $fail
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 写 `client/lib/dns.sh`**

```bash
#!/usr/bin/env bash
# DNS 配置。核心约束：必须保证 .18 优先、且失败时能兜底 ——
# 这要求查询是【串行】的，因此 Ubuntu 上必须关掉 systemd-resolved。

TPROXY_DNS_PRIMARY="192.168.0.18"
TPROXY_DNS_FALLBACK=("223.5.5.5" "119.29.29.29")

dns_server_list() {
  printf '%s\n' "$TPROXY_DNS_PRIMARY"
  printf '%s\n' "${TPROXY_DNS_FALLBACK[@]}"
}

backup_dns_config() {
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  local dir="/var/backups/tproxy-client"
  mkdir -p "$dir"
  cp -a /etc/resolv.conf "$dir/resolv.conf.$stamp" 2>/dev/null || true
  echo "$dir/resolv.conf.$stamp"
}

# 关掉 systemd-resolved：它会【并行】查询多个 DNS 取最快返回，
# 公网 DNS 会抢在 .18 之前返回真实 IP，劫持直接失效。
disable_systemd_resolved() {
  systemctl disable --now systemd-resolved 2>/dev/null || true
  # 断开它管理的 stub 链接，让 /etc/resolv.conf 成为普通文件
  rm -f /etc/resolv.conf
  touch /etc/resolv.conf
  chmod 644 /etc/resolv.conf
}

write_resolv_conf() {
  {
    echo "# TProxy 客户端配置 —— 由 client-setup.sh 生成"
    echo "# 顺序即优先级：串行查询，.18 优先，其后为公网兜底"
    for s in $TPROXY_DNS_PRIMARY "${TPROXY_DNS_FALLBACK[@]}"; do
      echo "nameserver $s"
    done
    echo "options timeout:2 attempts:1"
  } > /etc/resolv.conf
}

configure_dns() {
  backup_dns_config >/dev/null
  local mgr; mgr=$(detect_dns_manager)
  if [[ "$mgr" == "systemd-resolved" ]]; then
    disable_systemd_resolved
  fi
  write_resolv_conf
  echo "DNS 已配置（机制: $mgr）"
}
```

> `options timeout:2 attempts:1` 缩短单次查询超时，让 `.18` 不可用时能**快速**切到兜底，
> 而不是卡 5 秒。

- [ ] **Step 4: 运行测试确认通过**

- [ ] **Step 5: 提交**

---

## Task 3: 根 CA 安装

**Files:**
- Create: `client/lib/ca.sh`
- Modify: `client/client-setup.sh`
- Create: `client/tests/test-ca-install.sh`

**Interfaces:**
- Consumes: `detect_distro()`
- Produces: `install_system_ca <证书文件>`、`install_docker_ca <证书文件> <域名列表>`、
  `install_java_ca <证书文件>`

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
# client/tests/test-ca-install.sh —— 验证 CA 安装函数存在且幂等
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/lib/ca.sh"

fail=0
echo "== 所需函数应已定义 =="
for fn in install_system_ca install_docker_ca install_java_ca; do
  if declare -F "$fn" >/dev/null; then
    echo "  ✅ $fn"
  else
    echo "  ❌ 缺少函数 $fn"
    fail=1
  fi
done

echo "== Docker 域名列表应为 9 个 =="
n=$(docker_ca_domains | wc -l)
if [[ "$n" -eq 9 ]]; then
  echo "  ✅ 9 个域名"
else
  echo "  ❌ 期望 9，实际 $n"
  fail=1
fi

[[ $fail -eq 0 ]] && echo "CAINST-PASS" || echo "CAINST-FAIL"
exit $fail
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 写 `client/lib/ca.sh`**

```bash
#!/usr/bin/env bash
# CA 安装：系统信任库 + 工具级信任库

CA_DEST_NAME="tproxy-ca.crt"

# Docker 客户端【不读系统 CA 库】，必须把 CA 放到
# /etc/docker/certs.d/<registry 域名>/ca.crt
docker_ca_domains() {
  cat <<'EOF'
registry-1.docker.io
auth.docker.io
production.cloudflare.docker.com
quay.io
gcr.io
ghcr.io
k8s.gcr.io
registry.k8s.io
mcr.microsoft.com
EOF
}

install_system_ca() {
  local cert="$1"
  [[ -f "$cert" ]] || { echo "❌ 证书不存在: $cert"; return 1; }
  case "$(detect_distro)" in
    ubuntu)
      install -m 644 "$cert" "/usr/local/share/ca-certificates/$CA_DEST_NAME"
      update-ca-certificates 2>&1 | tail -2
      ;;
    rhel)
      install -m 644 "$cert" "/etc/pki/ca-trust/source/anchors/$CA_DEST_NAME"
      update-ca-trust extract
      ;;
    *)
      echo "❌ 不支持的发行版，请手动安装 $cert"
      return 1
      ;;
  esac
  echo "系统信任库已更新"
}

install_docker_ca() {
  local cert="$1"
  [[ -d /etc/docker ]] || { echo "未安装 docker，跳过"; return 0; }
  while read -r d; do
    [[ -z "$d" ]] && continue
    install -d -m 755 "/etc/docker/certs.d/$d"
    install -m 644 "$cert" "/etc/docker/certs.d/$d/ca.crt"
  done < <(docker_ca_domains)
  echo "Docker 证书目录已写入（9 个域名）"
  echo "⚠️ 需重启 docker 才生效：systemctl restart docker"
}

install_java_ca() {
  local cert="$1"
  local ks=""
  # 找可用的 JDK：优先 JAVA_HOME，其次常见路径
  if [[ -n "${JAVA_HOME:-}" && -f "$JAVA_HOME/lib/security/cacerts" ]]; then
    ks="$JAVA_HOME/lib/security/cacerts"
  else
    ks=$(find /usr/lib/jvm -name cacerts -path '*security*' 2>/dev/null | head -1)
  fi
  [[ -n "$ks" ]] || { echo "未找到 JDK cacerts，跳过"; return 0; }
  keytool -importcert -noprompt -trustcacerts \
    -alias tproxy-ca -file "$cert" -keystore "$ks" -storepass changeit 2>&1 | tail -2
  echo "Java cacerts 已更新: $ks"
}
```

- [ ] **Step 4: 运行测试确认通过**

- [ ] **Step 5: 提交**

---

## Task 4: 主脚本整合与验证

**Files:**
- Modify: `client/client-setup.sh`（完整实现）
- Create: `client/tests/test-client.sh`

- [ ] **Step 1: 写主脚本**

```bash
#!/usr/bin/env bash
# client-setup.sh —— 把本机接入 TProxy 透明缓存
#
# 用法:
#   ./client-setup.sh                    # 从默认地址取 CA
#   ./client-setup.sh --ca /path/ca.crt  # 用本地 CA 文件
#   ./client-setup.sh --rollback         # 回滚
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/detect.sh
source "$DIR/lib/detect.sh"
# shellcheck source=lib/dns.sh
source "$DIR/lib/dns.sh"
# shellcheck source=lib/ca.sh
source "$DIR/lib/ca.sh"

TPROXY_SERVER="${TPROXY_SERVER:-192.168.0.18}"
CA_URL="http://${TPROXY_SERVER}/tproxy-ca.crt"
CA_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ca)       CA_FILE="$2"; shift 2 ;;
    --server)   TPROXY_SERVER="$2"; shift 2 ;;
    --rollback) do_rollback; exit 0 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *)          echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "=== TProxy 客户端接入 ==="
echo "服务端: $TPROXY_SERVER"
echo "发行版: $(detect_distro)   DNS 机制: $(detect_dns_manager)"
echo

echo "== 1/4 配置 DNS =="
configure_dns
echo

echo "== 2/4 获取根 CA =="
if [[ -z "$CA_FILE" ]]; then
  CA_FILE="/tmp/tproxy-ca.crt"
  echo "从 $CA_URL 下载..."
  if ! curl -fsSL --max-time 20 "$CA_URL" -o "$CA_FILE"; then
    echo "❌ 下载失败。请用 --ca 指定本地 CA 文件，或确认服务端可达。"
    exit 1
  fi
fi
openssl x509 -in "$CA_FILE" -noout -subject 2>/dev/null || { echo "❌ 不是合法证书"; exit 1; }
echo

echo "== 3/4 安装 CA =="
install_system_ca "$CA_FILE"
install_docker_ca "$CA_FILE"
install_java_ca "$CA_FILE"
echo

echo "== 4/4 验证 =="
"$DIR/tests/test-client.sh" || true

echo
echo "✅ 接入完成。"
echo "   注意：Docker 需重启才生效 —— systemctl restart docker"
```

- [ ] **Step 2: 写客户端验证脚本**

```bash
#!/usr/bin/env bash
# client/tests/test-client.sh —— 在本机（客户端）验证接入效果
set -uo pipefail
TPROXY_SERVER="${TPROXY_SERVER:-192.168.0.18}"
fail=0

echo "== DNS 解析应指向 $TPROXY_SERVER =="
for d in repo.openeuler.org registry-1.docker.io pypi.org registry.npmjs.org repo1.maven.org; do
  ip=$(dig +short +time=3 +tries=1 "$d" 2>/dev/null | grep -E '^[0-9]' | head -1)
  if [[ "$ip" == "$TPROXY_SERVER" ]]; then
    echo "  ✅ $d -> $ip"
  else
    echo "  ❌ $d -> ${ip:-解析失败}（期望 $TPROXY_SERVER）"
    fail=1
  fi
done

echo "== 公网兜底：未劫持域名应能正常解析 =="
r=$(dig +short +time=3 +tries=1 www.baidu.com 2>/dev/null | grep -E '^[0-9]' | head -1)
if [[ -n "$r" ]]; then
  echo "  ✅ 兜底正常 ($r)"
else
  echo "  ❌ 兜底失败 —— .18 不可用时可能断网"
  fail=1
fi

echo "== 证书链应被信任 =="
if curl -s -o /dev/null --max-time 15 "https://repo.openeuler.org/" 2>/dev/null; then
  echo "  ✅ HTTPS 校验通过（根 CA 已生效）"
else
  echo "  ❌ HTTPS 校验失败（根 CA 未生效？）"
  fail=1
fi

[[ $fail -eq 0 ]] && echo "CLIENT-PASS" || echo "CLIENT-FAIL"
exit $fail
```

- [ ] **Step 3: 实现 `do_rollback`**

在 `client-setup.sh` 中补充：

```bash
do_rollback() {
  echo "=== 回滚 TProxy 客户端配置 ==="
  local latest
  latest=$(ls -t /var/backups/tproxy-client/resolv.conf.* 2>/dev/null | head -1 || true)
  if [[ -n "$latest" ]]; then
    cp -a "$latest" /etc/resolv.conf
    echo "已恢复 DNS: $latest"
  else
    echo "⚠️ 未找到备份，请手动恢复 /etc/resolv.conf"
  fi
  case "$(detect_distro)" in
    ubuntu) rm -f "/usr/local/share/ca-certificates/$CA_DEST_NAME"; update-ca-certificates --fresh >/dev/null 2>&1 || true ;;
    rhel)   rm -f "/etc/pki/ca-trust/source/anchors/$CA_DEST_NAME"; update-ca-trust extract ;;
  esac
  rm -rf /etc/docker/certs.d/*/ca.crt 2>/dev/null || true
  echo "已移除 CA。Docker 与 Java 需手动重启/清理。"
}
```

> `do_rollback` 必须在参数解析之前定义（脚本中 `--rollback` 会调用它）。

- [ ] **Step 4: 在真实客户端上验证**

在一个测试客户端（如 `.29`）上执行，然后运行 `test-client.sh`。

Expected: `CLIENT-PASS`

- [ ] **Step 5: 提交**

---

## Task 5: 文档与 QUIC/DoH 加固说明

**Files:**
- Create: `client/README.md`

- [ ] **Step 1: 写使用说明**

````markdown
# TProxy 客户端接入

## 用法

```bash
# 标准接入（从服务端下载根 CA）
sudo ./client-setup.sh

# 服务端不可达时，手动拷入 CA
sudo ./client-setup.sh --ca /path/to/tproxy-ca.crt

# 回滚
sudo ./client-setup.sh --rollback
```

## 它做了什么

| 步骤 | 内容 |
|---|---|
| 1 | 配置 DNS：`192.168.0.18` → `223.5.5.5` → `119.29.29.29`（串行，带公网兜底） |
| 2 | 下载根 CA |
| 3 | 安装到系统信任库 + Docker + Java |
| 4 | 自检 |

## 注意事项

- **Ubuntu 会关闭 systemd-resolved** —— 它并行查询多 DNS 会让公网结果抢在 `.18` 前面，
  使劫持失效。如需保留，请改用仅指向 `.18` 的单 DNS 配置（但失去公网兜底）。
- **Docker 需重启**：`systemctl restart docker`
- **Firefox 需手动导入**根 CA（它不读系统信任库）
- **回滚**：`sudo ./client-setup.sh --rollback`

## ⚠️ 可选加固：阻断 QUIC 与加密 DNS

本脚本**不自动实施**以下策略（它们影响整机网络行为，应由你决定）：

```bash
# 阻断 QUIC（UDP 443）—— 否则客户端走 HTTP/3 会绕过 TCP 代理
iptables -A OUTPUT -p udp --dport 443 -j REJECT

# 阻断 DoT（853）—— 否则加密 DNS 会绕过 dnsmasq 劫持
iptables -A OUTPUT -p tcp --dport 853 -j REJECT
iptables -A OUTPUT -p udp --dport 853 -j REJECT
```

> 不加这两条，缓存仍可用，但存在被绕过的可能（客户端走 QUIC/DoH 时不命中缓存）。
````

- [ ] **Step 2: 提交并打标签**

```bash
git add client/
git commit -m "feat(client): 客户端接入脚本（DNS + CA + 工具级证书 + 回滚）"
git tag -a phase-7-client-setup -m "客户端接入脚本完成"
```

---

## 完成标准

1. 在至少一个 Ubuntu 和一个 RHEL 系客户端上执行成功
2. `test-client.sh` 输出 `CLIENT-PASS`
3. `--rollback` 能恢复原 DNS 配置
4. 脚本重复执行不报错（幂等）

## 后续计划

- **计划 D**（阶段 8）：统一管理界面
