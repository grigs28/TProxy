#!/usr/bin/env bash
# client/tests/test-ca-install.sh —— 验证 CA 安装函数与域名清单
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/ca.sh
source "$DIR/lib/ca.sh"

fail=0

echo "== 所需函数应已定义 =="
for fn in install_system_ca install_docker_ca install_java_ca; do
  if declare -F "$fn" >/dev/null; then
    echo "  ✅ $fn"
  else
    echo "  ❌ 缺少函数 $fn"
    fail=1
  fi
done

echo "== Docker 域名清单应为 9 个 =="
n=$(docker_ca_domains | grep -c .)
if [[ "$n" -eq 9 ]]; then
  echo "  ✅ 9 个域名"
else
  echo "  ❌ 期望 9，实际 $n"
  fail=1
fi

echo "== 域名清单应与 dnsmasq 劫持的一致 =="
# Docker 客户端不读系统 CA 库，CA 必须按域名逐个放入 certs.d；
# 漏一个域名就会导致该仓库拉取时报证书错误
for d in registry-1.docker.io auth.docker.io quay.io ghcr.io gcr.io; do
  if docker_ca_domains | grep -qx "$d"; then
    echo "  ✅ $d"
  else
    echo "  ❌ 缺少 $d"
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then echo "CAINST-PASS"; else echo "CAINST-FAIL"; fi
exit $fail
