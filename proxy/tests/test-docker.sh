#!/usr/bin/env bash
# proxy/tests/test-docker.sh —— 验证 Docker 镜像缓存透明可用
# 在目标机运行。
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0

# Docker Registry v2 API：/v2/ 返回 200 或 401 都表示 registry 正常工作
# （401 是要求 token 认证的正常响应，不是故障）
echo "== Docker 上游应能通过代理访问 =="
for d in registry-1.docker.io quay.io ghcr.io; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "$CA" --resolve "${d}:443:${TARGET}" \
    "https://${d}/v2/" --max-time 25 2>/dev/null) || code="000"
  if [[ "$code" =~ ^(200|401|403)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code（registry 未正常工作）"
    fail=1
  fi
done

echo "== 本机 registry 缓存服务应监听 5001 =="
if docker exec v3-tengine sh -c 'wget -q -O- http://127.0.0.1:5001/v2/ >/dev/null 2>&1'; then
  echo "  ✅ 5001 有响应"
else
  echo "  ❌ 5001 无响应（registry 容器未就绪？）"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "DOCKER-ALL-PASS"; else echo "DOCKER-HAS-FAILURE"; fi
exit $fail
