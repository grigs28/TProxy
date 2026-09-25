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
         deb.debian.org security.debian.org download.proxmox.com \
         mirror.centos.org mirrorlist.centos.org dl.fedoraproject.org mirrors.fedoraproject.org \
         mirrors.aliyun.com mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.huaweicloud.com \
         mirrors.cloud.tencent.com nvidia.github.io developer.download.nvidia.com \
         cli.github.com; do
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

echo "== github.com 的子域必须【放行】（劫持了却不服务 = 把机器弄坏）=="
# ⚠️ `address=/github.com/` **连子域一起匹配**（dnsmasq 的语义），而 tengine
#    只服务 github.com 本身（见 tengine/conf.d/git.conf 的 server_name）。
#    于是 cli/api/codeload 这些子域被劫持到本机却拿不到匹配的证书 ——
#    实测 .14 的 dnf gh-cli 源（https://cli.github.com/packages/rpm）报
#      Curl error (35): SSL connect error ... tlsv1 alert internal error
#    这正是 registry.conf 里那条原则的另一面：
#    「若某域名无缓存实例，应同时从 dnsmasq 劫持清单和 server_name 中移除」。
#
#    下面断言这些例外**仍然存在**，防止被当成冗余配置清理掉。
#
#    ⚠️ 例外清单**不是固定的**：某个子域一旦被 tengine 服务（如 cli.github.com
#       后来补了服务块），就该从例外里移掉、加进上面的劫持断言 —— 两件事是一体的。
CONF="$(dirname "$0")/../dnsmasq/dnsmasq.conf"
for d in api.github.com codeload.github.com ssh.github.com gist.github.com; do
  n=$(grep -cE "^server=/${d//./\\.}/" "$CONF" 2>/dev/null)
  n=${n:-0}
  if [[ "$n" -ge 1 ]]; then
    echo "  ✅ $d 有放行规则（$n 条）"
  else
    echo "  ❌ $d 没有放行规则 —— 它会被劫持到本机却无人服务"
    fail=1
  fi
done

# ⚠️ 用**显式上游**，别用 `server=/域名/#`。
#    实测 `#` 会连带把 address=/github.com/ 的语义带偏：github.com 本身
#    开始从上游缓存答（日志 `cached github.com is 140.82.116.3`），劫持整个失效。
if grep -qE '^server=/[^/]+/#$' "$CONF" 2>/dev/null; then
  echo "  ❌ 用了 server=/域名/# —— 会把 address= 的语义带偏，请改显式上游"
  fail=1
else
  echo "  ✅ 未使用 server=/域名/# （显式上游）"
fi

# 而 github.com 本身仍必须被劫持
check "github.com 仍被劫持" "$HOST_IP" "$($DIG github.com +short | head -1)"

if [[ $fail -eq 0 ]]; then
  echo "DNS-ALL-PASS"
else
  echo "DNS-HAS-FAILURE"
fi
exit $fail
