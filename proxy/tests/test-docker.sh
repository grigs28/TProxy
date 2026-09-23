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

echo "== ⚠️ 认证流程端到端（这才是缓存可用的证据）=="
# 上面的 /v2/ 断言无法区分「认证被正确透传」与「客户端永远拿到 401」。
# 真正能证明可用的是：取匿名 token → 带 token 拉 manifest 得 200。
TOKEN=$(curl -s --cacert "$CA" --resolve "auth.docker.io:443:${TARGET}" \
  "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull" \
  --max-time 30 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
if [[ -n "$TOKEN" ]]; then
  echo "  ✅ 取得匿名 token（auth.docker.io 透传正常）"
  mcode=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
    --resolve "registry-1.docker.io:443:${TARGET}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/library/alpine/manifests/latest" --max-time 40 2>/dev/null) || mcode="000"
  if [[ "$mcode" == "200" ]]; then
    echo "  ✅ 带 token 拉 manifest -> HTTP 200"
  else
    echo "  ❌ 带 token 拉 manifest -> HTTP $mcode"
    fail=1
  fi
else
  echo "  ❌ 未取得 token —— 认证端点未被正确透传"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "DOCKER-ALL-PASS"; else echo "DOCKER-HAS-FAILURE"; fi
exit $fail
