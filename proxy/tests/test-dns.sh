#!/usr/bin/env bash
# proxy/tests/test-dns.sh —— 验证 DNS 劫持、内网解析与上游兜底
set -uo pipefail
HOST_IP="${HOST_IP:-192.168.0.18}"
DIG="dig +time=2 +tries=1 @127.0.0.1"
fail=0

check() {  # check <描述> <期望> <实际>
  if [[ "$2" == "$3" ]]; then
    echo "  ✅ $1"
  else
    echo "  ❌ $1: 期望[$2] 实际[$3]"
    fail=1
  fi
}

# 本任务（计划 A / Task 2）范围仅限「系统包」域名。
# Java/Python/Node 的劫持在计划 B 加入，此处不测——否则是测超出交付范围的行为。
echo "== 劫持测试（应全部返回 $HOST_IP）=="
for d in repo.openeuler.org mirrors.openeuler.org dl-cdn.openeuler.openatom.cn \
         archive.ubuntu.com security.ubuntu.com cn.archive.ubuntu.com ports.ubuntu.com \
         mirror.centos.org mirrorlist.centos.org dl.fedoraproject.org mirrors.fedoraproject.org \
         mirrors.aliyun.com mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.huaweicloud.com; do
  check "$d" "$HOST_IP" "$($DIG "$d" +short | head -1)"
done

echo "== 内网域名测试（应返回 2 条 A 记录）=="
n=$($DIG nt08.sxsy +short | grep -c '^192\.168\.0\.' || true)
check "nt08.sxsy 记录数" "2" "$n"
check "nt08.sxsy 小写" "192.168.0.38" "$($DIG nt08.sxsy +short | sort | head -1)"
check "NT08.sxsy 大写等价" "192.168.0.38" "$($DIG NT08.sxsy +short | sort | head -1)"

echo "== 上游兜底测试（未劫持域名应能解析）=="
# 注意：+short 会先输出 CNAME 行，必须过滤出纯 IP 行
r=$($DIG www.baidu.com +short | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
if [[ -n "$r" ]]; then
  echo "  ✅ 上游兜底正常 ($r)"
else
  echo "  ❌ 上游兜底失败"
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "DNS-ALL-PASS"
else
  echo "DNS-HAS-FAILURE"
fi
exit $fail
