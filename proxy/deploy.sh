#!/usr/bin/env bash
# proxy/deploy.sh —— 一键部署核心代理层
set -euo pipefail
cd "$(dirname "$0")"

echo "== 1/5 检查参数 =="
[[ -f .env ]] || { echo "❌ 缺少 .env"; exit 1; }
# shellcheck disable=SC1091
source .env
echo "   HOST_IP=$HOST_IP  CACHE_BASE=$CACHE_BASE"

echo "== 2/5 准备缓存目录 =="
# 容器内 /var/cache/tproxy 挂载自此处，nginx 会在其中自动创建 os/ 子目录
if [[ ! -d "${CACHE_BASE}/nginx" ]]; then
  sudo mkdir -p "${CACHE_BASE}/nginx"
fi
sudo chmod 755 "${CACHE_BASE}" "${CACHE_BASE}/nginx" 2>/dev/null || true
echo "   ${CACHE_BASE}/nginx 就绪"

echo "== 3/5 检查证书 =="
if [[ ! -f ca/tproxy-ca.crt ]]; then
  echo "   根 CA 不存在，正在生成..."
  ( cd ca && ./gen-ca.sh )
  while read -r d; do
    [[ -z "$d" || "$d" == \#* ]] && continue
    ( cd ca && ./gen-cert.sh "$d" )
  done < ca/domains.txt
fi
echo "   证书文件数: $(ls ca/certs/*.crt 2>/dev/null | wc -l)"

echo "== 4/5 校验 compose =="
docker compose config >/dev/null && echo "   语法 OK"

echo "== 5/5 启动服务 =="
docker compose up -d
sleep 10
docker compose ps

echo
echo "✅ 部署完成。后续步骤："
echo "   1. 客户端安装根 CA：$(pwd)/ca/tproxy-ca.crt"
echo "   2. 客户端 DNS 指向：$HOST_IP"
echo "   3. 运行自检：./tests/acceptance.sh"
