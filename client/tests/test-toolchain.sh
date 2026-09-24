#!/usr/bin/env bash
# client/tests/test-toolchain.sh —— pip / npm / git 的「死 Nexus」配置清理
#
# 背景（2026-09-24 全网巡检实测）：跑过旧架构 `ve.client.sh` 的机器上留着
#   · pip：/root/.pip/pip.conf 的 index-url 指向 http://192.168.0.18:8081/repository/pypi-all/simple
#   · npm：/root/.npmrc 的 registry 指向 http://192.168.0.18:8081/repository/npm-proxy/
#   · git：[http "http://192.168.0.36:4999/"] 段（旧缓存），带 sslVerify = false
# Nexus 下线后这些一律不可达 —— pip install 直接失败、npm 完全不能用。
# 而 TProxy 靠 DNS 劫持生效，**本来就该用默认地址**（pypi.org / registry.npmjs.org）。
#
# 所以修法是「把指向死 Nexus 的那一行去掉，回落默认」，而不是改写成别的地址。
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/repair.sh
source "$DIR/lib/repair.sh"

fail=0
T=$(mktemp -d)

echo "== pip：检出 index-url 指向死 Nexus =="
mkdir -p "$T/pip"
cat > "$T/pip/pip.conf" <<'EOF'
[global]
index-url = http://192.168.0.18:8081/repository/pypi-all/simple
trusted-host = 192.168.0.18
retries = 5
timeout = 120
EOF
n=$(pip_dead_nexus "$T/pip" | wc -l)
if [[ "$n" -eq 1 ]]; then
  echo "  ✅ 检出 1 个"
else
  echo "  ❌ 期望 1，实际 $n"
  fail=1
fi
BACKUP_DIR="$T/bk" repair_pip_config "$T/pip" >/dev/null
if [[ -z "$(pip_dead_nexus "$T/pip")" ]]; then
  echo "  ✅ 已清除"
else
  echo "  ❌ 还在"
  fail=1
fi
# 关键：要回落默认，而不是改写地址 —— 不能留下任何 index-url
if command grep -q '^index-url' "$T/pip/pip.conf"; then
  echo "  ❌ 仍留着 index-url："
  command grep '^index-url' "$T/pip/pip.conf" | sed 's/^/       /'
  fail=1
else
  echo "  ✅ index-url 已移除（回落默认 pypi.org，会被劫持）"
fi
# trusted-host 是给死 Nexus 的自签证书用的，一并清掉
if command grep -q '^trusted-host' "$T/pip/pip.conf"; then
  echo "  ❌ trusted-host 没清（它只为死 Nexus 存在）"
  fail=1
else
  echo "  ✅ trusted-host 已清"
fi
# 与 Nexus 无关的设置要保住
if command grep -q '^retries' "$T/pip/pip.conf" && command grep -q '^timeout' "$T/pip/pip.conf"; then
  echo "  ✅ 无关设置（retries / timeout）保留"
else
  echo "  ❌ 误删了无关设置"
  fail=1
fi

echo "== pip：本来就指向官方源的不能动 =="
mkdir -p "$T/pip2"
printf '[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\n' > "$T/pip2/pip.conf"
before=$(md5sum "$T/pip2/pip.conf" | cut -d' ' -f1)
BACKUP_DIR="$T/bk" repair_pip_config "$T/pip2" >/dev/null
if [[ "$before" == "$(md5sum "$T/pip2/pip.conf" | cut -d' ' -f1)" ]]; then
  echo "  ✅ 一个字节都没动"
else
  echo "  ❌ 动了不该动的（清华源是被劫持的，本来就对）"
  fail=1
fi

echo "== npm：检出 registry 指向死 Nexus =="
mkdir -p "$T/npm"
cat > "$T/npm/npmrc" <<'EOF'
registry=http://192.168.0.18:8081/repository/npm-proxy/
strict-ssl=false
EOF
n=$(npm_dead_nexus "$T/npm" | wc -l)
if [[ "$n" -eq 1 ]]; then
  echo "  ✅ 检出 1 个"
else
  echo "  ❌ 期望 1，实际 $n"
  fail=1
fi
BACKUP_DIR="$T/bk" repair_npm_config "$T/npm" >/dev/null
if [[ -z "$(npm_dead_nexus "$T/npm")" ]]; then
  echo "  ✅ 已清除"
else
  echo "  ❌ 还在"
  fail=1
fi
if command grep -q '^registry=' "$T/npm/npmrc"; then
  echo "  ❌ 仍留着 registry="
  fail=1
else
  echo "  ✅ registry 已移除（回落默认 registry.npmjs.org，会被劫持）"
fi
if command grep -q 'strict-ssl' "$T/npm/npmrc"; then
  echo "  ❌ strict-ssl=false 没清（那是在给死 Nexus 的自签证书开后门）"
  fail=1
else
  echo "  ✅ strict-ssl 已清"
fi

echo "== npm：指向华为云的不是「死 Nexus」，不在本函数职责内 =="
mkdir -p "$T/npm2"
printf 'registry=https://repo.huaweicloud.com/repository/npm\n' > "$T/npm2/npmrc"
if [[ -z "$(npm_dead_nexus "$T/npm2")" ]]; then
  echo "  ✅ 没误判（判据要求【内网 IP】+ /repository/，华为云是公网）"
else
  echo "  ❌ 误判了公网镜像"
  fail=1
fi

echo "== git：检出指向内网 IP 的 [http \"...\"] 段 =="
mkdir -p "$T/git"
cat > "$T/git/gitconfig" <<'EOF'
[user]
	name = someone
[http "http://192.168.0.36:4999/"]
	sslVerify = false
[core]
	editor = vim
EOF
n=$(git_stale_internal_http "$T/git/gitconfig" | wc -l)
if [[ "$n" -eq 1 ]]; then
  echo "  ✅ 检出 1 段"
else
  echo "  ❌ 期望 1，实际 $n"
  fail=1
fi
BACKUP_DIR="$T/bk" repair_git_config "$T/git/gitconfig" >/dev/null
if [[ -z "$(git_stale_internal_http "$T/git/gitconfig")" ]]; then
  echo "  ✅ 段已移除"
else
  echo "  ❌ 段还在"
  fail=1
fi
if command grep -q '^\[user\]' "$T/git/gitconfig" && command grep -q '^\[core\]' "$T/git/gitconfig"; then
  echo "  ✅ 其他段完好（user / core 保留）"
else
  echo "  ❌ 误删了别的段："; sed 's/^/       /' "$T/git/gitconfig"
  fail=1
fi
if command grep -q 'sslVerify' "$T/git/gitconfig"; then
  echo "  ❌ sslVerify 残留"
  fail=1
else
  echo "  ✅ sslVerify=false 随之清掉"
fi

echo "== git：公网 URL 的 [http] 段不该动 =="
mkdir -p "$T/git2"
printf '[http "https://github.com/"]\n\tsslVerify = false\n' > "$T/git2/gitconfig"
if [[ -z "$(git_stale_internal_http "$T/git2/gitconfig")" ]]; then
  echo "  ✅ 没误判公网地址"
else
  echo "  ❌ 误判了公网地址"
  fail=1
fi

echo "== 函数定义必须在主 dispatch 之前（否则运行时「未找到命令」）=="
# ⚠️ 真机上踩过：把工具链函数**追加到文件末尾**，而 `case "$ACTION" in` 在它之前 ——
# bash 是「执行到哪定义到哪」，于是 check_system_repo 里调用时函数还不存在：
#     /tmp/tp.client.sh: 行 1159: pip_dead_nexus: 未找到命令
# **单测全绿也没挡住**：测试是 source 整个文件，函数当然都在。
# 所以这条守卫直接比行号。
_dispatch=$(command grep -n '^case "\$ACTION" in' "$DIR/dist/tp.client.sh" | head -1 | cut -d: -f1)
if [[ -z "$_dispatch" ]]; then
  echo "  ⏭  找不到主 dispatch，跳过"
else
  while read -r fn; do
    [[ -z "$fn" ]] && continue
    _ln=$(command grep -n "^${fn}()" "$DIR/dist/tp.client.sh" | head -1 | cut -d: -f1)
    if [[ -z "$_ln" ]]; then
      echo "  ❌ dist 里没有 $fn"; fail=1
    elif (( _ln > _dispatch )); then
      echo "  ❌ $fn 定义在第 ${_ln} 行，晚于 dispatch（第 ${_dispatch} 行）—— 运行时会「未找到命令」"
      fail=1
    else
      echo "  ✅ $fn 在第 ${_ln} 行（dispatch 之前）"
    fi
  done <<< "$(printf '%s\n' pip_dead_nexus repair_pip_config npm_dead_nexus repair_npm_config git_stale_internal_http repair_git_config)"
fi

echo "== 两份实现不许分叉 =="
for fn in pip_dead_nexus repair_pip_config npm_dead_nexus repair_npm_config \
          git_stale_internal_http repair_git_config _is_internal_ip; do
  if command grep -q "^${fn}()" "$DIR/lib/repair.sh" && command grep -q "^${fn}()" "$DIR/dist/tp.client.sh"; then
    echo "  ✅ 两份都有 $fn"
  else
    echo "  ❌ 有一份缺少 $fn"
    fail=1
  fi
done

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "TOOLCHAIN-PASS"; else echo "TOOLCHAIN-FAIL"; fi
exit $fail
