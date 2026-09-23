#!/usr/bin/env bash
# proxy/tests/test-ca.sh —— 验证根 CA 与全部域名证书链
set -uo pipefail
cd "$(dirname "$0")/../ca"

[[ -f tproxy-ca.crt ]] || { echo "❌ 缺少根 CA"; echo "CA-VERIFY-FAIL"; exit 1; }

fail=0
n=0
for c in certs/*.crt; do
  [[ -e "$c" ]] || { echo "❌ 无域名证书"; echo "CA-VERIFY-FAIL"; exit 1; }
  if openssl verify -CAfile tproxy-ca.crt "$c" >/dev/null 2>&1; then
    n=$((n+1))
  else
    echo "  ❌ 验证失败: $c"
    fail=1
  fi
done

echo "  通过 $n 张证书"

# 私钥不得入库（安全红线）
repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -n "$repo" ]] && git -C "$repo" ls-files 'proxy/ca/' 2>/dev/null | grep -q '\.key$'; then
  echo "  ❌ 私钥已被 git 跟踪！"
  fail=1
else
  echo "  ✅ 私钥未被 git 跟踪"
fi

if [[ $fail -eq 0 && $n -gt 0 ]]; then
  echo "CA-VERIFY-PASS"
else
  echo "CA-VERIFY-FAIL"
fi
exit $fail
