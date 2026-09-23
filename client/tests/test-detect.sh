#!/usr/bin/env bash
# client/tests/test-detect.sh —— 验证发行版与 DNS 机制检测
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/detect.sh
source "$DIR/lib/detect.sh"

fail=0

echo "== 发行版检测 =="
d=$(detect_distro)
if [[ "$d" =~ ^(ubuntu|rhel)$ ]]; then
  echo "  ✅ 检测到: $d"
else
  echo "  ❌ 未识别的发行版: $d"
  fail=1
fi

echo "== DNS 管理机制检测 =="
m=$(detect_dns_manager)
if [[ "$m" =~ ^(systemd-resolved|networkmanager|resolvconf|unknown)$ ]]; then
  echo "  ✅ 检测到: $m"
else
  echo "  ❌ 异常返回值: $m"
  fail=1
fi

echo "== 检测函数不得依赖未定义的外部变量 =="
# 用 env -i 模拟最简环境，确保函数不依赖调用方的环境
if env -i bash -c "source '$DIR/lib/detect.sh'; detect_distro" >/dev/null 2>&1; then
  echo "  ✅ 在干净环境下可运行"
else
  echo "  ❌ 干净环境下失败（可能依赖了外部变量）"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "DETECT-PASS"; else echo "DETECT-FAIL"; fi
exit $fail
