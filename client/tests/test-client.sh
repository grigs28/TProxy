#!/usr/bin/env bash
# client/tests/test-client.sh —— 在【客户端】验证接入效果
#
# 与前缀 test-*.sh 的服务端测试不同：本脚本验证的是「这台机器接入后能否
# 透明命中缓存」，必须在已执行 client-setup.sh 的客户端上运行。
set -uo pipefail
TPROXY_SERVER="${TPROXY_SERVER:-192.168.0.18}"
DIG="dig +time=3 +tries=1"
fail=0

echo "== DNS 应指向 $TPROXY_SERVER =="
for d in repo.openeuler.org registry-1.docker.io pypi.org registry.npmjs.org repo1.maven.org github.com; do
  ip=$($DIG +short "$d" 2>/dev/null | grep -E '^[0-9]' | head -1)
  if [[ "$ip" == "$TPROXY_SERVER" ]]; then
    echo "  ✅ $d -> $ip"
  else
    echo "  ❌ $d -> ${ip:-解析失败}（期望 $TPROXY_SERVER）"
    fail=1
  fi
done

echo "== 公网兜底：未劫持域名应能正常解析 =="
# 这条验证「.18 之外还有可用的 DNS」——若失败，说明 .18 挂掉时本机会断网
r=$($DIG +short www.baidu.com 2>/dev/null | grep -E '^[0-9]' | head -1)
if [[ -n "$r" ]]; then
  echo "  ✅ 兜底正常 ($r)"
else
  echo "  ❌ 兜底失败 —— .18 不可用时可能断网"
  fail=1
fi

echo "== 证书链应被信任（根 CA 已生效）=="
if curl -s -o /dev/null --max-time 20 "https://repo.openeuler.org/" 2>/dev/null; then
  echo "  ✅ HTTPS 校验通过"
else
  echo "  ❌ HTTPS 校验失败（根 CA 未生效？）"
  fail=1
fi

echo "== 实际下载应走代理（响应头带缓存标记或至少能连通）=="
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 \
  "https://registry.npmjs.org/express" 2>/dev/null) || code="000"
if [[ "$code" =~ ^(200|301|302)$ ]]; then
  echo "  ✅ npm 元数据可达 ($code)"
else
  echo "  ❌ npm 元数据不可达 ($code)"
  fail=1
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "CLIENT-PASS"
else
  echo "CLIENT-FAIL"
fi
exit $fail
