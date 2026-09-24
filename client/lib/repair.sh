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

# 已下线的 **Nexus** 路径特征：内网 IP（可选端口）+ `/repository/`。
#
# 旧架构把仓库挂成 `http://<cacheIP>[:8081]/repository/<名>/`，Nexus 下线后
# 这些 URL 一律不可达。原来只认 `repository/debian-proxy` 这一条（apt 侧的
# 历史配置），**dnf 侧的漏网** —— 实测 `.16` 的 nexus-openeuler.repo 挂着
# `repository/openEuler-24.03-OS/` 等三条，`dnf makecache` 直接
# `Curl error (7): Couldn't connect to server ... port 8081`，
# 而脚本还在报「正常」。
#
# ⚠️ 判据必须含【内网 IP】这一条：公网镜像站也有 `/repository/` 路径
#    （如 mirrors.aliyun.com/repository/openeuler/），不能误判。
_DEAD_NEXUS_RE='https?://[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+(:[0-9]+)?/repository/'

# 判断：哪些 .repo 文件里有**启用中**的死 Nexus 仓库。只读。
# 与 dnf_metalink_sources 同样的两条约束：不递归进 backup/，只看启用中的段。
dead_nexus_repos() {
  local d="${1:-/etc/yum.repos.d}" f
  for f in "$d"/*.repo; do
    [[ -f "$f" ]] || continue
    awk -v RE="$_DEAD_NEXUS_RE" '
      /^\[/ { sec = $0; gsub(/[][]/, "", sec); next }
      /^[[:space:]]*enabled[[:space:]]*=/ {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v)
        off[sec] = (v == "0" || v == "false" || v == "no")
        next
      }
      /^[[:space:]]*baseurl[[:space:]]*=/ { if ($0 ~ RE) has[sec] = 1 }
      END { for (s in has) if (!off[s]) { print FILENAME; exit } }
    ' "$f"
  done
}

# 停用死 Nexus 仓库所在的**段**（不是删段）。返回 0=改过。
#
# 为什么是「停用」而不是「删段」：删了不可逆，而这个文件里往往还混着
# **正常**的仓库段（实测 .16 的 nexus-openeuler.repo 就是死段 + 正常段混排），
# 按段停用最不容易误伤。停用后 dnf 不再尝试它，报错即消失。
disable_dead_nexus_repos() {
  local d="${1:-/etc/yum.repos.d}" f did=0
  while read -r f; do
    [[ -n "$f" ]] || continue
    local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/yum.repos.d"
    mkdir -p "$bk" 2>/dev/null || true
    cp -a "$f" "$bk/$(basename "$f").$(date +%s)" 2>/dev/null || true
    local tmp
    tmp=$(mktemp) || continue
    # 两遍扫描：先标出「该段有死 Nexus baseurl」，再逐段改写。
    # enabled 可能写在 baseurl 之前，所以必须先标后改。
    # 段里若原本**没有** enabled 行，要在段末补一行 —— 否则 dnf 默认是启用的。
    awk -v RE="$_DEAD_NEXUS_RE" '
      NR == FNR {
        if ($0 ~ /^\[/) { sec = $0; gsub(/[][]/, "", sec) }
        else if ($0 ~ /^[ \t]*baseurl[ \t]*=/) { if ($0 ~ RE) dead[sec] = 1 }
        next
      }
      /^\[/ {
        if (sec != "" && dead[sec] && !saw_en) print "enabled=0"
        sec = $0; gsub(/[][]/, "", sec); saw_en = 0
        print; next
      }
      dead[sec] && /^[ \t]*enabled[ \t]*=/ { print "enabled=0"; saw_en = 1; next }
      /^[ \t]*enabled[ \t]*=/ { saw_en = 1 }
      { print }
      END { if (sec != "" && dead[sec] && !saw_en) print "enabled=0" }
    ' "$f" "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
    did=1
  done < <(dead_nexus_repos "$d")
  [[ $did -eq 1 ]]
}

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
  local d="${1:-/etc/yum.repos.d}" f
  # ⚠️ 两个约束，都是真机踩出来的（.9 / CentOS 7）：
  #
  # ① **只在顶层找，不递归**。原来是 `grep -r ... "$d"`，于是
  #    /etc/yum.repos.d/backup/ 里的**备份**也被算进来。备份 dnf 根本不读，
  #    报它是误报；更糟的是 repair_dnf_repos 会照单去"修" ——
  #    实测把备份里未注释 baseurl 段的 `metalink=` 行**删掉了**，
  #    备份就此还原不回去，失去存在意义。
  # ② **只看启用中的段**。整段 enabled=0 的 repo（如 epel-testing.repo）
  #    dnf 压根不会读，报它只是噪音。enabled 缺省视为启用（dnf 的默认）。
  for f in "$d"/*.repo; do
    [[ -f "$f" ]] || continue
    awk '
      /^\[/ { sec = $0; gsub(/[][]/, "", sec); next }
      /^[[:space:]]*enabled[[:space:]]*=/ {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v)
        off[sec] = (v == "0" || v == "false" || v == "no")
        next
      }
      /^[[:space:]]*metalink[[:space:]]*=/ { has[sec] = 1 }
      END { for (s in has) if (!off[s]) { print FILENAME; exit } }
    ' "$f"
  done
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

  # 死 Nexus 仓库：按段停用（做完这个，dnf 才不会再报 Curl error）
  disable_dead_nexus_repos "$d" && did=1

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

# 判断：`/etc/apt/sources.list.d/` 下哪些文件提供了 **PVE 无订阅源**。
#
# 两种格式都算：deb822（`URIs: http://download.proxmox.com/debian/pve` +
# `Components: pve-no-subscription`）与单行（`deb … pve-no-subscription`）。
# 文件名不作数 —— 实测有 `pve.list` / `pve-no-subscription.sources` /
# `proxmox.sources` 三种叫法，只按文件名找必然漏。
#
# 双重匹配（仓库 URL **且** pve-no-subscription）以排除 `pve-ceph.sources`
# 那类「同一个 Proxmox、另一个仓库」的文件。
pve_source_files() {
  local d="${1:-$APT_SOURCES_D}" f
  for f in "$d"/*.sources "$d"/*.list; do
    [[ -f "$f" ]] || continue
    grep -qE 'download[.]proxmox[.]com/debian/pve' "$f" 2>/dev/null || continue
    grep -qE 'pve-no-subscription' "$f" 2>/dev/null || continue
    printf '%s\n' "$f"
  done
}

# 判断：PVE 无订阅源**是否需要规范化**（多于一份 / codename 不符 / 还是单行 .list）。
#
# ⚠️ 这个函数存在的意义是**从结构上消灭一类反复犯的错**：
# 「报出来了」和「判据里有没有」是两处独立的代码，加检测项时容易只改前者 ——
# 症状是「报了问题、却说正常、修复压根没跑、下次再报」。本项目已经犯过四次
# （apt 漏「重复」、dnf 漏「metalink」、dnf 漏「死 Nexus」、apt 漏「PVE 源重复」）。
# 所以现在**报告方与修复方共用这一个判据**，不存在「忘了同步」的可能。
pve_needs_repair() {
  local d="${1:-$APT_SOURCES_D}" codename="${2:-$(detect_codename)}"
  local pv n=0 need=0 f
  pv=$(pve_source_files "$d")
  [[ -n "$pv" ]] && n=$(grep -c . <<<"$pv")
  (( n > 1 )) && need=1
  while read -r f; do
    [[ -n "$f" ]] || continue
    codename_mismatch "$f" "$codename" && need=1
    grep -q "^deb " "$f" 2>/dev/null && need=1   # 单行 .list 格式
  done <<< "$pv"
  [[ $need -eq 1 ]]
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

  # ② PVE 无订阅源：保证**只剩一份**定义。
  #
  # ⚠️ 原逻辑只认 `pve-no-subscription.list` 这一个**文件名**，而且
  # **不看是否已有等价定义就直接新建** —— 实测在 `.98` 上帮了倒忙：
  # 那台机器本来就有 `pve-no-subscription.sources` 与 `pve.list` 两份，
  # 脚本又生成了第三份 `proxmox.sources`，apt 于是满屏
  # `W: ... configured multiple times`，元数据被拉多遍。
  #
  # 所以改为：先**枚举所有提供者**（deb822 与单行格式都算），
  # 需要规范化时（多于一份 / codename 不符 / 还是单行格式）
  # 才统一收敛成一份 `proxmox.sources`，其余备份后移走。
  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/apt"
  local pv="" f
  # 判据与 check_system_repo / show_status 共用同一个函数（见 pve_needs_repair）
  if pve_needs_repair "$d" "$codename"; then
    pv=$(pve_source_files "$d")
    mkdir -p "$bk" 2>/dev/null || true
    while read -r f; do
      [[ -n "$f" ]] || continue
      cp -a "$f" "$bk/$(basename "$f").$(date +%s)" 2>/dev/null || true
      [[ "$(basename "$f")" == "proxmox.sources" ]] && continue
      rm -f "$f"
    done <<< "$pv"
    pve_sources_content "$codename" > "$d/proxmox.sources" || return 1
    did=1
  fi

  # Ceph 源：同样只在「是单行 .list」或「codename 不符」时规范化，
  # 已是正确的 deb822 就一个字节都不动（避免无谓 churn）
  local ceph="$d/ceph.list"
  if [[ -f "$ceph" ]] || { [[ -f "$d/ceph.sources" ]] && codename_mismatch "$d/ceph.sources" "$codename"; }; then
    mkdir -p "$bk" 2>/dev/null || true
    [[ -f "$ceph" ]] && { cp -a "$ceph" "$bk/ceph.list.$(date +%s)" 2>/dev/null || true; rm -f "$ceph"; }
    ceph_sources_content "$codename" > "$d/ceph.sources" || return 1
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

# ============================================================
# 工具链配置（pip / npm / git）里的「死 Nexus」
# ============================================================
#
# 与 apt/dnf 那套是同一回事，只是换了配置文件。实测那批跑过旧架构
# `ve.client.sh` 的 openEuler 机器上全是这个：
#   · pip  /root/.pip/pip.conf   index-url → http://192.168.0.18:8081/repository/pypi-all/simple
#   · npm  /root/.npmrc          registry  → http://192.168.0.18:8081/repository/npm-proxy/
#   · git  ~/.gitconfig          [http "http://192.168.0.36:4999/"] + sslVerify = false
# Nexus 下线后一律不可达（8081 无监听），pip install 直接失败、npm 完全不能用。
#
# **修法是「删掉那一行、回落默认」，不是改写地址**：TProxy 靠 DNS 劫持生效，
# 默认地址 pypi.org / registry.npmjs.org 本来就会被劫持 —— 改写反而多一个
# 要维护的值，而且下次服务端换地址又要再改一遍。

# 内网 IP（死 Nexus 与旧缓存都挂在内网地址上）。
# 公网镜像站（mirrors.aliyun.com 等）不算 —— 判据必须能区分这两者。
_is_internal_ip() {
  case "$1" in
    192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- pip ----

# pip 配置文件的候选位置。给了目录就只看该目录下的 pip.conf（便于测试）。
pip_config_files() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1/pip.conf"
  else
    printf '%s\n' /etc/pip.conf /root/.pip/pip.conf /root/.config/pip/pip.conf /etc/xdg/pip/pip.conf
  fi
}

# 判断：哪些 pip 配置的 index-url 指向死 Nexus。只读。
pip_dead_nexus() {
  local f
  while read -r f; do
    [[ -f "$f" ]] || continue
    grep -qE "^[[:space:]]*index-url[[:space:]]*=.*${_DEAD_NEXUS_RE}" "$f" 2>/dev/null && printf '%s\n' "$f"
  done < <(pip_config_files "${1:-}")
}

# 删掉指向死 Nexus 的 index-url 与配套的 trusted-host。
# trusted-host 是给那个自签服务的证书开后门用的，一起清掉才是干净状态。
repair_pip_config() {
  local f did=0
  while read -r f; do
    [[ -f "$f" ]] || continue
    local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/toolchain"
    mkdir -p "$bk" 2>/dev/null || true
    cp -a "$f" "$bk/$(tr '/' '_' <<<"$f").$(date +%s)" 2>/dev/null || true
    local tmp
    tmp=$(mktemp) || continue
    awk -v RE="$_DEAD_NEXUS_RE" '
      /^[[:space:]]*index-url[[:space:]]*=/ { if ($0 ~ RE) next }
      /^[[:space:]]*trusted-host[[:space:]]*=/ {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v)
        if (v ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) next
      }
      { print }
    ' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
    did=1
  done < <(pip_dead_nexus "${1:-}")
  [[ $did -eq 1 ]]
}

# ---- npm ----

npm_config_files() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1/npmrc"
  else
    printf '%s\n' /root/.npmrc /usr/etc/npmrc /etc/npmrc /usr/local/etc/npmrc
  fi
}

# 判断：哪些 npmrc 的 registry 指向死 Nexus。只读。
npm_dead_nexus() {
  local f
  while read -r f; do
    [[ -f "$f" ]] || continue
    grep -qE "^[[:space:]]*registry[[:space:]]*=.*${_DEAD_NEXUS_RE}" "$f" 2>/dev/null && printf '%s\n' "$f"
  done < <(npm_config_files "${1:-}")
}

# 删掉指向死 Nexus 的 registry，并清掉 strict-ssl（那是给死 Nexus 的自签证书
# 开后门用的；留着等于对**所有** npm 站点都不校验证书）。
repair_npm_config() {
  local f did=0
  while read -r f; do
    [[ -f "$f" ]] || continue
    local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/toolchain"
    mkdir -p "$bk" 2>/dev/null || true
    cp -a "$f" "$bk/$(tr '/' '_' <<<"$f").$(date +%s)" 2>/dev/null || true
    local tmp
    tmp=$(mktemp) || continue
    awk -v RE="$_DEAD_NEXUS_RE" '
      /^[[:space:]]*registry[[:space:]]*=/ { if ($0 ~ RE) next }
      /^[[:space:]]*strict-ssl[[:space:]]*=/ { next }
      { print }
    ' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
    did=1
  done < <(npm_dead_nexus "${1:-}")
  [[ $did -eq 1 ]]
}

# ---- git ----

# 判断：gitconfig 里指向**内网 IP** 的 `[http "..."]` 段。只读。
#
# `[http "<url>"]` 是 git 的「按 URL 生效的设置」段 —— 实测内容都是
# `sslVerify = false`，是旧缓存（.36:4999）留下的。它**不重定向流量**
# （那要 `http.proxy`，全网都是空的），所以没有功能影响；但 sslVerify=false
# 是个安全隐患，且那段指向的服务早没了，该清。
git_stale_internal_http() {
  local f="${1:-$HOME/.gitconfig}"
  [[ -f "$f" ]] || return 0
  awk '
    /^\[http "/ {
      if (match($0, /"[^"]*"/)) {
        url = substr($0, RSTART + 1, RLENGTH - 2)
        if (url ~ /^https?:\/\/(192[.]168[.]|10[.]|172[.](1[6-9]|2[0-9]|3[01])[.])/) { print; next }
      }
    }
  ' "$f"
}

# 整段移除（含段内所有行）。其他段一个字节不动。
repair_git_config() {
  local f="${1:-$HOME/.gitconfig}"
  [[ -f "$f" ]] || return 0
  [[ -n "$(git_stale_internal_http "$f")" ]] || return 0
  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/toolchain"
  mkdir -p "$bk" 2>/dev/null || true
  cp -a "$f" "$bk/$(tr '/' '_' <<<"$f").$(date +%s)" 2>/dev/null || true
  local tmp
  tmp=$(mktemp) || return 1
  awk '
    /^\[/ {
      if ($0 ~ /^\[http "/ && match($0, /"[^"]*"/)) {
        url = substr($0, RSTART + 1, RLENGTH - 2)
        if (url ~ /^https?:\/\/(192[.]168[.]|10[.]|172[.](1[6-9]|2[0-9]|3[01])[.])/) { skip = 1; next }
      }
      skip = 0
    }
    !skip { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
  return 0
}
