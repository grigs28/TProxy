#!/usr/bin/env bash
# proxy/tests/test-python.sh —— 验证 PyPI 缓存
# 在目标机运行。
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0
RESOLVE=(--resolve "pypi.org:443:${TARGET}" --resolve "files.pythonhosted.org:443:${TARGET}")

cache_status() {
  curl -sL -o /dev/null -D- --cacert "$CA" "${RESOLVE[@]}" "$1" --max-time 30 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{s=$2} END{print s}'
}

echo "== PyPI 站点应能通过代理访问 =="
for d in pypi.org files.pythonhosted.org; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
    --resolve "${d}:443:${TARGET}" "https://${d}/" --max-time 30 2>/dev/null) || code="000"
  if [[ "$code" =~ ^(200|301|302|404)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code"
    fail=1
  fi
done

echo "== simple 索引应能缓存（容忍后台更新窗口）=="
s=""
for i in 1 2 3 4 5; do
  s=$(cache_status "https://pypi.org/simple/pip/")
  echo "  第 $i 次 -> ${s:-无}"
  [[ "$s" == "HIT" ]] && break
  sleep 3
done
[[ "$s" == "HIT" ]] || { echo "  ❌ 5 次后仍未 HIT"; fail=1; }

echo "== 索引内容应为合法 HTML（PyPI simple 索引是 HTML 页面）=="
# 只取前 150 字节会落在 <head> 里，看不到包名 —— 因此判断「是 HTML 文档」而非「含 pip 字样」
body=$(curl -sL --cacert "$CA" "${RESOLVE[@]}" "https://pypi.org/simple/pip/" --max-time 30 2>/dev/null | head -c 300)
if [[ "$body" == *"<!DOCTYPE html"* || "$body" == *"<html"* ]]; then
  echo "  ✅ 索引返回 HTML 文档"
else
  echo "  ❌ 索引内容异常: ${body:0:60}"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "PYTHON-ALL-PASS"; else echo "PYTHON-HAS-FAILURE"; fi
exit $fail
