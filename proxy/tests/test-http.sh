#!/usr/bin/env bash
# proxy/tests/test-http.sh —— 验证 HTTP 分流与缓存头
# 在目标机（tengine 所在机器）运行
set -uo pipefail
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0

echo "== HTTP 分流与缓存头 =="
for h in archive.ubuntu.com mirrors.aliyun.com; do
  hdr=$(curl -s -o /dev/null -D- -H "Host: $h" "http://$TARGET/" --max-time 20 2>&1)
  code=$(echo "$hdr" | grep -oP '^HTTP/\S+ \K\d+' | head -1)
  cache=$(echo "$hdr" | grep -i '^x-cache-status' | tr -d '\r' | awk '{print $2}')
  if [[ "$code" =~ ^(200|301|302|403|404)$ ]]; then
    echo "  ✅ $h -> HTTP $code (cache=${cache:-n/a})"
  else
    echo "  ❌ $h -> HTTP ${code:-无响应}"
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then echo "HTTP-ALL-PASS"; else echo "HTTP-HAS-FAILURE"; fi
exit $fail
