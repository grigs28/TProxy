#!/usr/bin/env bash
# proxy/tests/test-git.sh —— 验证 git 缓存代理
# 在目标机运行。
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0

echo "== git 站点应能通过代理访问 =="
for d in github.com gitlab.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "$CA" --resolve "${d}:443:${TARGET}" \
    "https://${d}/" --max-time 30 2>/dev/null) || code="000"
  if [[ "$code" =~ ^(200|301|302|404)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code"
    fail=1
  fi
done

echo "== 本机 gitcache 应在 4999 监听 =="
# 用端口监听判断，而非请求 / —— gitcache 不是网页服务器，根路径不对它做响应
if ss -tln 2>/dev/null | grep -q ':4999 '; then
  echo "  ✅ 4999 已监听"
else
  echo "  ❌ 4999 未监听（gitcache 未启动）"
  fail=1
fi

echo "== git 智能 HTTP 端点（info/refs）应可达 =="
# 这是 git clone 的入口，也是 gitcache 真正处理的路径。
# 首次请求 gitcache 需回源建立镜像，可能较慢，故超时放宽。
code=$(curl -s -o /dev/null -w '%{http_code}' \
  --cacert "$CA" --resolve "github.com:443:${TARGET}" \
  "https://github.com/git/git.git/info/refs?service=git-upload-pack" \
  --max-time 60 2>/dev/null) || code="000"
if [[ "$code" =~ ^(200|301|302)$ ]]; then
  echo "  ✅ info/refs -> HTTP $code"
else
  echo "  ❌ info/refs -> HTTP $code"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "GIT-ALL-PASS"; else echo "GIT-HAS-FAILURE"; fi
exit $fail
