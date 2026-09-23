#!/usr/bin/env bash
# proxy/ca/gen-ca.sh —— 生成 TProxy 根 CA
#
# 环境变量：
#   DAYS=<天数>   根 CA 有效期，默认 10950（约 30 年）
#   FORCE=1       已存在时也重新生成
#
# ⚠️ FORCE=1 会**换掉整个信任锚**：所有域名证书立即失效、每台客户端都要重装。
#    管理界面的「更换根 CA」用的就是它 —— 那一步会连带重签全部叶子证书。
#
# 【原子替换】与 gen-cert.sh 同理：先在工作目录生成，最后才 mv 落位。
# 直接往 ca/ 里写的话，`openssl genrsa -out tproxy-ca.key` 会立刻截断现有根私钥，
# 一旦后续失败就既没有新根也没有旧根 —— 全部客户端与全部域名证书同时失效，
# 且无从恢复。
set -euo pipefail
cd "$(dirname "$0")"

DAYS="${DAYS:-10950}"

if [[ -f tproxy-ca.crt && "${FORCE:-0}" != "1" ]]; then
  echo "根 CA 已存在，跳过。如需重建请先删除 tproxy-ca.crt 与 tproxy-ca.key"
  exit 0
fi

WORK="$(mktemp -d .rebuild.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

openssl genrsa -out "$WORK/tproxy-ca.key" 4096
openssl req -x509 -new -nodes -key "$WORK/tproxy-ca.key" -sha256 -days "$DAYS" \
  -subj "/C=CN/O=TProxy/CN=TProxy Root CA" \
  -out "$WORK/tproxy-ca.crt"

# 属主跟随本目录，权限保留 openssl 的默认（私钥 600）。
# 容器里以 root 生成时，不这么做会让目标机上的文件变成 root 所有，
# 之后 rsync --inplace 就再也写不进去（详见 gen-cert.sh 里的同类说明）。
for f in key crt; do
  chown --reference=. "$WORK/tproxy-ca.$f" 2>/dev/null || true
done

mv -f "$WORK/tproxy-ca.key" tproxy-ca.key
mv -f "$WORK/tproxy-ca.crt" tproxy-ca.crt
# 旧的序列号文件对新根没有意义，留着会让新签的证书序列号与旧的重叠
rm -f tproxy-ca.srl

echo "✅ 根 CA 已生成（有效期 ${DAYS} 天）："
echo "   证书: $(pwd)/tproxy-ca.crt   ← 分发到客户端安装"
echo "   私钥: $(pwd)/tproxy-ca.key   ← 严禁泄露、严禁入库"
