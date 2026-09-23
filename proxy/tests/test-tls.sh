#!/usr/bin/env bash
# proxy/tests/test-tls.sh —— 验证 HTTPS 终结与证书链（MITM）
# 在目标机运行。用 --resolve 模拟「客户端 DNS 已指向代理」的情形，
# 避免依赖测试机自身的 DNS 配置。
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0

[[ -f "$CA" ]] || { echo "❌ 缺少根 CA: $CA"; echo "TLS-HAS-FAILURE"; exit 1; }

echo "== 装了根 CA 后，HTTPS 源应能通过代理 =="
for d in repo.openeuler.org mirrors.aliyun.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "$CA" --resolve "${d}:443:${TARGET}" \
    "https://${d}/" --max-time 20 2>/dev/null) || code="000"
  if [[ "$code" =~ ^(200|301|302|403|404)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code（证书或连接失败）"
    fail=1
  fi
done

echo "== 不装根 CA 时应被拒绝（证明 MITM 生效，且非直连上游）=="
if curl -s -o /dev/null --resolve "repo.openeuler.org:443:${TARGET}" \
     "https://repo.openeuler.org/" --max-time 15 2>/dev/null; then
  echo "  ❌ 未装 CA 竟然通过了 —— 证书链有问题或流量未经过代理"
  fail=1
else
  echo "  ✅ 未装 CA 被正确拒绝"
fi

if [[ $fail -eq 0 ]]; then echo "TLS-ALL-PASS"; else echo "TLS-HAS-FAILURE"; fi
exit $fail
