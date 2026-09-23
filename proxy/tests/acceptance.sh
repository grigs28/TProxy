#!/usr/bin/env bash
# proxy/tests/acceptance.sh —— 计划 A（阶段 1-2）完整验收
# 在目标机运行
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
fail=0

run() {
  local name="$1"; shift
  echo "--- $name ---"
  if "$@"; then :; else echo "  ⬆️ 该组失败"; fail=1; fi
  echo
}

run "CA 与私钥"          "$D/test-ca.sh"
run "DNS 劫持与内网解析"  "$D/test-dns.sh"
run "HTTP 分流"          "$D/test-http.sh"
run "TLS 终结"           "$D/test-tls.sh"
run "缓存行为"           "$D/test-cache.sh"

echo "--- 防绕过说明 ---"
echo "  ℹ️ QUIC(UDP 443) 与 DoH/DoT 的阻断属于客户端与网络层范畴，不在本计划范围"
echo "     （见 spec §4.4）。该加固由计划 C 的 client-setup.sh 在客户端实施。"
echo

echo "--- 容器健康 ---"
docker compose -f "$D/../docker-compose.yml" ps
echo

if [[ $fail -eq 0 ]]; then
  echo "ACCEPTANCE-PASS（阶段 1-2 验收通过）"
else
  echo "ACCEPTANCE-FAIL（存在失败项，见上）"
fi
exit $fail
