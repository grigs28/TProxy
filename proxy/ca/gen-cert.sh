#!/usr/bin/env bash
# proxy/ca/gen-cert.sh <域名> [域名2 ...] —— 用根 CA 为域名签发证书
#
# 环境变量 DAYS 控制有效期（默认 3650 天）。
#
# 【原子替换】先在整个临时目录里签好，最后才 mv 进 certs/。
#
# 不能直接往 certs/ 里写。实测（根 CA 私钥不可用时的旧脚本行为）：
#   `openssl genrsa -out certs/X.key`   立刻截断旧私钥
#   `openssl x509 -req -out certs/X.crt` 在报错【之前】就把旧证书清成 0 字节
# 结果是该域名的 .crt 与 .key 双双被清空，HTTPS 彻底失效，
# 而现场完全看不出是「一次失败的重新签发」造成的。
#
# mv 在同一文件系统内是 rename，原子的；失败时 trap 清掉临时目录，
# certs/ 一个字节都没动过。
set -euo pipefail
cd "$(dirname "$0")"
[[ $# -ge 1 ]] || { echo "用法: $0 <域名> [域名2 ...]" >&2; exit 1; }
[[ -f tproxy-ca.key ]] || { echo "❌ 缺少根 CA，请先运行 gen-ca.sh" >&2; exit 1; }

mkdir -p certs
DOMAIN="$1"
CNT=$#
DAYS="${DAYS:-3650}"

SAN=""
for d in "$@"; do SAN="${SAN}DNS:${d},"; done
SAN="${SAN%,}"

WORK="$(mktemp -d certs/.sign.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

openssl genrsa -out "$WORK/${DOMAIN}.key" 2048
openssl req -new -key "$WORK/${DOMAIN}.key" -subj "/CN=${DOMAIN}" \
  -out "$WORK/${DOMAIN}.csr"
cat > "$WORK/${DOMAIN}.ext" <<EOF
subjectAltName=${SAN}
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in "$WORK/${DOMAIN}.csr" -CA tproxy-ca.crt -CAkey tproxy-ca.key \
  -CAcreateserial -out "$WORK/${DOMAIN}.crt" -days "$DAYS" -sha256 \
  -extfile "$WORK/${DOMAIN}.ext"

# 全部成功才落位。权限沿用旧文件（若存在），否则跟随当前 umask ——
# 刻意的：tengine 的 worker 以非 root 身份读取证书文件，
# 收紧权限会让 HTTPS 静默失效。
if [[ -f "certs/${DOMAIN}.key" ]]; then
  chmod --reference="certs/${DOMAIN}.key" "$WORK/${DOMAIN}.key" 2>/dev/null || true
  chmod --reference="certs/${DOMAIN}.crt" "$WORK/${DOMAIN}.crt" 2>/dev/null || true
fi
mv -f "$WORK/${DOMAIN}.key" "certs/${DOMAIN}.key"
mv -f "$WORK/${DOMAIN}.crt" "certs/${DOMAIN}.crt"

echo "✅ 已签发 ${DOMAIN}（含 ${CNT} 个 SAN，有效期 ${DAYS} 天）"
