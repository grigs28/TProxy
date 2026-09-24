#!/usr/bin/env bash
# client/tests/test-status.sh —— 接入状态的**判定结论**
#
# 为什么值得测：`--status` 原本把「DNS 指向」和「CA 是否安装」当两件独立的事
# 分别打印，各自看都是中性的 —— 于是**从不说破合起来的含义**。
#
# 实测 .16 就是最糟的那一档：DNS 已指 .18（劫持生效、37 个域名全被 MITM），
# 但根 CA 没装 → 所有 HTTPS 报 curl 60。这台机器**比没接入时更不可用**，
# 而 --status 只给了两条普通 warning，看起来像是「差一步没配完」。
#
# 四种组合的含义完全不同，必须分开判定。
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/dist/tp.client.sh"

fail=0
T=$(mktemp -d)

if ! command grep -q '^onboard_verdict()' "$SCRIPT"; then
  echo "  ❌ 脚本里没有 onboard_verdict()"
  rm -rf "$T"; echo "STATUS-FAIL"; exit 1
fi
sed -n '/^onboard_verdict()/,/^}/p' "$SCRIPT" > "$T/v.sh"
# shellcheck source=/dev/null
source "$T/v.sh"

echo "== 四种组合的判定 =="
# 参数：<DNS 是否指向本代理> <CA 是否已装入信任库>
check() {
  local dns="$1" ca="$2" want="$3" desc="$4"
  got=$(onboard_verdict "$dns" "$ca")
  if [[ "$got" == "$want" ]]; then
    echo "  ✅ $desc → $got"
  else
    echo "  ❌ $desc → 期望 $want，实际 '$got'"
    fail=1
  fi
}
check 1 1 ok           "DNS 指代理 + CA 已装"
check 1 0 broken       "DNS 指代理 + CA 未装（半接入，TLS 全断）"
check 0 1 stale-ca     "DNS 未指代理 + CA 已装（装了 CA 却没走代理）"
check 0 0 not-onboarded "都没配"

echo "== 半接入必须被判为坏（不是普通的「差一步」）=="
onboard_verdict 1 0 >/dev/null
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "  ✅ 半接入返回非 0（调用方据此报「错误」而不是 warning）"
else
  echo "  ❌ 半接入返回 0 —— 会被当成正常状态"
  fail=1
fi
onboard_verdict 1 1 >/dev/null
[[ $? -eq 0 ]] && echo "  ✅ 正常接入返回 0" || { echo "  ❌ 正常接入返回非 0"; fail=1; }

echo "== --status 必须把结论打出来（而不是只列两个事实）=="
# ⚠️ 别用 `[^\n]` 想表达「非换行」—— grep 里那是「排除 \ 和 n 两个字符」，
# 而 `onboard_verdict "$_dns" "$_ca"` 里的 `_dns` 含 n，会被误判成不匹配。
if command grep -q 'onboard_verdict' <<<"$(sed -n '/^show_status()/,/^}/p' "$SCRIPT")"; then
  echo "  ✅ show_status 调用了 onboard_verdict"
else
  echo "  ❌ show_status 没用它 —— 结论仍然说不出来"
  fail=1
fi

echo "== systemd-resolved 在跑时要告警（并行查询会破坏劫持）=="
body=$(sed -n '/^show_status()/,/^}/p' "$SCRIPT")
if command grep -q 'systemd-resolved' <<<"$body"; then
  echo "  ✅ show_status 会提到 systemd-resolved"
else
  echo "  ❌ show_status 不提 systemd-resolved —— 用户不知道劫持可能失效"
  fail=1
fi

echo "== 没有 python3 时 Docker 配置要明说处理不了 =="
if command grep -qE 'python3' <(sed -n '/^check_docker_conf()/,/^}/p' "$SCRIPT"); then
  echo "  ✅ check_docker_conf 里提到了 python3"
else
  echo "  ❌ 没有 python3 时会静默失败，用户以为处理过了"
  fail=1
fi

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "STATUS-PASS"; else echo "STATUS-FAIL"; fi
exit $fail
