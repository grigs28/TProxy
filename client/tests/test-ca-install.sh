#!/usr/bin/env bash
# client/tests/test-ca-install.sh —— 验证 CA 安装函数与域名清单
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/ca.sh
source "$DIR/lib/ca.sh"

fail=0

echo "== 所需函数应已定义 =="
for fn in install_system_ca install_docker_ca install_java_ca install_runtime_ca; do
  if declare -F "$fn" >/dev/null; then
    echo "  ✅ $fn"
  else
    echo "  ❌ 缺少函数 $fn"
    fail=1
  fi
done

echo "== Docker 域名清单应为 10 个 =="
n=$(docker_ca_domains | grep -c .)
if [[ "$n" -eq 10 ]]; then
  echo "  ✅ 10 个域名"
else
  echo "  ❌ 期望 10，实际 $n"
  fail=1
fi

echo "== 域名清单应与 dnsmasq 劫持的一致 =="
# Docker 客户端不读系统 CA 库，CA 必须按域名逐个放入 certs.d；
# 漏一个域名就会导致该仓库拉取时报证书错误
for d in registry-1.docker.io auth.docker.io quay.io ghcr.io gcr.io; do
  if docker_ca_domains | grep -qx "$d"; then
    echo "  ✅ $d"
  else
    echo "  ❌ 缺少 $d"
    fail=1
  fi
done

# ---- 根 CA 轮换：运行时自带的 CA 包必须真的换掉 ----
# conda / miniconda 用自己的 ssl/cacert.pem，不读系统信任库。
# 它们最初是用「固定标记串」判重的，于是根 CA 一换，
# 脚本看到标记就跳过 —— 客户端继续拿着旧根，
# 表现为「换根后 conda/pip 连不上，且完全看不出原因」。
echo "== 根 CA 轮换（运行时 CA 包）=="
_t=$(mktemp -d)
_mkcert() {
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
    -out "$1" -days "$2" -subj "/CN=TProxy Root CA" 2>/dev/null
}
_mkcert "$_t/old.crt" 3650
_mkcert "$_t/new.crt" 10950
_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g'; }
_OLD=$(_fp "$_t/old.crt"); _NEW=$(_fp "$_t/new.crt")

# 造一个假的 bundle，并把候选路径指到它（函数可覆盖，故测试无需真装 conda）
BUNDLE="$_t/cacert.pem"
echo "# 其他 CA 占位" > "$BUNDLE"
_runtime_candidates() { printf '%s\n' "$BUNDLE"; }

# 模拟「继承来的 root 独占权限」。这不是假想：早先的 remove_runtime_ca
# 用 mktemp + mv 落盘，而 mv 会把临时文件的 600 root:root 带过去，
# 于是 bundle 变成只有 root 读得到 —— 普通用户跑 conda/pip 时连自己的
# CA 包都打不开，curl 报的是 exit 77，信息里完全看不出是权限问题。
chmod 600 "$BUNDLE"

# 从 bundle 里取出我们追加的那张证书并算指纹。
# 必须连 BEGIN/END 两行一起取出 —— 只给 base64 正文 openssl 是解析不了的。
_bundle_fp() {
  awk '
    /TProxy Root CA/ { f=1; next }
    f && /-----BEGIN CERTIFICATE-----/ { b=1 }
    b { print }
    b && /-----END CERTIFICATE-----/ { exit }
  ' "$1" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g'
}

install_runtime_ca "$_t/old.crt" >/dev/null
if [[ "$(_bundle_fp "$BUNDLE")" == "$_OLD" ]]; then
  echo "  ✅ 首次安装写入旧根"
else
  echo "  ❌ 首次安装未写入"; fail=1
fi

install_runtime_ca "$_t/old.crt" >/dev/null
if [[ "$(grep -c 'TProxy Root CA' "$BUNDLE")" -eq 1 ]]; then
  echo "  ✅ 重复安装同一张不重复追加"
else
  echo "  ❌ 重复追加了"; fail=1
fi

install_runtime_ca "$_t/new.crt" >/dev/null
if [[ "$(_bundle_fp "$BUNDLE")" == "$_NEW" ]]; then
  echo "  ✅ 换根后换成了新根"
else
  echo "  ❌ 换根后仍是旧根（客户端会一直用过期信任锚）"; fail=1
fi
if [[ "$(grep -c 'TProxy Root CA' "$BUNDLE")" -eq 1 ]]; then
  echo "  ✅ 旧根未残留在包里"
else
  echo "  ❌ 新旧根同时存在"; fail=1
fi
if grep -q "其他 CA 占位" "$BUNDLE"; then
  echo "  ✅ 原有内容未被破坏"
else
  echo "  ❌ 原有内容被破坏"; fail=1
fi

# conda / pip 常以普通用户身份运行，bundle 必须对普通用户可读。
# 注意别用 [[ -r ]] 判断 —— 脚本以 root 运行，root 永远读得到。
_bm=$(stat -c '%a' "$BUNDLE")
if (( (8#$_bm & 8#004) != 0 )); then
  echo "  ✅ bundle 对普通用户可读 ($_bm)"
else
  echo "  ❌ bundle 权限 $_bm，普通用户的 conda/pip 读不到自己的 CA 包"; fail=1
fi

# 「内容已是最新」这条路径也必须修权限，否则它永远纠正不过来：
# 一台机器只要曾经对过一次，之后再跑脚本都走这条分支。
chmod 600 "$BUNDLE"
install_runtime_ca "$_t/new.crt" >/dev/null
_bm=$(stat -c '%a' "$BUNDLE")
if (( (8#$_bm & 8#004) != 0 )); then
  echo "  ✅ 内容已最新时仍会修正权限 ($_bm)"
else
  echo "  ❌ 走「已是最新」分支时权限没被修正（$_bm），这类机器永远好不了"; fail=1
fi
rm -rf "$_t"

if [[ $fail -eq 0 ]]; then echo "CAINST-PASS"; else echo "CAINST-FAIL"; fi
exit $fail
