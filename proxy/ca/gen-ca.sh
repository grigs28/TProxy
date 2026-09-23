#!/usr/bin/env bash
# proxy/ca/gen-ca.sh —— 生成 TProxy 根 CA（仅需执行一次）
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f tproxy-ca.crt ]]; then
  echo "根 CA 已存在，跳过。如需重建请先删除 tproxy-ca.crt 与 tproxy-ca.key"
  exit 0
fi

openssl genrsa -out tproxy-ca.key 4096
openssl req -x509 -new -nodes -key tproxy-ca.key -sha256 -days 3650 \
  -subj "/C=CN/O=TProxy/CN=TProxy Root CA" \
  -out tproxy-ca.crt

echo "✅ 根 CA 已生成："
echo "   证书: $(pwd)/tproxy-ca.crt   ← 分发到客户端安装"
echo "   私钥: $(pwd)/tproxy-ca.key   ← 严禁泄露、严禁入库"
