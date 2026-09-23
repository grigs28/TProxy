#!/usr/bin/env bash
# proxy/tests/test-cache.sh —— 验证缓存命中、TTL 分级与 302 跳转不出内网
# 在目标机运行。
#
# 注意：本脚本【不清空缓存】。先前的实现会 rm -rf 整个缓存目录，而 acceptance.sh
# 又串联了本脚本、OPERATIONS.md 更把它列为「日常自检」——运维在生产机上例行自检
# 就会清空数百 GB 缓存并引发回源风暴。测试不应破坏被测系统。
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

cache_status() {
  curl -sL -o /dev/null -D- --cacert "$CA" "${RESOLVE[@]}" "$1" --max-time 25 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{s=$2} END{print s}'
}

echo "== 元数据 TTL 分级：正则必须覆盖 zstd 索引 =="
cfg=$(docker exec v3-tengine nginx -T 2>/dev/null || echo "")
meta_line=$(echo "$cfg" | grep -o 'location ~\* /(repodata[^)]*)' | head -1)
if echo "$meta_line" | grep -q 'zst'; then
  echo "  ✅ 元数据正则覆盖 zst"
else
  echo "  ❌ 元数据正则未覆盖 zst"
  echo "     后果：Packages.zst / Contents-amd64.zst 会命中制品规则被缓存 365 天，"
  echo "     客户端一年内看不到新包，且 apt update 不报任何错。"
  fail=1
fi

echo "== 首次请求（仅记录，不断言——缓存可能已有内容）=="
s1=$(cache_status "$PROBE"); echo "  -> ${s1:-无}"

echo "== 二次请求必须为 HIT =="
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
