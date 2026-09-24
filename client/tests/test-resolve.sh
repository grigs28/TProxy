#!/usr/bin/env bash
# client/tests/test-resolve.sh —— DNS 查询的解析（dig 缺失时的替代品）
#
# 为什么值得测：自检原本只认 dig，没有就整段跳过。加替代品时踩了三个坑，
# 全都是**只有拿到真机输出才看得出来**的：
#
#   ① resolvectl 的行尾还有 `-- link: eth0`，开始用的贪婪 `.*: ` 匹配到了
#      `link: ` 而不是域名后面那个冒号 → 永远取不到地址
#   ② `getent hosts` 只回 IPv6（实测 .78 上 pypi.org 回 4 条 AAAA、0 条 A）
#      → 必须改用 `getent ahostsv4`
#   ③ nslookup 的输出**前几行是它自己的服务器地址**（Server/Address），
#      通用「找第一个 IP」会把 127.0.0.1 当成答案
#
# 下面每个 fixture 都是从真机上原样抄下来的。
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/dist/tp.client.sh"

fail=0
T=$(mktemp -d)

# 把三个解析函数抽出来单独测（不跑整个脚本，避免依赖网络）
{
  sed -n '/^_nslookup_ipv4()/,/^}/p'      "$SCRIPT"
  sed -n '/^_resolvectl_ipv4()/,/^}/p'    "$SCRIPT"
  sed -n '/^_getent_ipv4()/,/^}/p'        "$SCRIPT"
} > "$T/parsers.sh"
if [[ ! -s "$T/parsers.sh" ]]; then
  echo "  ❌ 抽不出解析函数 —— 脚本里没有 _nslookup_ipv4 / _resolvectl_ipv4 / _getent_ipv4"
  rm -rf "$T"; echo "RESOLVE-FAIL"; exit 1
fi
# shellcheck source=/dev/null
source "$T/parsers.sh"

echo "== nslookup：不能把 Server/Address 那两行当成答案（真机 .17 抄来的）=="
out=$(printf 'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nName:\tgithub.com\nAddress: 20.205.243.166\n\nNon-authoritative answer:\n' | _nslookup_ipv4)
if [[ "$out" == "20.205.243.166" ]]; then
  echo "  ✅ 取到答案 20.205.243.166（没把 127.0.0.1 当答案）"
else
  echo "  ❌ 取到 '$out'，期望 20.205.243.166"
  fail=1
fi

echo "== nslookup：REFUSED 时不能返回服务器地址（真机 .17 抄来的）=="
out=$(printf "Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\n** server can't find pypi.org: REFUSED\n\n** server can't find pypi.org: REFUSED\n" | _nslookup_ipv4)
if [[ -z "$out" ]]; then
  echo "  ✅ 正确地返回空"
else
  echo "  ❌ 返回了 '$out'，应该为空"
  fail=1
fi

echo "== resolvectl：行尾有 '-- link: eth0' 也要取对（真机 .78 抄来的）=="
out=$(printf 'pypi.org: 151.101.192.223                                   -- link: eth0\n          151.101.0.223                                     -- link: eth0\n          151.101.64.223                                    -- link: eth0\n          2a04:4e42:400::223                                -- link: eth0\n' | _resolvectl_ipv4)
if [[ "$out" == "151.101.192.223" ]]; then
  echo "  ✅ 取到 151.101.192.223（没被 link: 那个冒号带偏）"
else
  echo "  ❌ 取到 '$out'，期望 151.101.192.223"
  fail=1
fi

echo "== getent：IPv6-only 的输出要返回空（真机 .78 的 getent hosts 就是）=="
out=$(printf '2a04:4e42:400::223 pypi.org\n2a04:4e42:600::223 pypi.org\n2a04:4e42::223  pypi.org\n' | _getent_ipv4)
if [[ -z "$out" ]]; then
  echo "  ✅ 正确地返回空（IPv6 不算 IPv4 答案）"
else
  echo "  ❌ 返回了 '$out'"
  fail=1
fi

echo "== getent ahostsv4 的输出要能取到 =="
out=$(printf '151.101.192.223 STREAM pypi.org\n151.101.192.223 DGRAM  \n151.101.192.223 RAW    \n' | _getent_ipv4)
if [[ "$out" == "151.101.192.223" ]]; then
  echo "  ✅ 取到 151.101.192.223"
else
  echo "  ❌ 取到 '$out'"
  fail=1
fi

echo "== 三个解析函数都要存在于脚本里 =="
for fn in _nslookup_ipv4 _resolvectl_ipv4 _getent_ipv4 dns_query_tool resolve_first_ip resolve_via; do
  if command grep -q "^${fn}()" "$SCRIPT"; then
    echo "  ✅ 有 $fn"
  else
    echo "  ❌ 缺 $fn"
    fail=1
  fi
done

echo "== resolve_via 必须区分「查不到」与「工具不支持 =="
# 工具不支持指定服务器时要返回 2（调用方据此跳过），不能返回 1（会被当成 DNS 不可达）
body=$(sed -n '/^resolve_via()/,/^}/p' "$SCRIPT")
if command grep -q 'return 2' <<<"$body"; then
  echo "  ✅ resolve_via 有 return 2 的分支"
else
  echo "  ❌ resolve_via 没有区分工具不支持 —— 会误报「备用 DNS 均不可达」"
  fail=1
fi

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "RESOLVE-PASS"; else echo "RESOLVE-FAIL"; fi
exit $fail
