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
