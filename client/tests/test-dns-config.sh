#!/usr/bin/env bash
# client/tests/test-dns-config.sh —— 验证 DNS 配置内容正确（不实际改动网络）
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/dns.sh
source "$DIR/lib/dns.sh"

fail=0

echo "== DNS 序列应为 18 → 223.5.5.5 → 119.29.29.29 =="
got=$(dns_server_list | tr '\n' ' ')
want="192.168.0.18 223.5.5.5 119.29.29.29 "
if [[ "$got" == "$want" ]]; then
  echo "  ✅ $got"
else
  echo "  ❌ 期望[$want] 实际[$got]"
  fail=1
fi

echo "== 不得包含被禁用的运营商 DNS =="
if dns_server_list | grep -q '202.99.192.68'; then
  echo "  ❌ 出现 202.99.192.68（运营商劫持，spec 明确禁用）"
  fail=1
else
  echo "  ✅ 未包含 202.99.192.68"
fi

echo "== 生成的内容应含串行查询参数 =="
# timeout:2 attempts:1 让 .18 不可用时能【快速】切到兜底，而不是卡 5 秒
content=$(render_resolv_conf)
if grep -q 'options timeout' <<<"$content"; then
  echo "  ✅ 含 timeout 选项"
else
  echo "  ❌ 缺少 timeout 选项（.18 挂掉时会卡默认 5 秒）"
  fail=1
fi
if [[ $(grep -c '^nameserver' <<<"$content") -eq 3 ]]; then
  echo "  ✅ 三个 nameserver"
else
  echo "  ❌ nameserver 数量不为 3"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "DNSCONF-PASS"; else echo "DNSCONF-FAIL"; fi
exit $fail
