#!/bin/bash
# ============================================================
#  tp.client.sh —— 把本机接入 TProxy 透明缓存
#
#  用法: w.sh tp.client.sh <选项>
#        w.sh tp.client.sh              # 无参数 → 显示本帮助（不做任何改动）
#        w.sh tp.client.sh -i           # 完整接入（改 DNS + 装证书）
#        w.sh tp.client.sh -c           # 只装证书，不改 DNS
#        w.sh tp.client.sh -d           # 只改 DNS，不装证书
#        w.sh tp.client.sh -s           # 查看当前接入状态
#        w.sh tp.client.sh -r           # 回滚（恢复 DNS、移除证书）
#        w.sh tp.client.sh --server <IP>   # 指定 TProxy 服务器
#
#  为什么无参数不直接执行:
#        本脚本会被下载到几十个节点上执行，误触即改动生产配置。
#        故要求显式给出动作，缺参数时只打印帮助、不碰任何文件。
#
#  它做什么:
#    1. 下载根证书（tp/tproxy-ca.crt）并装入信任库
#    2. 把 DNS 指向 TProxy 服务器
#    3. 自检
#
#  接入后无需修改任何仓库/镜像配置 —— Docker、dnf/yum、pip、npm、mvn
#  都会经 DNS 劫持自动命中 192.168.0.18 上的缓存。
#
#  DNS 序列（顺序即优先级，串行查询）:
#    192.168.0.18      代理，命中缓存
#    223.5.5.5         公网兜底（代理不可用时仍能上网）
#    119.29.29.29      第二兜底，换厂商避免同一家整体故障
#  ⚠️ 不含 202.99.192.68 —— 运营商 DNS 存在劫持/污染，实测不可信
#
#  ⚠️ 必须关闭 systemd-resolved（Ubuntu 默认启用）:
#    它会【并行】查询多个 DNS 取最快返回，公网结果会抢在代理之前，
#    使劫持彻底失效。glibc resolver 才是串行的。
#
#  证书的三处安装（系统信任库覆盖不到全部工具）:
#    系统库     dnf/apt/curl/pip/npm 读它
#    Docker     daemon 用自有信任库，须放到 /etc/docker/certs.d/<域名>/ca.crt
#    Java       JDK 自带 cacerts，须 keytool 导入
#    运行时     conda 等自带 CA bundle，不读系统库
#
#  幂等: 重复执行安全。DNS 一致则不重写、证书已装则不重复导入。
#        首次的原始 DNS 配置备份在 /var/backups/tproxy-client/，
#        重复执行【不会】覆盖它（否则回滚会恢复出仍指向代理的配置）。
#
#  依赖: wget（下载证书）、openssl（校验与自检）、dig（自检）
#        不依赖 wget.sh —— 直接用系统 wget 取文件
#  版本号：每次修改递增，10 进位
# ============================================================
VERSION="0.1.8"
set -uo pipefail

source /opt/grigs/bas.sh 2>/dev/null || {
    print_step()    { echo -e "\n>>> $1"; }
    print_info()    { echo "  [INFO] $1"; }
    print_success() { echo "  [OK] $1"; }
    print_warning() { echo "  [WARN] $1"; }
    print_error()   { echo "  [ERROR] $1" >&2; }
    check_root()    { [[ $EUID -eq 0 ]] || { echo "[ERROR] 此操作需要管理员权限" >&2; exit 1; }; }
}

# ---------- 配置 ----------
TPROXY_SERVER="192.168.0.18"
DNS_FALLBACK=("223.5.5.5" "119.29.29.29")
CA_NAME="tproxy-ca.crt"
CA_REMOTE="tp/${CA_NAME}"
CA_LOCAL="/opt/grigs/tp/${CA_NAME}"
BACKUP_DIR="/var/backups/tproxy-client"
BACKUP_ORIGINAL="${BACKUP_DIR}/resolv.conf.original"

SERVERS=("http://192.168.0.79" "http://10.10.10.79")

# Docker 客户端不读系统 CA 库，必须按域名逐个放置
DOCKER_CERT_DOMAINS=(
    registry-1.docker.io auth.docker.io production.cloudflare.docker.com
    quay.io gcr.io ghcr.io k8s.gcr.io registry.k8s.io mcr.microsoft.com
    nvcr.io
)

# TProxy 会劫持的域名。用于自检核对，以及检查 /etc/hosts 有没有把它们钉在公网 IP 上。
# ⚠️ 要与服务端 dnsmasq.conf 的 address= 规则保持一致。
HIJACK_DOMAINS=(
    repo.openeuler.org mirrors.openeuler.org
    registry-1.docker.io auth.docker.io nvcr.io
    pypi.org files.pythonhosted.org
    registry.npmjs.org
    repo1.maven.org
    github.com
)

BACKUP_HOSTS="${BACKUP_DIR}/hosts.original"

# ---------- 直连模式（应急）----------
#
# 用途：.18 不可用时，把劫持域名钉到**源站**，机器照常上网。
# 不这么做的话，每次 DNS 查询都要先等 .18 超时（resolv.conf 里配的 2 秒）
# 才会落到公网 DNS —— 能通，但每个请求都慢一拍。
#
# ⚠️ 应急手段，不是长期配置：这些 IP 属于 CDN / 云厂商，会变
#    （实测 github.com 的 A 记录几个月内就换过）。而且钉住之后
#    那几个域名就**再也不走缓存**了，恢复正常后请及时 --no-bypass。
#
# 数据来源：2026-09-23 用两个公网 DNS（223.5.5.5 / 119.29.29.29）实测，
# 两者结果一致，并与线上资料交叉核对。github.com 给两个 IP：
# 140.82.116.3 是 GitHub 自有网络（西雅图），20.205.243.166 走 Azure 新加坡 ——
# 后者在境内延迟更好，且实测已稳定服务两年。
DIRECT_HOSTS=(
    "49.0.229.41        repo.openeuler.org"
    "49.0.230.196       mirrors.openeuler.org"
    "100.30.41.220      registry-1.docker.io"
    "104.18.43.178      auth.docker.io"
    "151.101.0.223      pypi.org"
    "151.101.0.223      files.pythonhosted.org"
    "104.16.0.34        registry.npmjs.org"
    "104.18.18.12       repo1.maven.org"
    "140.82.116.3       github.com"
    "20.205.243.166     github.com"
)

# 成对标记：撤销时按标记整体摘掉，不会误伤手工加的记录
BYPASS_BEGIN="# >>> TProxy 直连模式（应急，--no-bypass 撤销）"
BYPASS_END="# <<< TProxy 直连模式"

bypass_active() {
    grep -qF "$BYPASS_BEGIN" "${1:-/etc/hosts}" 2>/dev/null
}

# 开启直连模式。幂等：已开启则重写这一块（便于更新 IP）。
bypass_on() {
    local f="${1:-/etc/hosts}" entry
    bypass_off "$f"                       # 先摘掉旧的，避免叠加

    {
        printf '\n%s\n' "$BYPASS_BEGIN"
        for entry in "${DIRECT_HOSTS[@]}"; do
            printf '%s\n' "$entry"
        done
        printf '%s\n' "$BYPASS_END"
    } >> "$f" || return 1
    return 0
}

# 撤销直连模式。没有开启时一个字节都不动。
bypass_off() {
    local f="${1:-/etc/hosts}" tmp
    grep -qF "$BYPASS_BEGIN" "$f" 2>/dev/null || return 0

    tmp=$(mktemp) || return 1
    if ! awk -v b="$BYPASS_BEGIN" -v e="$BYPASS_END" '
          index($0, b) { skip = 1; next }
          index($0, e) { skip = 0; next }
          !skip { print }
        ' "$f" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    # 用 cat 覆盖而非 mv：保住原文件的属主与 inode
    cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# ---------- Docker daemon 配置 ----------
DOCKER_DAEMON_JSON="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"

# 判断：列出已配置的 registry-mirrors，每行一个。只读。
docker_conf_mirrors() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
ms = d.get("registry-mirrors")
if isinstance(ms, list):
    for m in ms:
        print(m)
PY
}

# 读取 data-root 的值。**只用于报告，任何情况下都不修改它。**
#
# 为什么专门列出来：它逐机不同，且改它会让 Docker 换个根目录去找数据 ——
# 现有容器与镜像会全部「消失」（数据没丢，但 Docker 看不见），
# 要恢复得把数据搬过去。所以这个键必须「看见但不碰」。
docker_conf_data_root() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = d.get("data-root")
if isinstance(v, str):
    print(v)
PY
}

# daemon.json 是否合法 JSON。非法返回 1。
docker_conf_valid() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$f" 2>/dev/null
}

# 标准 daemon.json 的键值（data-root 除外 —— 它只保留、不设定）
DOCKER_STD_LOG_DRIVER="json-file"
DOCKER_STD_LOG_OPTS='{"max-size": "50m", "max-file": "5"}'
DOCKER_STD_EXEC_OPTS='["native.cgroupdriver=systemd"]'
DOCKER_STD_STORAGE_DRIVER="overlay2"

# 标准之外的键。标准化时**原样保留**，只列出来告知用户。
# 早先的版本会把这些替换掉 —— 那删掉过 ai02 的 runtimes.nvidia，
# 会让 GPU 容器不可用。功能键不能按"统一配置"处理。
docker_conf_extra_keys() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
keep = {"data-root", "registry-mirrors",
        "log-driver", "log-opts", "exec-opts", "storage-driver"}
for k in d:
    if k not in keep:
        print(k)
PY
}

# 读出 storage-driver 的现值。只读。
docker_conf_storage_driver() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = d.get("storage-driver")
if isinstance(v, str):
    print(v)
PY
}

# 现在是否已经就是标准配置（data-root 与异值 storage-driver 不计）。
# 用于「先判断」—— 已经是标准就不该重写文件，那是无谓的 churn。
docker_conf_is_standard() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  docker_conf_valid "$f" || return 1
  [[ -z "$(docker_conf_mirrors "$f")" ]] || return 1
  [[ -z "$(docker_conf_extra_keys "$f")" ]] || return 1

  local drv
  drv=$(docker_conf_storage_driver "$f")
  [[ -z "$drv" || "$drv" == "$DOCKER_STD_STORAGE_DRIVER" ]] || return 1

  STDD_LOG="$DOCKER_STD_LOG_DRIVER" \
  STDD_LOGO="$DOCKER_STD_LOG_OPTS" \
  STDD_EXECO="$DOCKER_STD_EXEC_OPTS" \
  python3 - "$f" <<'PY' 2>/dev/null
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
ok = (d.get("log-driver") == os.environ["STDD_LOG"]
      and d.get("log-opts") == json.loads(os.environ["STDD_LOGO"])
      and d.get("exec-opts") == json.loads(os.environ["STDD_EXECO"]))
sys.exit(0 if ok else 1)
PY
}

# 标准化：保留 data-root，其余键写成标准值。
#
# ⚠️ storage-driver 是**条件保留**的：它与 data-root 同类 ——
#    改了会让 Docker 去别的地方找镜像层，现有镜像与容器会全部「消失」。
#    所以本机已是别的驱动时，保留原值不改（由调用方告警）。
#
# **先判断**：文件不存在或 JSON 非法时不动手。
# **宁可不改也不能写坏**：写坏 daemon.json 会让 Docker 起不来。
docker_conf_normalize() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  docker_conf_valid "$f" || return 3
  command -v python3 >/dev/null 2>&1 || return 2

  local tmp rc
  tmp=$(mktemp) || return 1

  STDD_LOG="$DOCKER_STD_LOG_DRIVER" \
  STDD_LOGO="$DOCKER_STD_LOG_OPTS" \
  STDD_EXECO="$DOCKER_STD_EXEC_OPTS" \
  STDD_DRV="$DOCKER_STD_STORAGE_DRIVER" \
  python3 - "$f" >"$tmp" 2>/dev/null <<'PY'
import json, os, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    old = json.load(fh)

# ⚠️ 从原配置**原样保留**开始，只动该动的。
#
# 不能"清空后只写标准键"：daemon.json 里的键分两类 ——
# 一类是风格（日志格式、cgroup 驱动），标准化它们有意义；
# 另一类是**功能**（runtimes / dns / bip / insecure-registries / data-root …），
# 它们是逐机配的，删掉就是故障。
# 实测代价：在一台 AI 机器（ai02）上照「其余替换成标准」执行，
# 把 runtimes.nvidia 删掉了 —— 那台机器的 GPU 容器会直接不可用。
new = dict(old)
new.pop("registry-mirrors", None)   # 只删它：会让 Docker Hub 拉取绕过本地缓存

new["log-driver"] = os.environ["STDD_LOG"]
new["log-opts"] = json.loads(os.environ["STDD_LOGO"])
new["exec-opts"] = json.loads(os.environ["STDD_EXECO"])

# storage-driver 条件保留：本机已是别的驱动就别改，改了镜像会「消失」
cur = old.get("storage-driver")
drv = os.environ["STDD_DRV"]
new["storage-driver"] = cur if (isinstance(cur, str) and cur != drv) else drv

print(json.dumps(new, indent=2, ensure_ascii=False))
PY
  rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"; return 1
  fi
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi

  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/daemon.json.original"
  if [[ ! -f "$bk" ]]; then
    mkdir -p "$(dirname "$bk")" 2>/dev/null || true
    cp -a "$f" "$bk" 2>/dev/null || true
  fi
  cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# 去掉 registry-mirrors，其余键原样保留。
#
# **先判断**：没有该项时一个字节都不动。
# **宁可不改也不能写坏**：JSON 非法、或 python3 不可用时直接失败返回，
# 绝不尝试用 sed 之类的文本手段去「修」JSON —— 写坏了 Docker 起不来，
# 那是比「缓存没命中」严重得多的故障。
docker_conf_strip_mirrors() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  # 先判合法性：非法 JSON 会让 Docker 起不来，本身就是要报出来的问题。
  # 放在「有没有 mirrors」之前 —— 否则解析失败返回空，会被误当成
  # 「没有 mirrors、无需处理」而静默通过。
  docker_conf_valid "$f" || return 3
  [[ -n "$(docker_conf_mirrors "$f")" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 2

  local tmp rc
  tmp=$(mktemp) || return 1

  # 用 python3 而不是 sed/awk：JSON 不是面向行的，
  # 文本手段处理嵌套结构迟早出错，而写坏 daemon.json 会让 Docker 起不来
  python3 - "$f" >"$tmp" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
d.pop("registry-mirrors", None)
print(json.dumps(d, indent=2, ensure_ascii=False))
PY
  rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"; return 1
  fi
  # 再校验一次产物 —— 宁可不动，也不能把坏文件写进去
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  # 先备份（只备第一次），再用 cat 覆盖 —— 保住原文件的属主与 inode
  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/daemon.json.original"
  if [[ ! -f "$bk" ]]; then
    mkdir -p "$(dirname "$bk")" 2>/dev/null || true
    cp -a "$f" "$bk" 2>/dev/null || true
  fi
  cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# 检查 Docker daemon 配置。**先判断再动手**。
check_docker_conf() {
    local f="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"

    if [[ ! -f "$f" ]]; then
        print_info "  未发现 %s（Docker 用默认配置，Docker Hub 拉取走本地缓存）" "$f"
        return 0
    fi

    # data-root：读出来报告，但任何情况下都不改 ——
    # 改它 Docker 会换个根目录找数据，现有容器与镜像会全部「消失」
    local dr
    dr=$(docker_conf_data_root "$f")
    if [[ -n "$dr" ]]; then
        print_info "  data-root: %s（保留，不改）" "$dr"
    fi

    if ! docker_conf_valid "$f"; then
        print_error "  %s 不是合法 JSON —— Docker 会起不来，请先修好它" "$f"
        return 1
    fi

    # 已经是标准配置就不动文件（先判断）
    if docker_conf_is_standard "$f"; then
        print_success "  已是标准配置"
        return 0
    fi

    # 会被替换掉的非标准键：先报出来，配置无声消失最难查
    local extra k
    extra=$(docker_conf_extra_keys "$f")
    if [[ -n "$extra" ]]; then
        print_info "  以下非标准键原样保留（只做标准化，不动功能键）："
        while read -r k; do
            [[ -n "$k" ]] && print_info "    %s" "$k"
        done <<< "$extra"
    fi

    # storage-driver 与 data-root 同类：改了镜像会「消失」，故异值时保留
    local drv
    drv=$(docker_conf_storage_driver "$f")
    if [[ -n "$drv" && "$drv" != "overlay2" ]]; then
        print_warning "  本机 storage-driver 是 %s，保留不改（改了现有镜像会「消失」）" "$drv"
    fi

    if [[ -n "$(docker_conf_mirrors "$f")" ]]; then
        print_warning "  registry-mirrors 会让 Docker Hub 拉取【绕过本地缓存】，将被移除"
    fi

    if docker_conf_normalize "$f"; then
        print_success "  已标准化（原文件备份在 %s）" "${BACKUP_DIR}/daemon.json.original"
        print_warning "  需重启 Docker 才生效: systemctl restart docker"
    else
        print_warning "  标准化失败，原文件未改动"
        return 1
    fi
    return 0
}

# ---------- 系统源与 git 重定向的修复 ----------

APT_SOURCES_LIST="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
APT_SOURCES_D="${APT_SOURCES_D:-/etc/apt/sources.list.d}"
PROXMOX_KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"

# 已下线的代理路径特征。含 IP 通配，因为旧配置里 .18 与 .36 都出现过。
_DEAD_PROXY_RE='repository/debian-proxy'

# 判断：列出仍然指向已下线代理路径的 apt 源行。只读。
dead_proxy_sources() {
  local f="${1:-$APT_SOURCES_LIST}"
  [[ -f "$f" ]] || return 0
  # 只看未注释的行 —— 注释掉的历史配置不该被算作问题
  grep -vE '^[[:space:]]*#' "$f" 2>/dev/null | grep -F "$_DEAD_PROXY_RE"
}

# PVE 9 的 Proxmox 无订阅源（deb822）。$1 = 发行版 codename
pve_sources_content() {
  local codename="${1:-trixie}"
  cat <<EOF
# Proxmox VE 9 —— 无订阅源（由 tp.client.sh 生成）
#
# PVE 9 基于 Debian 13 (trixie)，故 codename 用 trixie 而非 bookworm。
# 这是官方推荐的 deb822 格式；旧的单行 .list 格式在 PVE 9 上已不推荐。
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${codename}
Components: pve-no-subscription
Signed-By: ${PROXMOX_KEYRING}
EOF
}

# PVE 9 的 Ceph 无订阅源（deb822）。$1 = codename
ceph_sources_content() {
  local codename="${1:-trixie}"
  cat <<EOF
# Ceph（Proxmox 提供）—— 无订阅源（由 tp.client.sh 生成）
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: ${codename}
Components: no-subscription
Signed-By: ${PROXMOX_KEYRING}
EOF
}

# 判断：文件里出现了 codename，但与实际系统不符。$1=文件 $2=实际codename
codename_mismatch() {
  local f="$1" want="$2"
  [[ -f "$f" ]] || return 1
  # 只在未被注释的行里找常见的 Debian codename
  local found
  found=$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null \
          | grep -oE '\b(bookworm|trixie|bullseye|buster|jammy|noble|focal)\b' \
          | sort -u)
  [[ -z "$found" ]] && return 1
  # 只要出现了一个不等于实际的 codename，就算不符
  local c
  while read -r c; do
    [[ -n "$c" && "$c" != "$want" ]] && return 0
  done <<< "$found"
  return 1
}

# ---- openEuler / dnf（rpm 系）----

# 是否 rpm 系（dnf/yum）。Debian 系不走这套。
is_rpm_like() {
  [[ -r /etc/os-release ]] && grep -qiE '^(ID|ID_LIKE)=.*(rhel|fedora|centos|openeuler|anolis|kylin)' /etc/os-release
}

# 判断：哪些 .repo 文件里还有 metalink=。
#
# 为什么它有害（不只是「多一次请求」）：metalink 返回的是**镜像地址列表**，
# dnf 会自己挑一个去下载 —— 挑到不在 TProxy 劫持列表里的镜像，
# 流量就**直接绕过缓存**了，与这套架构的目的相反。
# baseurl 指向官方域名，已被劫持，稳定走缓存。
#
# 实测：某台机器因为 metalink 地址写错（repo=/OS 少写了发行版名），
# 上游一律回 404，被 dnf-makecache.timer 每小时刷 168 次，
# 把缓存命中率从 70% 压到 31% —— 看起来像缓存坏了，实际毫无问题。
dnf_metalink_sources() {
  local d="${1:-/etc/yum.repos.d}"
  grep -rlE '^[[:space:]]*metalink[[:space:]]*=' "$d" --include='*.repo' 2>/dev/null
}

# 判断：哪些 .repo 文件里开着 debuginfo / source / update-source。
# 这些源普通机器用不到，元数据却不小 —— openEuler 官方默认也是关的。
dnf_redundant_repos() {
  local d="${1:-/etc/yum.repos.d}" f
  for f in "$d"/*.repo; do
    [[ -f "$f" ]] || continue
    # 必须**按段判断** enabled：整个文件里找 enabled=1 会误报 ——
    # [OS] 段也有 enabled=1，于是修完 debuginfo 仍然报「仍启用」。
    awk '
      /^\[/ { sec = $0; gsub(/[][]/, "", sec) }
      /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*1/ {
        if (sec == "debuginfo" || sec == "source" || sec == "update-source") {
          print FILENAME; exit
        }
      }
    ' "$f"
  done
}

# 修复 dnf 源：去掉 metalink、关掉冗余源。**先判断再动手**。
repair_dnf_repos() {
  local d="${1:-/etc/yum.repos.d}"
  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/yum.repos.d"
  local did=0 f

  while read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p "$bk" 2>/dev/null || true
    cp -a "$f" "$bk/$(basename "$f").$(date +%s)" 2>/dev/null || true
    local tmp
    tmp=$(mktemp) || continue
    # **只删「本段有 baseurl」的 metalink 行**。
    # 删 metalink 的前提是 baseurl 能兜底 —— 某段若只有 metalink 没有 baseurl，
    # 删了等于把该仓库彻底去掉。两遍扫描以兼容 baseurl 写在 metalink 之后的情况。
    awk '
      NR == FNR {
        if ($0 ~ /^\[/) { sec = $0; gsub(/[][]/, "", sec) }
        if ($0 ~ /^[ \t]*baseurl[ \t]*=/) has_base[sec] = 1
        next
      }
      /^\[/ { sec = $0; gsub(/[][]/, "", sec) }
      /^[ \t]*metalink[ \t]*=/ {
        if (has_base[sec]) next          # 有 baseurl 兜底 → 删掉 metalink
      }
      { print }
    ' "$f" "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
    did=1
  done < <(dnf_metalink_sources "$d")

  while read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p "$bk" 2>/dev/null || true
    cp -a "$f" "$bk/$(basename "$f").$(date +%s)" 2>/dev/null || true
    # 把 debuginfo / source / update-source 三段的 enabled 改成 0
    local tmp
    tmp=$(mktemp) || continue
    awk '
      /^\[(debuginfo|source|update-source)\]/ { insec = 1; print; next }
      /^\[/ { insec = 0 }
      insec && /^[[:space:]]*enabled[[:space:]]*=/ { print "enabled=0"; next }
      { print }
    ' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
    did=1
  done < <(dnf_redundant_repos "$d")

  [[ $did -eq 1 ]]
}

# 判断：启用中的企业版源（需付费订阅）。
#
# PVE 9 全新安装**默认启用** enterprise.proxmox.com。没有订阅密钥时
# apt update 返回 401，Proxmox 组件就**静默冻结**在安装 ISO 的版本上 ——
# Debian 基础源仍正常，所以安全更新照常，问题极难察觉。
# 非订阅环境必须把它们禁掉，改用 pve-no-subscription。
# 只列启用中的；已挪进 backup/ 或标了 Enabled: no 的不算。
enterprise_sources() {
  local d="${1:-$APT_SOURCES_D}"
  grep -rlE 'enterprise\.proxmox\.com' "$d" 2>/dev/null | grep -v '/backup/'
}

# 禁用企业版源：移进 backup（可逆），不删除。
# 用「移走」而不是「注释掉」：apt 的 deb822 格式没有注释行，
# 而整文件移走最干净、也最容易恢复（拿到订阅后挪回来即可）。
disable_enterprise_sources() {
  local d="${1:-$APT_SOURCES_D}"
  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/apt"
  local files
  files=$(enterprise_sources "$d")
  [[ -n "$files" ]] || return 0

  mkdir -p "$bk" 2>/dev/null || true
  local f n=0
  while read -r f; do
    [[ -n "$f" ]] || continue
    mv "$f" "$bk/$(basename "$f").$(date +%s)" 2>/dev/null && n=$((n + 1))
  done <<< "$files"
  [[ $n -gt 0 ]]
}

# 本机 Debian codename（如 trixie）。非 Debian 系返回空。
detect_codename() {
  local c=""
  [[ -r /etc/os-release ]] && c=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')
  [[ -n "$c" ]] && { echo "$c"; return 0; }
  command -v lsb_release >/dev/null 2>&1 && lsb_release -sc 2>/dev/null
}

# 判断：sources.list 里哪些行的 suite 已由 .sources 文件提供 —— 即重复配置。
#
# 为什么它是要修的：apt 会对每条重复的源发 W: 告警，并且**同一份元数据被拉两遍**
# （走代理，但白费一轮）。PVE 9 的官方布局是 debian.sources 负责 Debian 基础源、
# sources.list 清空 —— ve.client.sh 恰恰相反，往 sources.list 塞了一份完整的。
#
# 只列**非注释**且 suite 确实被 .sources 覆盖的行；backports 这类没被覆盖的会保留。
duplicate_suite_lines() {
  local f="${1:-$APT_SOURCES_LIST}" d="${2:-$APT_SOURCES_D}" line suite
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*deb ]] || continue
    suite=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^https?:\/\//) { print $(i+1); exit } }' <<< "$line")
    _suite_provided_by_sources "$suite" "$d" && printf '%s\n' "$line"
  done < "$f"
}

# 某个发行版 suite 是否已由 .sources（deb822）文件提供。
# 用于判断一条死源行是「改成别的地址」还是「直接删掉」。
_suite_provided_by_sources() {
  local suite="$1" d="${2:-$APT_SOURCES_D}" f
  [[ -n "$suite" ]] || return 1
  for f in "$d"/*.sources; do
    [[ -f "$f" ]] || continue
    grep -qE "^[[:space:]]*Suites:.*(^|[[:space:]])${suite}([[:space:]]|$)" "$f" 2>/dev/null && return 0
  done
  return 1
}

# 修复一行死源：
#   · 它声明的 suite 已被 .sources 提供 → **删除该行**（本来就重复，改地址只会
#     造成「同一源配置多次」，apt 会告警且元数据被拉两遍）
#   · 否则 → 把已下线的代理地址换成 deb.debian.org（仍在服务、且会被劫持）
_repair_dead_proxy_line() {
  local line="$1" d="$2" suite
  # 单行格式：deb [选项] URI suite 组件…  —— suite 是第 3 个字段
  suite=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^https?:\/\//) { print $(i+1); exit } }' <<< "$line")
  if _suite_provided_by_sources "$suite" "$d"; then
    return 0                      # 不输出 → 该行被删掉
  fi
  sed -E 's#https?://[0-9.]+/repository/debian-proxy/?#http://deb.debian.org/debian/#g' <<< "$line"
}

# 修复 apt 源。返回 0=无需或已修好，1=失败
#
# 分两步，各自独立判断：
#   ① /etc/apt/sources.list 里的死源行 → 换成 deb.debian.org
#   ② PVE 源若是旧 .list 格式或 codename 不符 → 按 PVE 9 官方 deb822 重建
repair_apt_sources() {
  local list="${1:-$APT_SOURCES_LIST}"
  local d="${2:-$APT_SOURCES_D}"
  local codename="${3:-$(detect_codename)}"
  local did=0

  # ① 死源 与 重复配置
  # 判据是「有死源**或**有与 .sources 重复的行」——
  # 只按死源判断的话，修完死源之后若还剩重复行（比如别人本来就配了
  # 一份与 debian.sources 重叠的），就再也不会被清理了。
  if [[ -f "$list" ]] && { [[ -n "$(dead_proxy_sources "$list")" ]] \
        || [[ -n "$(duplicate_suite_lines "$list" "$d")" ]]; }; then
    local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/apt"
    mkdir -p "$bk" 2>/dev/null || true
    cp -a "$list" "$bk/sources.list.$(date +%s)" 2>/dev/null || true
    local tmp line suite
    tmp=$(mktemp) || return 1
    : > "$tmp"
    while IFS= read -r line; do
      suite=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^https?:\/\//) { print $(i+1); exit } }' <<< "$line")
      if [[ "$line" =~ $_DEAD_PROXY_RE ]] || _suite_provided_by_sources "$suite" "$d"; then
        # 死源、或与 .sources 重复 → 交给 _repair_dead_proxy_line 决定是删还是改
        _repair_dead_proxy_line "$line" "$d" >> "$tmp" || { rm -f "$tmp"; return 1; }
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$list"
    cat "$tmp" > "$list" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    did=1
  fi

  # ② PVE 源：旧 .list 或 codename 不符 → 按官方 deb822 重建
  local legacy="$d/pve-no-subscription.list"
  if [[ -f "$legacy" ]] && { codename_mismatch "$legacy" "$codename" \
        || grep -q "^deb " "$legacy" 2>/dev/null; }; then
    local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/apt"
    mkdir -p "$bk" 2>/dev/null || true
    mv "$legacy" "$bk/pve-no-subscription.list.$(date +%s)" 2>/dev/null || true
    pve_sources_content "$codename" > "$d/proxmox.sources" || return 1
    # Ceph 源若原本存在（无论在 .list 还是 .sources），一并按 trixie 重建
    if [[ -f "$d/ceph.list" ]] || [[ -f "$d/ceph.sources" ]]; then
      [[ -f "$d/ceph.list" ]] && mv "$d/ceph.list" "$bk/ceph.list.$(date +%s)" 2>/dev/null || true
      ceph_sources_content "$codename" > "$d/ceph.sources" || return 1
    fi
    did=1
  fi

  [[ $did -eq 1 ]] && return 0
  return 0
}

# 去掉指向非缓存地址的 git 全局重定向。$1=gitconfig 路径（默认全局）
remove_git_redirects() {
  local f="${1:-$HOME/.gitconfig}"
  [[ -f "$f" ]] || return 0
  local lines
  lines=$(git_redirects "$f")
  [[ -n "$lines" ]] || return 0

  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/gitconfig.original"
  if [[ ! -f "$bk" ]]; then
    mkdir -p "$(dirname "$bk")" 2>/dev/null || true
    cp -a "$f" "$bk" 2>/dev/null || true
  fi

  # 用 git 自己的命令去掉，而不是改文件 —— 避免写坏 gitconfig
  local src dst
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    src="${line%% -> *}"; dst="${line##* -> }"
    git config --global --unset "url.${dst}.insteadOf" "$src" 2>/dev/null || true
  done <<< "$lines"

  # 清理只剩空节的 url.<dst> 段
  while IFS= read -r line; do
    dst="${line##* -> }"
    git config --global --remove-section "url.${dst}" 2>/dev/null || true
  done <<< "$lines"
  return 0
}

# 判断：git 全局配置里的 url.*.insteadOf 重定向。只读。
# 输出形如：<insteadOf 的源> -> <重定向到的地址>
git_redirects() {
  local f="${1:-$HOME/.gitconfig}"
  [[ -f "$f" ]] || return 0
  awk '
    /^\[url / {
      # [url "http://gitea.local:3000/"]
      match($0, /"[^"]*"/)
      dst = substr($0, RSTART + 1, RLENGTH - 2)
      next
    }
    /insteadOf/ {
      sub(/^[ \t]*insteadOf[ \t]*=[ \t]*/, "")
      if (dst != "") print $0 " -> " dst
    }
  ' "$f"
}


# 是否 Debian 系（apt）。openEuler/rpm 系不走 apt 那套。
is_debian_like() {
    [[ -r /etc/os-release ]] && grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release
}

# 检查系统源与 git 重定向。**先判断再动手**。
check_system_repo() {
    # ---- apt 源（仅 Debian 系）----
    if is_debian_like; then
        local dead cn legacy l
        dead=$(dead_proxy_sources)
        cn=$(detect_codename)
        legacy="/etc/apt/sources.list.d/pve-no-subscription.list"

        if [[ -n "$dead" ]]; then
            print_warning "  apt 源指向已下线的代理路径（旧 Nexus），apt update 会失败："
            while read -r l; do
                [[ -n "$l" ]] && print_info "    %s" "$l"
            done <<< "$dead"
        fi
        if [[ -f "$legacy" ]] && codename_mismatch "$legacy" "$cn"; then
            print_warning "  PVE 源 codename 与实际系统不符（本机是 %s）——" "$cn"
            print_info "    PVE 9 基于 Debian 13，应为 trixie，且用 deb822 .sources 格式"
        fi
        # 企业源：非订阅环境会 401，且表现为「Proxmox 组件静默冻结在 ISO 版本」
        local ent
        ent=$(enterprise_sources)
        if [[ -n "$ent" ]]; then
            print_warning "  启用了企业版源（需付费订阅），非订阅下 apt update 会 401："
            local e
            while read -r e; do [[ -n "$e" ]] && print_info "    %s" "$e"; done <<< "$ent"
            if disable_enterprise_sources; then
                print_success "  已禁用（移进 backup，拿到订阅后挪回来即可）"
            else
                print_warning "  禁用失败，请手工移走上述文件"
            fi
        fi

        # 重复配置也要报：apt 会对每条重复源发 W:，且元数据被拉两遍
        local dup
        dup=$(duplicate_suite_lines)
        if [[ -n "$dup" ]]; then
            print_warning "  sources.list 有 %s 行与 .sources 重复（apt 会告警、元数据拉两遍）：" \
                "$(grep -c . <<< "$dup")"
            while read -r l; do
                [[ -n "$l" ]] && print_info "    %s" "$l"
            done <<< "$dup"
        fi

        if [[ -n "$dead" || -n "$dup" ]] \
           || { [[ -f "$legacy" ]] && codename_mismatch "$legacy" "$cn"; }; then
            if repair_apt_sources; then
                print_success "  已修复（原文件备份在 %s/apt/）" "$BACKUP_DIR"
            else
                print_warning "  自动修复失败，请手工检查 /etc/apt/sources.list"
                return 1
            fi
        else
            print_success "  apt 源正常"
        fi
    fi

    # ---- dnf 源（仅 rpm 系）----
    if is_rpm_like; then
        local m r f
        m=$(dnf_metalink_sources)
        r=$(dnf_redundant_repos)
        if [[ -n "$m" ]]; then
            print_warning "  dnf 源里有 metalink —— 它返回的是镜像地址列表、由 dnf 自己挑，"
            print_info "    挑到不在劫持列表里的镜像就【绕过缓存】了："
            while read -r f; do
                [[ -n "$f" ]] && print_info "    %s" "$f"
            done <<< "$m"
        fi
        if [[ -n "$r" ]]; then
            print_warning "  debuginfo / source / update-source 是启用的（普通机器用不到，官方默认也是关的）："
            while read -r f; do
                [[ -n "$f" ]] && print_info "    %s" "$f"
            done <<< "$r"
        fi
        if [[ -n "$m" || -n "$r" ]]; then
            if repair_dnf_repos; then
                print_success "  已修复（备份在 %s/yum.repos.d/）" "$BACKUP_DIR"
            else
                print_warning "  自动修复失败，请手工检查 /etc/yum.repos.d/"
            fi
        else
            print_success "  dnf 源正常"
        fi
    fi

    # ---- git 重定向（各发行版都可能存在）----
    local red r
    red=$(git_redirects)
    if [[ -n "$red" ]]; then
        print_warning "  git 全局配置把请求重定向到了别处，会绕过缓存："
        while read -r r; do
            [[ -n "$r" ]] && print_info "    %s" "$r"
        done <<< "$red"
        if remove_git_redirects; then
            print_success "  已移除（原配置备份在 %s/gitconfig.original）" "$BACKUP_DIR"
        else
            print_warning "  移除失败，请手工执行 git config --global --unset …"
        fi
    fi
    return 0
}

# ---------- /etc/hosts 覆盖检查 ----------
#
# 为什么必须查：/etc/nsswitch.conf 里 `hosts: files dns ...` —— **files 排在 dns 之前**，
# 所以 /etc/hosts 里的一条记录会稳稳压过 TProxy 的 DNS 劫持。
# 而自检用的 `dig` 绕过 NSS（直接问 nameserver），永远看不到它 ——
# 表现为「自检全绿、劫持其实完全没生效」，真实程序直连公网。
# 本项目已经踩过两次（.18 服务端、.19 客户端），两次都报的绿灯。

# 判断：列出被钉死的劫持域名。只读，不改任何东西。
# 报的是【被破坏的劫持域名】而非文件里的每条主机名 —— 用户关心的是
# 「哪个域名的劫持失效了」。子域（www.github.com）归到所属域名名下，
# 因为 dnsmasq 的 address=/github.com/ 同样覆盖 *.github.com。
hosts_pinned_domains() {
    local f="${1:-/etc/hosts}" d
    [[ -f "$f" ]] || return 0
    for d in "${HIJACK_DOMAINS[@]}"; do
        awk -v want="$d" '
            # 子域判定必须用「后缀相等」，不能用 index(...) == 长度差 ——
            # 后者在两串**等长**时会得到 0 == 0 而误判
            # （registry.npmjs.org 与 repo.openeuler.org 同为 18 字符）。
            function is_sub(host, d) {
                return host == d || substr(host, length(host) - length(d)) == "." d
            }
            { sub(/#.*/, "") }
            NF >= 2 {
                for (i = 2; i <= NF; i++) if (is_sub($i, want)) { print want; exit }
            }
        ' "$f"
    done
}

# 修正：删掉 /etc/hosts 里钉死劫持域名的行。
# **先判断** —— 一行都没命中时一个字节都不动（那是人家有意配的就别碰，
# 比如 raw.githubusercontent.com 常被手工钉住以绕开访问问题，它不在劫持列表里）。
hosts_unpin() {
    local f="${1:-/etc/hosts}" pinned
    pinned=$(hosts_pinned_domains "$f")
    [[ -n "$pinned" ]] || return 0

    if [[ ! -f "$BACKUP_HOSTS" ]]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || true
        cp -a "$f" "$BACKUP_HOSTS" 2>/dev/null || true
    fi

    local tmp
    tmp=$(mktemp) || return 1
    if ! awk -v domains="${HIJACK_DOMAINS[*]}" '
          BEGIN { ndoms = split(domains, doms, " ") }
          function is_sub(host, d) {
              return host == d || substr(host, length(host) - length(d)) == "." d
          }
          {
              line = $0
              sub(/#.*/, "", line)
              n = split(line, a, /[ \t]+/)
              drop = 0
              for (i = 2; i <= n && !drop; i++)
                  for (j = 1; j <= ndoms; j++)
                      if (is_sub(a[i], doms[j])) { drop = 1; break }
              if (!drop) print $0
          }
        ' "$f" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    # 用 cat 覆盖而非 mv：保住原文件的属主与 inode
    cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# 检查并（在确有覆盖时）修正 /etc/hosts。
check_hosts() {
    # 直连模式是「我们自己写的 hosts 覆盖」，先整体摘掉再走常规流程 ——
    # 否则 hosts_unpin 会留下孤零零的一对标记注释。
    if bypass_active; then
        print_warning "/etc/hosts 处于【直连模式】（应急用），将改回走代理"
        bypass_off /etc/hosts && print_success "  已撤销直连模式"
        print_info "  若 .18 仍未恢复，请稍后重跑: w.sh tp.client.sh --bypass"
    fi

    local pinned
    pinned=$(hosts_pinned_domains /etc/hosts)

    if [[ -z "$pinned" ]]; then
        print_success "/etc/hosts 没有覆盖劫持域名"
        return 0
    fi

    print_warning "/etc/hosts 钉死了这些域名，DNS 劫持对它们完全失效："
    local d
    while read -r d; do
        [[ -n "$d" ]] && print_info "  %s" "$d"
    done <<< "$pinned"
    print_info "原因：nsswitch 里 files 排在 dns 之前，/etc/hosts 压过 DNS"

    if hosts_unpin /etc/hosts; then
        print_success "已移除这些记录（原文件备份在 %s）" "$BACKUP_HOSTS"
    else
        print_warning "自动移除失败，请手工删除上述域名在 /etc/hosts 里的记录"
        return 1
    fi
    # 清掉本地 DNS 缓存，避免仍解析到旧结果
    command -v nscd >/dev/null 2>&1 && nscd -i hosts >/dev/null 2>&1 || true
    return 0
}

# ---------- 帮助 ----------
show_help() {
    # 帮助只说「能打什么、打了会怎样」。
    #
    # 不要去打印文件头那段注释：它是给维护者看的取舍说明
    # （为什么无参数不执行、DNS 序列为什么是这三个、systemd-resolved 为什么要关、
    # 证书要装四处……）。混进来会把 10 行用法变成 57 行说明，
    # 而用户要找的那个参数就淹在里面。
    cat <<EOF
tp.client.sh v${VERSION} —— 把本机接入 TProxy 透明缓存

用法: w.sh tp.client.sh <选项>

  -i, --install     接入本机（配置 DNS + 安装根证书）
  -c, --cert-only   只装证书，不改 DNS
  -d, --dns-only    只改 DNS，不装证书
  -s, --status      查看当前接入状态
  -r, --remove      回滚（恢复 DNS、移除证书）
  -b, --bypass      直连模式：劫持域名走源站（.18 不可用时应急）
      --no-bypass   取消直连模式，恢复走代理
      --server <IP> 指定 TProxy 服务器（默认 ${TPROXY_SERVER}）
  -h, --help        显示本帮助

无参数只显示本帮助，不改动任何配置。

接入后无需修改任何仓库 / 镜像配置 —— Docker、dnf/yum、pip、npm、mvn
都会经 DNS 劫持自动命中代理上的缓存。
EOF
}

# ---------- 参数 ----------
# 无参数时只显示帮助，不执行任何改动 ——
# 这类脚本会在几十个节点上被下载执行，误触即改动生产配置，
# 故要求显式给出动作。
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--install)   ACTION="install"; shift ;;
        -c|--cert-only) ACTION="cert"; shift ;;
        -d|--dns-only)  ACTION="dns"; shift ;;
        -s|--status)    ACTION="status"; shift ;;
        -r|--remove)    ACTION="remove"; shift ;;
        -b|--bypass)    ACTION="bypass"; shift ;;
        --no-bypass)    ACTION="unbypass"; shift ;;
        --server)       TPROXY_SERVER="${2:-}"; shift 2 ;;
        -h|--help)      show_help; exit 0 ;;
        *)              print_error "未知参数: %s（用 -h 查看用法）" "$1"; exit 1 ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    show_help
    exit 0
fi

# ---------- 依赖保障 ----------
# 本脚本只需 wget（下载证书）与 dig（自检）。
# 两者都不是所有镜像都预装，故缺了就装，装不上则明确报错而不是中途失败。

# dig 的包名因发行版而异：rpm 系属 bind-utils，deb 系属 dnsutils。
# 写死 bind-utils 会让 Ubuntu 节点静默装不上 —— 自检的 DNS 检查随之被跳过，
# 而那条检查正是发现「劫持没生效」的唯一手段。
dig_package() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "dnsutils"
    else
        echo "bind-utils"
    fi
}

ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    command -v "$cmd" >/dev/null 2>&1 && return 0

    print_warning "未安装 %s，尝试安装" "$cmd"
    if command -v ins_dnf >/dev/null 2>&1; then
        # 仓库标准做法：bas.sh 的 ins_dnf 带进度与双语输出
        ins_dnf "$pkg" >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg" >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg" >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y "$pkg" >/dev/null 2>&1 || true
    fi

    if command -v "$cmd" >/dev/null 2>&1; then
        print_success "%s 已安装" "$cmd"
        return 0
    fi
    print_error "%s 安装失败，请手工安装后重试" "$cmd"
    return 1
}

# ---------- 工具 ----------
dns_server_list() {
    printf '%s\n' "$TPROXY_SERVER"
    printf '%s\n' "${DNS_FALLBACK[@]}"
}

detect_dns_manager() {
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "systemd-resolved"
    elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "networkmanager"
    else
        echo "unknown"
    fi
}

# 从发布服务器取文件 —— 直接用系统 wget，不经过 wget.sh。
# wget.sh 会先拉 bas.sh/up.sh 等一串引导文件再转发，对「只下一个证书」
# 来说层层套娃；系统 wget 一步到位，且不依赖 /opt/grigs 是否已初始化。
# 仅在 wget 不存在时才退回 curl（极简镜像可能没装 wget）。
fetch_file() {
    local remote="$1" local_path="$2"
    mkdir -p "$(dirname "$local_path")"

    local server
    if command -v wget >/dev/null 2>&1; then
        for server in "${SERVERS[@]}"; do
            if wget -q --timeout=10 -O "$local_path" "${server}/sxiad/grigs/${remote}" 2>/dev/null \
               && [[ -s "$local_path" ]]; then
                return 0
            fi
        done
        return 1
    fi

    print_warning "未安装 wget，回退 curl"
    for server in "${SERVERS[@]}"; do
        if curl -sSf --connect-timeout 5 "${server}/sxiad/grigs/${remote}" -o "$local_path" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ---------- DNS ----------
render_resolv_conf() {
    echo "# TProxy 客户端配置 —— 由 tp.client.sh 生成"
    echo "# 顺序即优先级：串行查询，代理优先，其后为公网兜底"
    dns_server_list | while read -r s; do echo "nameserver $s"; done
    # 缩短单次超时：代理不可用时快速切兜底，而不是卡默认 5 秒
    echo "options timeout:2 attempts:1"
}

# 只备份【第一次】的原始配置，重复执行不覆盖。
# 否则第二次会用「上一次的 TProxy 配置」覆盖真正的原始配置，
# 导致 --remove 恢复出一个仍指向代理的文件（回滚等于没做）。
backup_dns() {
    mkdir -p "$BACKUP_DIR"
    if [[ ! -f "$BACKUP_ORIGINAL" ]]; then
        # cp -aL 解引用符号链接：Ubuntu 上 /etc/resolv.conf 通常是指向
        # /run/systemd/resolve/stub-resolv.conf 的链接，-a 会备份链接本身，
        # 而我们随后会删掉它，回滚时就得到一个死链接。
        cp -aL /etc/resolv.conf "$BACKUP_ORIGINAL" 2>/dev/null || true
    fi
}

disable_systemd_resolved() {
    systemctl disable --now systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    : > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
}

# NetworkManager 会在连接重启、DHCP 续约时重写 /etc/resolv.conf，
# 仅写文件不持久，必须同时写进连接配置。
configure_dns_networkmanager() {
    local conn
    conn=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
           | grep -v ':lo$' | head -1 | cut -d: -f1)
    [[ -z "$conn" ]] && return 1
    local dns_join
    dns_join=$(dns_server_list | paste -sd' ')
    if nmcli con mod "$conn" ipv4.dns "$dns_join" ipv4.ignore-auto-dns yes >/dev/null 2>&1; then
        print_info "已写入 NetworkManager 连接 '%s'" "$conn"
        nmcli con up "$conn" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

install_dns() {
    print_step "配置 DNS"
    backup_dns

    local mgr
    mgr=$(detect_dns_manager)
    print_info "检测到 DNS 机制: %s" "$mgr"

    # 幂等：内容已一致就跳过
    local want
    want=$(render_resolv_conf)
    if [[ -f /etc/resolv.conf ]] && [[ "$(cat /etc/resolv.conf)" == "$want" ]]; then
        print_success "DNS 已是目标配置，跳过"
    else
        case "$mgr" in
            systemd-resolved)
                # 关闭它，否则配置会被覆盖，且并行查询会让劫持失效
                disable_systemd_resolved
                render_resolv_conf > /etc/resolv.conf
                print_success "已关闭 systemd-resolved 并写入 /etc/resolv.conf"
                ;;
            networkmanager)
                render_resolv_conf > /etc/resolv.conf
                configure_dns_networkmanager || print_warning "nmcli 配置失败，仅写入 /etc/resolv.conf"
                print_success "已写入 /etc/resolv.conf"
                ;;
            *)
                render_resolv_conf > /etc/resolv.conf
                print_success "已写入 /etc/resolv.conf"
                ;;
        esac
    fi

    # 清本地 DNS 缓存，避免改了配置仍解析到旧结果
    command -v nscd >/dev/null 2>&1 && nscd -i hosts >/dev/null 2>&1 || true
    print_info "DNS 序列: %s" "$(dns_server_list | paste -sd' ')"

    # 配好 DNS 还不够：/etc/hosts 里的记录会把它整个压过去。
    # 必须在这里检查 —— 否则这台机器看起来接入成功，实际劫持一个都没生效。
    print_info "/etc/hosts 覆盖检查"
    check_hosts || true
}

# ---------- 证书 ----------
install_system_ca() {
    local cert="$1"
    if [[ -f /etc/os-release ]] && grep -qiE '^(ID|ID_LIKE)=.*(ubuntu|debian)' /etc/os-release; then
        install -m 644 "$cert" "/usr/local/share/ca-certificates/${CA_NAME}"
        update-ca-certificates 2>&1 | tail -1
    elif [[ -f /etc/os-release ]] && grep -qiE '^(ID|ID_LIKE)=.*(rhel|fedora|centos|openeuler)' /etc/os-release; then
        install -m 644 "$cert" "/etc/pki/ca-trust/source/anchors/${CA_NAME}"
        update-ca-trust extract
    else
        print_warning "未识别的发行版，跳过系统信任库"
        return 1
    fi
    print_success "系统信任库已更新"
}

install_docker_ca() {
    local cert="$1"
    [[ -d /etc/docker ]] || { print_info "未安装 docker，跳过"; return 0; }
    local d
    for d in "${DOCKER_CERT_DOMAINS[@]}"; do
        install -d -m 755 "/etc/docker/certs.d/${d}"
        install -m 644 "$cert" "/etc/docker/certs.d/${d}/ca.crt"
    done
    print_success "Docker 证书目录已写入（${#DOCKER_CERT_DOMAINS[@]} 个域名）"
    print_warning "需重启 docker 才生效: systemctl restart docker"
}

install_java_ca() {
    local cert="$1"
    local keystores=()
    local found
    while read -r found; do
        [[ -z "$found" ]] && continue
        keystores+=("$found")
    # ⚠️ 排除容器镜像层目录（*/overlay2/*）。Docker 的 data-root 在 /opt 下时
  # （实测 ai02 是 /opt/docker），`find /opt` 会扫进容器自己的 JDK ——
  # 改它们既无意义，又在动别人的镜像层。
  done < <(find /usr/lib/jvm /opt -name cacerts -path '*security*' \
             -not -path '*/overlay2/*' 2>/dev/null)

    if [[ ${#keystores[@]} -eq 0 ]]; then
        print_info "未找到 JDK cacerts，跳过"
        return 0
    fi
    local ks
    for ks in "${keystores[@]}"; do
        # 先删再导入：alias 已存在时 keytool 会拒绝，
        # 那会让 CA 轮换后重跑时 Java 库永远停留在旧证书
        keytool -delete -alias tproxy-ca -keystore "$ks" -storepass changeit >/dev/null 2>&1 || true
        if keytool -importcert -noprompt -trustcacerts -alias tproxy-ca \
             -file "$cert" -keystore "$ks" -storepass changeit >/dev/null 2>&1; then
            print_success "Java cacerts: %s" "$ks"
        else
            print_warning "Java cacerts 导入失败: %s" "$ks"
        fi
    done
}

# conda 等运行时自带 CA bundle，不读系统信任库。
# 若不处理，表现为「/usr/bin/curl 正常、conda 的 curl 报 unknown CA」。
RUNTIME_MARK="# TProxy Root CA"
runtime_bundles() {
    local p
    for p in /opt/conda*/ssl/cacert.pem /opt/miniconda*/ssl/cacert.pem \
             /opt/anaconda*/ssl/cacert.pem \
             /home/*/miniconda*/ssl/cacert.pem /home/*/anaconda*/ssl/cacert.pem \
             /root/miniconda*/ssl/cacert.pem /root/anaconda*/ssl/cacert.pem; do
        [[ -f "$p" ]] && printf '%s\n' "$p"
    done
}

# 追加标记**带上证书指纹**。
# 只写固定字串的话，根 CA 一换就会误判「已装过」而跳过 —— 客户端继续拿着
# 旧根，而 conda 读的是自己的 ssl/cacert.pem、不读系统信任库，
# 表现为「换根后 conda/pip 连不上」，完全看不出是信任锚没换。
_runtime_mark_for() {
    local cert="$1" fp
    fp=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null \
         | sed 's/.*=//; s/://g')
    printf '%s %s' "$RUNTIME_MARK" "${fp:-unknown}"
}

# 确保 bundle 对普通用户可读。
# conda / pip 常以普通用户身份运行；bundle 若只剩 root 可读，
# 它们连自己的 CA 包都打不开，curl 只报 exit 77，
# 信息里完全看不出是权限问题。
# ⚠️ 不能用 [[ -r ]] 判断 —— 本脚本以 root 运行，root 永远读得到。
_runtime_make_readable() {
    local f="$1" mode
    mode=$(stat -c '%a' "$f" 2>/dev/null || echo "")
    [[ -n "$mode" ]] || return 0
    if (( (8#$mode & 8#004) == 0 )); then
        chmod 644 "$f" 2>/dev/null || true
    fi
    return 0
}

# 去掉此前追加的 TProxy 块（标记行起、到文件末尾）。没有则原样返回。
_runtime_strip() {
    local f="$1" tmp
    grep -qF "$RUNTIME_MARK" "$f" 2>/dev/null || return 0
    tmp=$(mktemp) || return 1
    if ! awk -v mark="$RUNTIME_MARK" 'index($0, mark) { exit } { print }' "$f" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    # 用 cat 覆盖而不是 mv：保留原文件的属主与 inode。
    # 这些 bundle 常在 root 独占的目录里，mv 会把属主换掉。
    cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

install_runtime_ca() {
    local cert="$1"
    local mark
    mark=$(_runtime_mark_for "$cert")
    local n=0 seen=0 f
    while read -r f; do
        [[ -z "$f" ]] && continue
        seen=$((seen + 1))
        if grep -qF "$mark" "$f" 2>/dev/null; then
            # 内容已是最新，但权限未必对。这条分支必须先修权限再跳过：
            # 一台机器只要曾经对过一次，之后每次跑都走到这里，
            # 不修的话它永远好不了。
            _runtime_make_readable "$f"
            print_info "已是最新，跳过: %s" "$f"
        elif ! _runtime_strip "$f"; then
            print_warning "处理失败，跳过（请手工检查）: %s" "$f"
        else
            { printf '\n%s\n' "$mark"; cat "$cert"; } >> "$f"
            _runtime_make_readable "$f"
            print_success "已更新 %s" "$f"
            n=$((n + 1))
        fi
    done < <(runtime_bundles)
    # 区分「本机没有这类运行时」与「有但已是最新」—— 前者跳过正常，后者是幂等命中
    if [[ $seen -eq 0 ]]; then
        print_info "未发现自带 CA bundle 的运行时，跳过"
    fi
}

remove_runtime_ca() {
    local f
    while read -r f; do
        [[ -z "$f" ]] && continue
        grep -qF "$RUNTIME_MARK" "$f" 2>/dev/null || continue
        # 标记行之后即为追加内容，截断即可（不误伤用户原有证书）
        _runtime_strip "$f" || { print_warning "处理失败，跳过: %s" "$f"; continue; }
        print_success "已从 %s 移除" "$f"
    done < <(runtime_bundles)
}

# 远端证书指纹（不发请求体，只取 1.9KB 的证书本身）
remote_fingerprint() {
    local remote="$1" server fp
    for server in "${SERVERS[@]}"; do
        fp=$(wget -q -O - --timeout=10 "${server}/sxiad/grigs/${remote}" 2>/dev/null \
             | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
        if [[ -n "$fp" ]]; then
            echo "$fp"
            return 0
        fi
    done
    return 1
}

local_fingerprint() {
    [[ -s "$1" ]] || return 1
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null
}

install_cert() {
    print_step "安装根证书"

    local need_download=0
    if [[ ! -s "$CA_LOCAL" ]]; then
        print_info "本地无证书，下载 %s" "$CA_REMOTE"
        need_download=1
    else
        # 比对指纹，而不是只看「本地有没有文件」。
        # 只判断存在性的话，服务端 CA 轮换后客户端会一直用旧证书 ——
        # 表现为 HTTPS 全线 unknown CA，且必须先手工 rm 掉本地证书才能恢复。
        # CA 轮换通常只在私钥泄露时发生，那正是最需要一键铺开的时刻。
        local rfp="" lfp=""
        rfp=$(remote_fingerprint "$CA_REMOTE") || rfp=""
        lfp=$(local_fingerprint "$CA_LOCAL") || lfp=""

        if [[ -z "$rfp" ]]; then
            # 服务器不可达不该让接入失败 —— 沿用本地证书
            print_warning "无法获取远端证书（服务器不可达？），沿用本地证书"
        elif [[ "$rfp" != "$lfp" ]]; then
            print_warning "服务端证书已变更，更新中"
            need_download=1
        else
            print_success "证书已是最新"
        fi
    fi

    if [[ $need_download -eq 1 ]]; then
        if ! fetch_file "$CA_REMOTE" "$CA_LOCAL"; then
            print_error "证书下载失败（%s）" "$CA_REMOTE"
            return 1
        fi
    fi
    if ! openssl x509 -in "$CA_LOCAL" -noout -subject >/dev/null 2>&1; then
        print_error "下载的不是合法证书: %s" "$CA_LOCAL"
        return 1
    fi
    # curl 落盘默认 600；证书是公开材料，且要供其他用户/服务读取
    chmod 644 "$CA_LOCAL" 2>/dev/null || true
    print_info "证书: %s" "$(openssl x509 -in "$CA_LOCAL" -noout -subject | sed 's/subject=//')"

    install_system_ca "$CA_LOCAL"
    install_docker_ca "$CA_LOCAL"
    install_java_ca "$CA_LOCAL"
    install_runtime_ca "$CA_LOCAL"
}

# ---------- 自检 ----------
do_verify() {
    print_step "自检"
    local fail=0 d ip

    if ! command -v dig >/dev/null 2>&1; then
        print_warning "未安装 dig，跳过 DNS 解析检查（可 ins_dnf bind-utils 后重跑 --status）"
        return 0
    fi

    print_info "DNS 解析（应指向 %s）" "$TPROXY_SERVER"
    for d in "${HIJACK_DOMAINS[@]}"; do
        ip=$(dig +time=3 +tries=1 +short "$d" 2>/dev/null | grep -E '^[0-9]' | head -1)
        if [[ "$ip" == "$TPROXY_SERVER" ]]; then
            print_success "  %s -> %s" "$d" "$ip"
        else
            print_warning "  %s -> %s（期望 %s）" "$d" "${ip:-解析失败}" "$TPROXY_SERVER"
            fail=1
        fi
    done

    # dig 绕过 NSS，所以上面那轮全绿**不代表真实程序走对了路**：
    # /etc/hosts 会压过 DNS，而 dig 看不到它。这条检查就是为了补上这个盲区。
    print_info "真实解析路径（经 NSS，含 /etc/hosts）"
    local pin
    pin=$(hosts_pinned_domains /etc/hosts)
    if [[ -z "$pin" ]]; then
        print_success "  无覆盖，真实程序与 dig 结果一致"
    else
        print_warning "  仍被 /etc/hosts 钉死：%s" "$(tr '\n' ' ' <<<"$pin")"
        print_warning "  真实程序会直连公网，劫持对这些域名完全没生效"
        fail=1
    fi

    # 公网兜底：必须【直查】备用 DNS，绕开位于首位的代理 ——
    # 这才是「代理宕机时能否上网」的验证
    print_info "公网兜底（直查备用 DNS）"
    local ok=0 b
    for b in "${DNS_FALLBACK[@]}"; do
        if dig +time=2 +tries=1 +short "@${b}" www.baidu.com 2>/dev/null | grep -qE '^[0-9]'; then
            print_success "  %s 可用" "$b"
            ok=1
            break
        fi
        print_warning "  %s 无响应" "$b"
    done
    [[ $ok -eq 0 ]] && { print_error "所有备用 DNS 均不可达 —— 代理宕机时将断网"; fail=1; }

    # 证书：用装了 CA 的工具去连代理，验证 TLS 能过
    print_info "证书链"
    if curl -s -o /dev/null --max-time 15 "https://repo.openeuler.org/" 2>/dev/null; then
        print_success "  HTTPS 校验通过"
    else
        print_warning "  HTTPS 校验失败（根证书未生效？）"
        fail=1
    fi

    if [[ $fail -eq 0 ]]; then
        print_success "自检通过"
    else
        print_warning "自检有未通过项，见上"
    fi
}

show_status() {
    print_step "TProxy 接入状态"
    print_info "目标服务器: %s" "$TPROXY_SERVER"
    echo
    print_info "/etc/resolv.conf:"
    [[ -f /etc/resolv.conf ]] && sed 's/^/    /' /etc/resolv.conf || echo "    (不存在)"
    echo
    print_info "DNS 机制: %s" "$(detect_dns_manager)"
    echo
    # 只看不改：状态查询不该动系统文件
    if is_debian_like; then
        if [[ -n "$(dead_proxy_sources)" ]]; then
            print_warning "apt 源指向已下线的代理路径（%s 行）—— apt update 会失败" "$(dead_proxy_sources | wc -l)"
            print_info "  重新接入可自动修复: w.sh tp.client.sh -i"
        fi
        if [[ -n "$(enterprise_sources)" ]]; then
            print_warning "启用了企业版源（需订阅）—— 非订阅下 apt update 会 401，且 Proxmox 组件会静默冻结"
            print_info "  重新接入可自动禁用: w.sh tp.client.sh -i"
        fi
        _pve=/etc/apt/sources.list.d/pve-no-subscription.list
        _cn=$(detect_codename)
        if [[ -f "$_pve" ]] && codename_mismatch "$_pve" "$_cn"; then
            print_warning "PVE 源 codename 与实际系统不符（本机 %s）—— PVE 9 应为 trixie" "$_cn"
            print_info "  重新接入可自动修复: w.sh tp.client.sh -i"
        fi
    fi
    if is_rpm_like && [[ -n "$(dnf_metalink_sources)" ]]; then
        print_warning "dnf 源里有 metalink —— 会让拉取绕过缓存（%s 个文件）" "$(dnf_metalink_sources | wc -l)"
        print_info "  重新接入可自动修复: w.sh tp.client.sh -i"
    fi
    if [[ -n "$(git_redirects)" ]]; then
        print_warning "git 配置把请求重定向到了别处（绕过缓存）"
        print_info "  重新接入可自动移除: w.sh tp.client.sh -i"
    fi
    if [[ -f "${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}" ]]; then
        local _m _dr
        _dr=$(docker_conf_data_root)
        [[ -n "$_dr" ]] && print_info "Docker data-root: %s" "$_dr"
        _m=$(docker_conf_mirrors)
        if [[ -n "$_m" ]]; then
            print_warning "Docker 配了 registry-mirrors（%s 个）—— Docker Hub 拉取绕过本地缓存" "$(grep -c . <<<"$_m")"
            print_info "  重新接入可自动移除: w.sh tp.client.sh -i"
        fi
    fi

    local pin
    if bypass_active; then
        # 直连模式本身就是「我们有意写的 hosts 覆盖」，
        # 不必再报一次「钉死了劫持域名」—— 那是同一件事
        print_warning "/etc/hosts: 处于【直连模式】—— 这些域名当前不走缓存"
        print_info "  撤销: w.sh tp.client.sh --no-bypass"
    else
        pin=$(hosts_pinned_domains /etc/hosts)
        if [[ -z "$pin" ]]; then
            print_info "/etc/hosts: 未覆盖劫持域名"
        else
            print_warning "/etc/hosts 钉死了这些劫持域名（劫持对其无效）：%s" "$(tr '\n' ' ' <<<"$pin")"
            print_info "重新接入可自动修复: w.sh tp.client.sh -i"
        fi
    fi
    echo
    print_info "根证书:"
    if [[ -s "$CA_LOCAL" ]]; then
        print_success "  %s" "$(openssl x509 -in "$CA_LOCAL" -noout -subject 2>/dev/null | sed 's/subject=//')"
    else
        print_warning "  未下载（%s 不存在）" "$CA_LOCAL"
    fi
    if [[ -f "/etc/pki/ca-trust/source/anchors/${CA_NAME}" ]] || \
       [[ -f "/usr/local/share/ca-certificates/${CA_NAME}" ]]; then
        print_success "  已装入系统信任库"
    else
        print_warning "  未装入系统信任库"
    fi
    echo
    print_info "Docker 证书目录: %s 个" "$(ls -d /etc/docker/certs.d/*/ 2>/dev/null | wc -l)"
}

do_remove() {
    print_step "回滚 TProxy 接入"

    # ⚠️ 必须先撤销 NetworkManager 连接里的 DNS 设置，再恢复文件。
    # 顺序反了的话，NM 会在恢复文件后立刻用连接配置把它重写回去 ——
    # 表现为「提示已恢复，实际 DNS 没变」，回滚等于没做。
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        local conn
        conn=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
               | grep -v ':lo$' | head -1 | cut -d: -f1)
        if [[ -n "$conn" ]]; then
            nmcli con mod "$conn" ipv4.dns "" ipv4.ignore-auto-dns no >/dev/null 2>&1 || true
            nmcli con up "$conn" >/dev/null 2>&1 || true
            print_success "已撤销 NetworkManager 连接 '%s' 的 DNS 设置" "$conn"
        fi
    fi

    if [[ -f "$BACKUP_ORIGINAL" ]]; then
        rm -f /etc/resolv.conf
        cp -aL "$BACKUP_ORIGINAL" /etc/resolv.conf
        print_success "已恢复原始 DNS 配置"
        print_info "  当前: %s" "$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | paste -sd' ')"
    else
        print_warning "未找到原始配置备份，请手动检查 /etc/resolv.conf"
    fi

    rm -f "/usr/local/share/ca-certificates/${CA_NAME}" \
          "/etc/pki/ca-trust/source/anchors/${CA_NAME}"
    command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates --fresh >/dev/null 2>&1 || true
    command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract 2>/dev/null || true
    print_success "已从系统信任库移除"

    # 只删我们装的那些域名 —— 不能通配删除整个 certs.d，
    # 那会连带删掉用户为自己的私有 registry 配置的 CA
    local d
    for d in "${DOCKER_CERT_DOMAINS[@]}"; do
        rm -f "/etc/docker/certs.d/${d}/ca.crt" 2>/dev/null
        rmdir "/etc/docker/certs.d/${d}" 2>/dev/null || true
    done
    print_success "已移除 TProxy 的 Docker 证书"

    remove_runtime_ca

    echo
    print_warning "以下需手动处理:"
    print_info "  Java: keytool -delete -alias tproxy-ca -keystore <JDK>/lib/security/cacerts"
    print_info "  systemd-resolved 若原为启用: systemctl enable --now systemd-resolved"
}

# ====================== 执行入口 ======================
print_color "绿" "### tp.client.sh v${VERSION} ###"

case "$ACTION" in
    status)
        show_status
        ;;
    remove)
        check_root
        do_remove
        ;;
    dns)
        check_root
        ensure_cmd dig "$(dig_package)" || print_warning "缺少 dig，自检的 DNS 部分会跳过"
        install_dns
        do_verify
        ;;
    cert)
        # 只装证书：用于「DNS 已由其他方式配好，只要证书」的场景
        check_root
        ensure_cmd wget || exit 1
        install_cert
        print_info "仅安装了证书，DNS 未改动（如需改 DNS 用 -d）"
        ;;
    install)
        check_root
        # 先保证依赖齐备，避免中途才失败
        ensure_cmd wget || exit 1
        ensure_cmd dig "$(dig_package)" || print_warning "缺少 dig，自检的 DNS 部分会跳过"
        print_step "检查系统源与 git 重定向"
        check_system_repo || true
        print_step "检查 Docker 配置"
        check_docker_conf || true
        install_dns
        install_cert
        do_verify
        echo
        print_success "接入完成。Docker 需重启才生效: systemctl restart docker"
        print_info "回滚: w.sh tp.client.sh -r"
        ;;
    bypass)
        # 应急：.18 不可用时让劫持域名直连源站，不必每次等 DNS 超时
        check_root
        print_step "开启直连模式"
        if ! bypass_on /etc/hosts; then
            print_error "写入 /etc/hosts 失败"
            exit 1
        fi
        print_success "已把 ${#DIRECT_HOSTS[@]} 条源站记录写入 /etc/hosts"
        command -v nscd >/dev/null 2>&1 && nscd -i hosts >/dev/null 2>&1 || true
        print_warning "这些域名从此【不再走缓存】，直连源站"
        print_info "恢复正常后请撤销: w.sh tp.client.sh --no-bypass"
        print_info "（重新接入 -i 也会自动撤销直连模式）"
        ;;
    unbypass)
        check_root
        print_step "关闭直连模式"
        if [[ ! -f /etc/hosts ]] || ! bypass_active; then
            print_info "当前未开启直连模式，无需处理"
            exit 0
        fi
        if bypass_off /etc/hosts; then
            print_success "已撤销，劫持域名重新走代理"
            command -v nscd >/dev/null 2>&1 && nscd -i hosts >/dev/null 2>&1 || true
        else
            print_error "撤销失败，请手工删除 /etc/hosts 里「TProxy 直连模式」那一段"
            exit 1
        fi
        ;;
esac
