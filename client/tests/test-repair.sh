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
          codename_mismatch git_redirects; do
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
