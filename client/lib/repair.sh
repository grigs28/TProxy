#!/usr/bin/env bash
# client/lib/repair.sh —— 修复别的脚本留下的、会让机器不可用的配置
#
# 为什么需要：PAID 机器（PVE 9 / Debian 13）跑过 ve/ve.client.sh，
# 它留下了三类问题，而且**都不会当场报错**，只在之后某个时刻以
# 「apt update 失败」「git 连不上」的形式暴露：
#
#   1. apt 源指向 http://<cacheIP>/repository/debian-proxy/
#      —— 旧 Nexus 的路径，架构重建时已下线（实测 .18 与 .36 都是 000）
#   2. 把已经正确的 PVE 9 源（deb822 + trixie）挪进 backup，
#      换成旧单行 .list + bookworm codename —— 而 PVE 9 基于 trixie
#   3. /etc/hosts 覆盖（由 hosts 检查负责，见 lib/dns.sh）
#
# 另有 git 全局 insteadOf 把 github.com 重定向到别处，同样绕过缓存。
#
# 依据：Proxmox 官方 Package Repositories 文档 —— PVE 9 用 deb822
# `.sources` 格式，Debian 基础源由 debian.sources 提供，
# 旧的 /etc/apt/sources.list 应清空。

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

# 本机 Debian codename（如 trixie）。非 Debian 系返回空。
detect_codename() {
  local c=""
  [[ -r /etc/os-release ]] && c=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')
  [[ -n "$c" ]] && { echo "$c"; return 0; }
  command -v lsb_release >/dev/null 2>&1 && lsb_release -sc 2>/dev/null
}

# 已下线的代理路径 → 换成仍在服务、且会被 TProxy 劫持的官方地址。
# 只改主机与路径，suite 与组件原样保留。
_rewrite_dead_proxy_line() {
  sed -E 's#https?://[0-9.]+/repository/debian-proxy/?#http://deb.debian.org/debian/#g'
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

  # ① 死源
  if [[ -f "$list" ]] && [[ -n "$(dead_proxy_sources "$list")" ]]; then
    local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/apt"
    mkdir -p "$bk" 2>/dev/null || true
    cp -a "$list" "$bk/sources.list.$(date +%s)" 2>/dev/null || true
    local tmp
    tmp=$(mktemp) || return 1
    _rewrite_dead_proxy_line < "$list" > "$tmp" || { rm -f "$tmp"; return 1; }
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
