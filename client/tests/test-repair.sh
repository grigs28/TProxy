#!/usr/bin/env bash
# client/tests/test-repair.sh —— 修复别的脚本留下的、会让机器不可用的配置
#
# 背景：PAID 机器（PVE 9 / Debian 13）跑过 ve/ve.client.sh，它留下三类问题：
#   1. /etc/apt/sources.list 指向 http://<cacheIP>/repository/debian-proxy/ ——
#      旧 Nexus 的路径，架构重建时已下线（实测 .18 与 .36 都是 000），
#      apt update 直接报错
#   2. 把正确的 PVE 9 sources（deb822、trixie）挪进 backup，
#      换成旧单行 .list 格式 + bookworm codename —— 而 PVE 9 基于 trixie
#   3. 留下一堆 /etc/hosts 覆盖，让劫持失效
#
# 另有 git 全局 insteadOf 把 github.com 重定向到别处，同样绕过缓存。
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/repair.sh
source "$DIR/lib/repair.sh"

fail=0
T=$(mktemp -d)

echo "== 检出指向已下线代理路径的 apt 源 =="
cat > "$T/sources.list" <<'EOF'
# 注释里的不算
# deb http://192.168.0.99/repository/debian-proxy/ trixie main
deb http://192.168.0.18/repository/debian-proxy/ trixie main contrib non-free non-free-firmware
deb http://192.168.0.36/repository/debian-proxy/ trixie-updates main contrib non-free
deb http://mirrors.ustc.edu.cn/debian-security trixie-security main
EOF
n=$(dead_proxy_sources "$T/sources.list" | wc -l)
if [[ "$n" -eq 2 ]]; then
  echo "  ✅ 检出 2 行（注释与正常源不算）"
else
  echo "  ❌ 期望 2 行，实际 $n"
  fail=1
fi

echo "== 与 .sources 重复的行也要清掉（apt 会告警且元数据拉两遍）=="
mkdir -p "$T/dup"
cat > "$T/dup/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
EOF
cat > "$T/dup/sources.list" <<'EOF'
deb http://192.168.0.18/repository/debian-proxy/ trixie main
deb http://mirrors.ustc.edu.cn/debian-security trixie-security main
deb http://mirrors.ustc.edu.cn/debian trixie-backports main
EOF
n=$(duplicate_suite_lines "$T/dup/sources.list" "$T/dup" | wc -l)
if [[ "$n" -eq 2 ]]; then
  echo "  ✅ 检出 2 行重复（trixie 与 trixie-security）"
else
  echo "  ❌ 期望 2，实际 $n"
  fail=1
fi
BACKUP_DIR="$T/bk" repair_apt_sources "$T/dup/sources.list" "$T/dup" trixie >/dev/null
if grep -q "trixie-backports" "$T/dup/sources.list" \
   && ! grep -qE "repository/debian-proxy|debian-security" "$T/dup/sources.list"; then
  echo "  ✅ 重复行已清，backports（唯一没被覆盖的）保留"
else
  echo "  ❌ 结果不对:"; sed 's/^/       /' "$T/dup/sources.list"
  fail=1
fi

echo "== PVE 9 的源该长什么样（官方 deb822 + trixie）=="
pve_sources_content trixie > "$T/proxmox.sources"
if grep -q "^Types: deb$" "$T/proxmox.sources" \
   && grep -q "URIs: http://download.proxmox.com/debian/pve" "$T/proxmox.sources" \
   && grep -q "^Suites: trixie$" "$T/proxmox.sources" \
   && grep -q "Components: pve-no-subscription" "$T/proxmox.sources" \
   && grep -q "Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg" "$T/proxmox.sources"; then
  echo "  ✅ PVE 源格式正确（deb822 / trixie / 无订阅）"
else
  echo "  ❌ PVE 源内容不对:"; sed 's/^/       /' "$T/proxmox.sources"
  fail=1
fi

ceph_sources_content trixie > "$T/ceph.sources"
if grep -q "URIs: http://download.proxmox.com/debian/ceph-squid" "$T/ceph.sources" \
   && grep -q "^Suites: trixie$" "$T/ceph.sources" \
   && grep -q "Components: no-subscription" "$T/ceph.sources"; then
  echo "  ✅ Ceph 源格式正确"
else
  echo "  ❌ Ceph 源内容不对:"; sed 's/^/       /' "$T/ceph.sources"
  fail=1
fi

echo "== 保护：只有 metalink 没有 baseurl 的段不许删（删了就没兜底）=="
mkdir -p "$T/d2"
cat > "$T/d2/onlymeta.repo" <<'EOF'
[only-meta]
name=only metalink, no baseurl
metalink=https://mirrors.openeuler.org/metalink?repo=x&arch=x86_64
enabled=1
EOF
cat > "$T/d2/normal.repo" <<'EOF'
[OS]
name=OS
baseurl=https://repo.openeuler.org/openEuler-24.03-LTS-SP4/OS/x86_64/
metalink=https://mirrors.openeuler.org/metalink?repo=$releasever/OS&arch=$basearch
enabled=1
EOF
BACKUP_DIR="$T/bk" repair_dnf_repos "$T/d2" >/dev/null
if [[ "$(grep -c '^metalink=' "$T/d2/onlymeta.repo")" -eq 1 ]]; then
  echo "  ✅ 无 baseurl 的段保留了 metalink"
else
  echo "  ❌ 删了没有兜底的 metalink —— 该仓库会彻底失效"
  fail=1
fi
if [[ "$(grep -c '^metalink=' "$T/d2/normal.repo")" -eq 0 ]] \
   && [[ "$(grep -c '^baseurl=' "$T/d2/normal.repo")" -eq 1 ]]; then
  echo "  ✅ 有 baseurl 的段正常删除，baseurl 完好"
else
  echo "  ❌ 正常段处理不对"
  fail=1
fi

echo "== dnf（openEuler）侧：metalink 与冗余源 =="
mkdir -p "$T/yum.repos.d"
cat > "$T/yum.repos.d/openEuler.repo" <<'EOF'
[OS]
name=OS
baseurl=https://repo.openeuler.org/openEuler-24.03-LTS-SP3/OS/x86_64/
metalink=https://mirrors.openeuler.org/metalink?repo=$releasever/OS&arch=$basearch
enabled=1

[debuginfo]
name=debuginfo
baseurl=https://repo.openeuler.org/openEuler-24.03-LTS-SP3/debuginfo/x86_64/
enabled=1
EOF
if [[ -n "$(dnf_metalink_sources "$T/yum.repos.d")" ]]; then
  echo "  ✅ 检出含 metalink 的 repo"
else
  echo "  ❌ 没检出 metalink"
  fail=1
fi
if [[ -n "$(dnf_redundant_repos "$T/yum.repos.d")" ]]; then
  echo "  ✅ 检出启用中的 debuginfo"
else
  echo "  ❌ 没检出冗余源"
  fail=1
fi
BACKUP_DIR="$T/bk" repair_dnf_repos "$T/yum.repos.d" >/dev/null
if [[ -z "$(dnf_metalink_sources "$T/yum.repos.d")" ]]; then
  echo "  ✅ metalink 已清除"
else
  echo "  ❌ metalink 还在"
  fail=1
fi
if grep -q "openEuler-24.03-LTS-SP3/OS/x86_64/" "$T/yum.repos.d/openEuler.repo"; then
  echo "  ✅ baseurl 未被破坏"
else
  echo "  ❌ baseurl 被改坏了"
  fail=1
fi
if [[ -z "$(dnf_redundant_repos "$T/yum.repos.d")" ]]; then
  echo "  ✅ 冗余源已关闭"
else
  echo "  ❌ 冗余源仍启用"
  fail=1
fi

echo "== 不许碰 backup/ 里的备份（那里的文件 dnf 根本不读）=="
# 实测 .9（CentOS 7）暴露的：/etc/yum.repos.d/ 下有个 backup/ 子目录，
# 里面是被替换掉的旧配置 —— dnf 不读它，所以它既不该被报成问题，
# 更不该被「修复」。改了就还原不回去了，备份的意义就没了。
mkdir -p "$T/bk9/yum.repos.d/backup"
cat > "$T/bk9/yum.repos.d/backup/openEuler.repo" <<'EOF'
[OS]
name=OS
baseurl=https://repo.openeuler.org/openEuler-24.03-LTS-SP3/OS/x86_64/
metalink=https://mirrors.openeuler.org/metalink?repo=$releasever/OS&arch=$basearch
enabled=1
EOF
cat > "$T/bk9/yum.repos.d/active.repo" <<'EOF'
[OS]
name=OS
baseurl=https://repo.openeuler.org/openEuler-24.03-LTS-SP3/OS/x86_64/
metalink=https://mirrors.openeuler.org/metalink?repo=$releasever/OS&arch=$basearch
enabled=1
EOF
got=$(dnf_metalink_sources "$T/bk9/yum.repos.d")
if [[ "$got" == *active.repo* && "$got" != *backup* ]]; then
  echo "  ✅ 只报活动配置，没报 backup/"
else
  echo "  ❌ 把 backup/ 也报出来了: $(tr '\n' ' ' <<<"$got")"
  fail=1
fi
before=$(md5sum "$T/bk9/yum.repos.d/backup/openEuler.repo" | cut -d' ' -f1)
BACKUP_DIR="$T/bk" repair_dnf_repos "$T/bk9/yum.repos.d" >/dev/null
if [[ "$before" == "$(md5sum "$T/bk9/yum.repos.d/backup/openEuler.repo" | cut -d' ' -f1)" ]]; then
  echo "  ✅ 备份文件一字未动"
else
  echo "  ❌ 备份被改写了 —— 还原不回去，备份失去意义"
  diff <(printf '') "$T/bk9/yum.repos.d/backup/openEuler.repo" >/dev/null 2>&1 || true
  fail=1
fi

echo "== 全段 enabled=0 的 repo 不该被报（dnf 不会读它）=="
mkdir -p "$T/off/yum.repos.d"
cat > "$T/off/yum.repos.d/epel-testing.repo" <<'EOF'
[epel-testing]
name=EPEL Testing
#baseurl=http://download.example/pub/epel/testing/7/$basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=testing-epel7
enabled=0

[epel-testing-debuginfo]
name=EPEL Testing Debug
metalink=https://mirrors.fedoraproject.org/metalink?repo=testing-debug-epel7
enabled=0
EOF
cat > "$T/off/yum.repos.d/on.repo" <<'EOF'
[epel]
name=EPEL
baseurl=http://mirror.example/epel/7/$basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-7
enabled=1
EOF
got=$(dnf_metalink_sources "$T/off/yum.repos.d")
if [[ "$got" == *on.repo* && "$got" != *epel-testing* ]]; then
  echo "  ✅ 只报启用中的，enabled=0 的不报"
else
  echo "  ❌ enabled=0 的也被报出来了: $(tr '\n' ' ' <<<"$got")"
  fail=1
fi

echo "== 已下线的 Nexus 路径（不只是 debian-proxy 那一条）=="
# 实测 .16：/etc/yum.repos.d/nexus-openeuler.repo 里挂着
#   baseurl=http://192.168.0.18:8081/repository/openEuler-24.03-OS/
#   baseurl=http://192.168.0.18/repository/openEuler-24.03-update/
# 旧 Nexus 下线后一律不可达，dnf makecache 直接
#   Curl error (7): Couldn't connect to server ... port 8081
# 而原判据只有 `repository/debian-proxy`（apt 侧那一条）—— 这些漏网，
# 脚本还会报「正常」。
mkdir -p "$T/nx/yum.repos.d"
cat > "$T/nx/yum.repos.d/nexus-openeuler.repo" <<'EOF'
[nexus-openeuler-os]
name=Nexus openEuler OS
baseurl=http://192.168.0.18:8081/repository/openEuler-24.03-OS/
enabled=1

[nexus-openeuler-update]
name=Nexus openEuler update
baseurl=http://192.168.0.18/repository/openEuler-24.03-update/
enabled=1

[OS]
name=OS
baseurl=https://repo.openeuler.org/openEuler-24.03-LTS-SP3/OS/x86_64/
enabled=1
EOF
n=$(dead_nexus_repos "$T/nx/yum.repos.d" | wc -l)
if [[ "$n" -eq 1 ]]; then
  echo "  ✅ 检出含死 Nexus 路径的 repo 文件"
else
  echo "  ❌ 期望检出 1 个文件，实际 $n"
  fail=1
fi
BACKUP_DIR="$T/bk" repair_dnf_repos "$T/nx/yum.repos.d" >/dev/null
if [[ -z "$(dead_nexus_repos "$T/nx/yum.repos.d")" ]]; then
  echo "  ✅ 已处理（不再有启用的死 Nexus 仓库）"
else
  echo "  ❌ 死 Nexus 仓库仍启用 —— dnf 会继续报错"
  fail=1
fi
if command grep -q "openEuler-24.03-LTS-SP3/OS/x86_64/" "$T/nx/yum.repos.d/nexus-openeuler.repo"; then
  echo "  ✅ 正常的 openEuler 源未被波及"
else
  echo "  ❌ 误伤了正常的源"
  fail=1
fi

echo "== 不该误判：镜像站的 /repository/ 不是 Nexus =="
mkdir -p "$T/nx2/yum.repos.d"
cat > "$T/nx2/yum.repos.d/ok.repo" <<'EOF'
[ok]
name=正常仓库
baseurl=https://mirrors.aliyun.com/repository/openeuler/
enabled=1
EOF
if [[ -z "$(dead_nexus_repos "$T/nx2/yum.repos.d")" ]]; then
  echo "  ✅ 公网镜像站没被误判（判据要求是【内网 IP】+ /repository/）"
else
  echo "  ❌ 误判了公网镜像站"
  fail=1
fi

echo "== 全新 PVE：移走企业版源后【必须补上】no-subscription =="
# 背景（2026-09-25，在全新装的 PVE 10.10.10.116 上发现）：
# 官方默认只有**订阅版**（pve-enterprise + ceph enterprise）。
# 我们过去只「移走错的」，没「补上对的」—— 于是全新机器修完变成
# **一个 Proxmox 源都没有**，组件静默失去全部更新。
# 老机器上因为 ve.client.sh 留了 pve-no-subscription.list 而"看起来对"，
# 全新机器才露出来。
#
# ve.client.sh 在这一点上做得比我们全：它明确「移走什么就补什么」。
mkdir -p "$T/fresh/sources.list.d"
: > "$T/fresh/sources.list"
cat > "$T/fresh/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
EOF
cat > "$T/fresh/sources.list.d/pve-enterprise.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
cat > "$T/fresh/sources.list.d/ceph.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
# 完整流程：先禁企业版，再补 no-subscription
# 真实调用形态：**移走前**先捕获，移走后按捕获值补
_comps=$(proxmox_components "$T/fresh/sources.list.d")
BACKUP_DIR="$T/bk1" disable_enterprise_sources "$T/fresh/sources.list.d" >/dev/null
BACKUP_DIR="$T/bk1" ensure_nosubscription_sources "$T/fresh/sources.list.d" trixie "$_comps" >/dev/null
if [[ -f "$T/fresh/sources.list.d/proxmox.sources" ]] \
   && grep -q 'pve-no-subscription' "$T/fresh/sources.list.d/proxmox.sources"; then
  echo "  ✅ 补上了 proxmox.sources（pve-no-subscription）"
else
  echo "  ❌ 没补 pve 源 —— 全新 PVE 会一个 Proxmox 源都没有"
  fail=1
fi
if [[ -f "$T/fresh/sources.list.d/ceph.sources" ]] \
   && grep -q 'no-subscription' "$T/fresh/sources.list.d/ceph.sources"; then
  echo "  ✅ 补上了 ceph.sources（no-subscription）"
else
  echo "  ❌ 没补 ceph 源"
  fail=1
fi

echo "== 补的源地址必须是【被劫持】的那个（否则绕过缓存）=="
if grep -q 'URIs: http://download.proxmox.com/debian/pve' "$T/fresh/sources.list.d/proxmox.sources" 2>/dev/null; then
  echo "  ✅ 用 download.proxmox.com（2026-09-25 已加入 dnsmasq 劫持，走缓存）"
else
  echo "  ❌ 地址不对：$(grep URIs "$T/fresh/sources.list.d/proxmox.sources" 2>/dev/null)"
  fail=1
fi

echo "== 纯 Debian 机器不得【凭空】加 Proxmox 源 =="
mkdir -p "$T/plain/sources.list.d"
: > "$T/plain/sources.list"
cp "$T/fresh/sources.list.d/debian.sources" "$T/plain/sources.list.d/"
BACKUP_DIR="$T/bk2" ensure_nosubscription_sources "$T/plain/sources.list.d" trixie >/dev/null 2>&1
if [[ -z "$(ls "$T/plain/sources.list.d/" | grep -i proxmox)" ]] \
   && [[ ! -f "$T/plain/sources.list.d/ceph.sources" ]]; then
  echo "  ✅ 什么都没加"
else
  echo "  ❌ 给纯 Debian 机器加了 Proxmox 源"
  fail=1
fi

echo "== 已有 no-subscription 时【幂等】，不重复写 =="
mkdir -p "$T/has/sources.list.d"
: > "$T/has/sources.list"
cp "$T/fresh/sources.list.d/debian.sources" "$T/has/sources.list.d/"
cp "$T/fresh/sources.list.d/proxmox.sources" "$T/has/sources.list.d/"
mkdir -p "$T/has/sources.list.d/backup"
cp "$T/fresh/sources.list.d/ceph.sources" "$T/has/sources.list.d/backup/ceph.sources.old"
before=$(md5sum "$T/has/sources.list.d/proxmox.sources" | cut -d' ' -f1)
BACKUP_DIR="$T/bk3" ensure_nosubscription_sources "$T/has/sources.list.d" trixie >/dev/null 2>&1
if [[ "$before" == "$(md5sum "$T/has/sources.list.d/proxmox.sources" | cut -d' ' -f1)" ]]; then
  echo "  ✅ pve 源未被重写"
else
  echo "  ❌ 重复写了 pve 源"
  fail=1
fi
if [[ -f "$T/has/sources.list.d/ceph.sources" ]] \
   && grep -q 'no-subscription' "$T/has/sources.list.d/ceph.sources"; then
  echo "  ✅ ceph 从 \$d/backup 里认出来了（ve.client.sh 的约定），补了 no-subscription"
else
  echo "  ❌ ceph 没补（backup 里的应当也算「这台机器有这个组件」）"
  fail=1
fi

echo "== PVE 源必须【只剩一份】定义（真机 .98 上出现了三份）=="
# 实测 .98：同一仓库同时有
#     pve.list                    deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
#     pve-no-subscription.sources （deb822，早就存在）
#     proxmox.sources             （脚本刚生成的 —— **帮倒忙**）
# apt 会对每条发 W: configured multiple times，且元数据被拉多遍。
# 原逻辑只认 `pve-no-subscription.list` 这一个文件名，且不看是否已有等价定义就新建。
mkdir -p "$T/p98"
cat > "$T/p98/pve-no-subscription.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
printf 'deb http://download.proxmox.com/debian/pve trixie pve-no-subscription\n' > "$T/p98/pve.list"
cat > "$T/p98/pve-ceph.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
EOF
BACKUP_DIR="$T/bk" repair_apt_sources "$T/empty-sources.list" "$T/p98" trixie >/dev/null 2>&1
n=$(pve_source_files "$T/p98" | wc -l)
if [[ "$n" -eq 1 ]]; then
  echo "  ✅ 修后只剩 1 份（$(pve_source_files "$T/p98" | xargs -n1 basename | tr '\n' ' ')）"
else
  echo "  ❌ 修后仍有 $n 份："
  pve_source_files "$T/p98" | sed 's/^/       /'
  fail=1
fi
if [[ -f "$T/p98/pve-ceph.sources" ]]; then
  echo "  ✅ Ceph 源（另一个仓库）未被波及"
else
  echo "  ❌ 误删了 Ceph 源"
  fail=1
fi

echo "== 已有一份时不该再新建（幂等）=="
mkdir -p "$T/p99"
cp "$T/p98/pve-no-subscription.sources" "$T/p99/" 2>/dev/null || \
  printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\n' > "$T/p99/pve-no-subscription.sources"
before=$(pve_source_files "$T/p99" | wc -l)
BACKUP_DIR="$T/bk" repair_apt_sources "$T/empty-sources.list" "$T/p99" trixie >/dev/null 2>&1
after=$(pve_source_files "$T/p99" | wc -l)
if [[ "$before" -eq 1 && "$after" -eq 1 ]]; then
  echo "  ✅ 仍是一份"
else
  echo "  ❌ $before → $after 份（重复执行不该增加）"
  fail=1
fi

echo "== 检出启用中的企业版源（非订阅会 401）=="
mkdir -p "$T/d"
cat > "$T/d/pve-enterprise.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
EOF
cat > "$T/d/proxmox.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
EOF
mkdir -p "$T/d/backup"
cp "$T/d/pve-enterprise.sources" "$T/d/backup/pve-enterprise.sources.old"
n=$(enterprise_sources "$T/d" | wc -l)
if [[ "$n" -eq 1 ]]; then
  echo "  ✅ 检出 1 个启用中的企业源（backup 里的不算）"
else
  echo "  ❌ 期望 1，实际 $n"
  fail=1
fi
BACKUP_DIR="$T/bk" disable_enterprise_sources "$T/d" >/dev/null
if [[ -z "$(enterprise_sources "$T/d")" ]]; then
  echo "  ✅ 已禁用（移进 backup，可逆）"
else
  echo "  ❌ 仍在启用"
  fail=1
fi
if [[ -f "$T/d/proxmox.sources" ]]; then
  echo "  ✅ 无订阅源未被波及"
else
  echo "  ❌ 误动了无订阅源"
  fail=1
fi

echo "== 检出 codename 与实际系统不符 =="
printf 'deb http://mirrors.ustc.edu.cn/proxmox/debian/pve bookworm pve-no-subscription\n' > "$T/pve.list"
if codename_mismatch "$T/pve.list" trixie; then
  echo "  ✅ 检出 bookworm ≠ trixie"
else
  echo "  ❌ 没检出 codename 不符"
  fail=1
fi
printf 'deb http://download.proxmox.com/debian/pve trixie pve-no-subscription\n' > "$T/ok.list"
codename_mismatch "$T/ok.list" trixie && { echo "  ❌ 一致却报不符"; fail=1; } \
  || echo "  ✅ 一致时不报"

echo "== git 重定向：检出指向非缓存地址的 insteadOf =="
cat > "$T/gitconfig" <<'EOF'
[user]
	name = someone
[url "http://gitea.local:3000/"]
	insteadOf = https://github.com/
	insteadOf = https://raw.githubusercontent.com/
EOF
out=$(git_redirects "$T/gitconfig" | tr '\n' ' ')
if [[ "$out" == *"github.com"* && "$out" == *"gitea.local"* ]]; then
  echo "  ✅ 检出 github → gitea.local"
else
  echo "  ❌ 没检出: '$out'"
  fail=1
fi
# 没有重定向时不该报
printf '[user]\n\tname = x\n' > "$T/gitclean"
[[ -z "$(git_redirects "$T/gitclean")" ]] && echo "  ✅ 无重定向时不报" \
  || { echo "  ❌ 误报"; fail=1; }

echo "== 两份实现不许分叉 =="
for fn in dead_proxy_sources pve_sources_content ceph_sources_content \
          codename_mismatch git_redirects enterprise_sources \
          duplicate_suite_lines \
          disable_enterprise_sources dnf_metalink_sources \
          dead_nexus_repos disable_dead_nexus_repos pve_source_files \
          proxmox_components ensure_nosubscription_sources \
          dnf_redundant_repos repair_dnf_repos is_rpm_like; do
  if grep -q "^${fn}()" "$DIR/lib/repair.sh" && grep -q "^${fn}()" "$DIR/dist/tp.client.sh"; then
    echo "  ✅ 两份都有 $fn"
  else
    echo "  ❌ 有一份缺少 $fn"
    fail=1
  fi
done

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "REPAIR-PASS"; else echo "REPAIR-FAIL"; fi
exit $fail
