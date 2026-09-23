#!/usr/bin/env bash
# proxy/tests/test-nodejs.sh —— 验证 npm 缓存
# 在目标机运行。
#
# ⚠️ npm 元数据响应带 Content-Encoding: gzip，必须用 --compressed，
# 否则 curl 拿到压缩字节流、JSON 解析必然失败 —— 这正是要覆盖的失败模式。
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0
RESOLVE=(--resolve "registry.npmjs.org:443:${TARGET}")

echo "== npm 站点应能通过代理访问 =="
for d in registry.npmjs.org registry.npmmirror.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
    --resolve "${d}:443:${TARGET}" "https://${d}/" --max-time 30 2>/dev/null) || code="000"
  if [[ "$code" =~ ^(200|301|302|404)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code"
    fail=1
  fi
done

echo "== 元数据 JSON 应能正确获取与解压 =="
body=$(curl -sL --compressed --cacert "$CA" "${RESOLVE[@]}" \
  "https://registry.npmjs.org/express" --max-time 30 2>/dev/null | head -c 200)
if [[ "$body" == *'"name"'* ]]; then
  echo "  ✅ 返回合法 JSON（gzip 解压正常）"
else
  echo "  ❌ 响应异常: ${body:0:80}"
  fail=1
fi

echo "== 缓存应能进入 HIT（容忍后台更新窗口）=="
s=""
for i in 1 2 3 4 5; do
  s=$(curl -sL -o /dev/null -D- --compressed --cacert "$CA" "${RESOLVE[@]}" \
      "https://registry.npmjs.org/express" --max-time 30 2>/dev/null \
      | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{v=$2} END{print v}')
  echo "  第 $i 次 -> ${s:-无}"
  [[ "$s" == "HIT" ]] && break
  sleep 3
done
[[ "$s" == "HIT" ]] || { echo "  ❌ 5 次后仍未 HIT"; fail=1; }

if [[ $fail -eq 0 ]]; then echo "NODEJS-ALL-PASS"; else echo "NODEJS-HAS-FAILURE"; fi
exit $fail
