#!/usr/bin/env bash
# proxy/tests/test-manager.sh —— 验证管理界面可用且数据非空
#
# 重点不在「接口返回 200」，而在「返回的数据是否真有内容」——
# 旧 proxy-manager 的教训正是「接口正常、界面全空、不报任何错」。
set -uo pipefail
PORT="${TPROXY_MANAGER_PORT:-5557}"
BASE="http://127.0.0.1:${PORT}"
fail=0

echo "== 管理端应可访问 =="
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/api/status" 2>/dev/null) || code="000"
if [[ "$code" == "200" ]]; then
  echo "  ✅ /api/status -> 200"
else
  echo "  ❌ /api/status -> $code（管理端未运行？）"
  echo "MANAGER-HAS-FAILURE"
  exit 1
fi

echo "== 缓存总览应返回六类 =="
n=$(curl -s --max-time 10 "$BASE/api/cache" 2>/dev/null | grep -o '"type"' | wc -l)
if [[ "$n" -eq 6 ]]; then
  echo "  ✅ 六类"
else
  echo "  ❌ 期望 6 类，实际 $n"
  fail=1
fi

echo "== 劫持规则应非空 =="
# 空列表意味着解析失败 —— 必须显式判失败，而不是放过
r=$(curl -s --max-time 10 "$BASE/api/rules" 2>/dev/null | grep -o '"domain"' | wc -l)
if [[ "$r" -gt 0 ]]; then
  echo "  ✅ 解析出 $r 条劫持规则"
else
  echo "  ❌ 劫持规则为空 —— 解析器可能未匹配实际配置格式"
  fail=1
fi

echo "== 证书应非空 =="
c=$(curl -s --max-time 10 "$BASE/api/certs" 2>/dev/null | grep -o '"domain"' | wc -l)
if [[ "$c" -gt 0 ]]; then
  echo "  ✅ 列出 $c 张证书"
else
  echo "  ❌ 证书列表为空"
  fail=1
fi

echo "== 首页应可加载 =="
hcode=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/" 2>/dev/null) || hcode="000"
if [[ "$hcode" == "200" ]]; then
  echo "  ✅ 首页 200"
else
  echo "  ❌ 首页 $hcode"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "MANAGER-ALL-PASS"; else echo "MANAGER-HAS-FAILURE"; fi
exit $fail
