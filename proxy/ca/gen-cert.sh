#!/usr/bin/env bash
# proxy/ca/gen-cert.sh <域名> [域名2 ...] —— 用根 CA 为域名签发证书
set -euo pipefail
cd "$(dirname "$0")"
[[ $# -ge 1 ]] || { echo "用法: $0 <域名> [域名2 ...]"; exit 1; }
[[ -f tproxy-ca.key ]] || { echo "❌ 缺少根 CA，请先运行 gen-ca.sh"; exit 1; }

mkdir -p certs
DOMAIN="$1"
CNT=$#
SAN=""
for d in "$@"; do SAN="${SAN}DNS:${d},"; done
SAN="${SAN%,}"

openssl genrsa -out "certs/${DOMAIN}.key" 2048
openssl req -new -key "certs/${DOMAIN}.key" -subj "/CN=${DOMAIN}" \
  -out "certs/${DOMAIN}.csr"
cat > "certs/${DOMAIN}.ext" <<EOF
subjectAltName=${SAN}
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in "certs/${DOMAIN}.csr" -CA tproxy-ca.crt -CAkey tproxy-ca.key \
  -CAcreateserial -out "certs/${DOMAIN}.crt" -days 3650 -sha256 \
  -extfile "certs/${DOMAIN}.ext"
rm -f "certs/${DOMAIN}.csr" "certs/${DOMAIN}.ext"
echo "✅ 已签发 ${DOMAIN}（含 ${CNT} 个 SAN）"
