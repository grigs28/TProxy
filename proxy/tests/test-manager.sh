#!/usr/bin/env bash
# proxy/tests/test-manager.sh —— 验证管理界面可用且数据真实
#
# 两条断言原则（都来自本项目踩过的坑）：
#   1. 断言「内容」而非「接口返回 200」—— 旧 proxy-manager 正是接口正常、
#      界面全空、不报任何错。
#   2. 断言「缓存目录被正确识别」—— 曾因路径映射错误，界面把已有 75MB 数据的
#      os 缓存报成「未启用」，而当时的验收脚本只数了 type 个数，全绿放过。
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
cache_json=$(curl -s --max-time 10 "$BASE/api/cache" 2>/dev/null)
n=$(grep -o '"type"' <<<"$cache_json" | wc -l)
if [[ "$n" -eq 6 ]]; then
  echo "  ✅ 六类"
else
  echo "  ❌ 期望 6 类，实际 $n"
  fail=1
fi

echo "== 缓存的启用状态必须与真实目录一致 =="
# 逐类核对界面报告 vs 磁盘实际 —— 这是曾漏过 Critical 的地方：
# 界面按错误的路径统计，把有数据的缓存报成「未启用」，而只数 type 个数的
# 断言完全看不出来。
while read -r t path; do
  [[ -z "$t" ]] && continue
  # 从 API 响应里取该类的 enabled/bytes
  reported=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
for x in d['types']:
    if x['type']=='$t':
        print(('true' if x['enabled'] else 'false') + ' ' + str(x['bytes']))
        break
" "$cache_json" 2>/dev/null || echo "missing 0")

  rep_enabled="${reported%% *}"
  rep_bytes="${reported##* }"
  real_path="/mnt/HDD/tproxy-cache/$path"

  if [[ -d "$real_path" ]]; then
    real_bytes=$(du -sb "$real_path" 2>/dev/null | awk '{print $1}')
    if [[ "$rep_enabled" == "true" ]]; then
      echo "  ✅ $t: 已启用，界面 $rep_bytes / 磁盘 ${real_bytes:-?} 字节"
    else
      echo "  ❌ $t: 磁盘上 $real_path 存在（${real_bytes:-?} 字节），界面却报「未启用」"
      fail=1
    fi
  else
    if [[ "$rep_enabled" == "false" ]]; then
      echo "  ✅ $t: 未启用（与磁盘一致）"
    else
      echo "  ❌ $t: 磁盘上 $real_path 不存在，界面却报「已启用」"
      fail=1
    fi
  fi
done <<'PATHS'
os nginx/os
python nginx/python
nodejs nginx/nodejs
java nginx/java
registry registry
git git
PATHS

echo "== 劫持规则应非空 =="
r=$(curl -s --max-time 10 "$BASE/api/rules" 2>/dev/null | grep -o '"domain"' | wc -l)
if [[ "$r" -gt 0 ]]; then
  echo "  ✅ 解析出 $r 条劫持规则"
else
  echo "  ❌ 劫持规则为空 —— 解析器可能未匹配实际配置格式"
  fail=1
fi

echo "== 域名列表不得混入假值 =="
# `proxy_ssl_server_name on;` 曾让 "on" 混进域名列表
if curl -s --max-time 10 "$BASE/api/rules" 2>/dev/null | grep -q '"on"'; then
  echo "  ❌ 域名列表出现 \"on\" —— server_name 正则误匹配了 proxy_ssl_server_name"
  fail=1
else
  echo "  ✅ 无假域名"
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
