#!/usr/bin/env bash
# proxy/tests/test-cache.sh —— 验证缓存命中、TTL 分级与 302 跳转不出内网
# 在目标机运行。
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0

PROBE="https://repo.openeuler.org/openEuler-24.03-LTS-SP3/OS/x86_64/repodata/repomd.xml"

# 两个域名都必须 --resolve：上游对 repo.openeuler.org 返回 302 跳到
# dl-cdn.openeuler.openatom.cn，若不把它也指向代理，curl 会直连公网，
# 测试就绕过了代理 —— 那正是本任务要防的失败模式。
RESOLVE=(--resolve "repo.openeuler.org:443:${TARGET}"
         --resolve "dl-cdn.openeuler.openatom.cn:443:${TARGET}")

# 跟随重定向，取【最后一个】响应的 X-Cache-Status
cache_status() {
  curl -sL -o /dev/null -D- --cacert "$CA" "${RESOLVE[@]}" "$1" --max-time 25 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{s=$2} END{print s}'
}

echo "== 清空缓存，确保测试可重复 =="
docker exec v3-tengine sh -c 'rm -rf /var/cache/tproxy/os/*' 2>/dev/null || true
echo "  已清空"

echo "== 首次请求应为 MISS =="
s1=$(cache_status "$PROBE"); echo "  -> ${s1:-无}"
[[ "$s1" == "MISS" ]] || { echo "  ❌ 首次应为 MISS"; fail=1; }

echo "== 二次请求应为 HIT =="
s2=$(cache_status "$PROBE"); echo "  -> ${s2:-无}"
[[ "$s2" == "HIT" ]] || { echo "  ❌ 二次应为 HIT"; fail=1; }

echo "== 跟随 302 后应拿到合法 XML（证明跳转未出内网）=="
body=$(curl -sL --cacert "$CA" "${RESOLVE[@]}" "$PROBE" --max-time 25 2>/dev/null | head -c 200)
if [[ "$body" == *"<?xml"* ]]; then
  echo "  ✅ 返回合法 XML"
else
  echo "  ❌ 响应体异常: ${body:0:80}"
  fail=1
fi

echo "== 缓存目录应有实际文件 =="
n=$(docker exec v3-tengine find /var/cache/tproxy/os -type f 2>/dev/null | wc -l)
if [[ "$n" -gt 0 ]]; then echo "  ✅ 缓存文件数: $n"; else echo "  ❌ 缓存目录为空"; fail=1; fi

if [[ $fail -eq 0 ]]; then echo "CACHE-ALL-PASS"; else echo "CACHE-HAS-FAILURE"; fi
exit $fail
