#!/usr/bin/env bash
# proxy/deploy.sh —— 一键部署核心代理层
set -euo pipefail
cd "$(dirname "$0")"

echo "== 1/6 检查参数 =="
[[ -f .env ]] || { echo "❌ 缺少 .env"; exit 1; }
# shellcheck disable=SC1091
source .env
echo "   HOST_IP=$HOST_IP  CACHE_BASE=$CACHE_BASE"

echo "== 2/6 准备缓存目录 =="
# 容器内 /var/cache/tproxy 挂载自 nginx/，nginx 会在其中自动创建 os/ 子目录
sudo mkdir -p "${CACHE_BASE}"/{nginx,git,registry/{docker,quay,gcr,ghcr,k8s-io,mcr}}
sudo chmod 755 "${CACHE_BASE}" 2>/dev/null || true
# gitcache 容器以 uid 1000 运行（见 gitcache/Dockerfile），
# 若目录由 docker 以 root 自动创建，它会无法写入、镜像建立失败。
# 本机曾被手工修好，推倒重部署即复发 —— 故在此显式处理。
sudo chown -R 1000:1000 "${CACHE_BASE}/git"
echo "   ${CACHE_BASE} 就绪（含 git 目录属主 1000:1000）"

echo "== 3/6 检查证书 =="
if [[ ! -f ca/tproxy-ca.crt ]]; then
  echo "   根 CA 不存在，正在生成..."
  ( cd ca && ./gen-ca.sh )
  # 一行可含多个域名：首个是 CN，其余进 SAN —— 与管理界面登记时的格式一致。
  # 若不认这种行，界面上签的带附加域名的证书在根 CA 重建后会丢掉 SAN。
  while read -r -a line; do
    if [[ ${#line[@]} -eq 0 || "${line[0]}" == \#* ]]; then continue; fi
    ( cd ca && ./gen-cert.sh "${line[@]}" )
  done < ca/domains.txt
fi
echo "   证书文件数: $(ls ca/certs/*.crt 2>/dev/null | wc -l)"

echo "== 4/6 校验 compose =="
docker compose config >/dev/null && echo "   语法 OK"

echo "== 5/6 放行防火墙 =="
# 必须的一步：firewalld 默认不放行 443，而 nginx 在监听 ——
# 表现为「服务端自测全绿、客户端 No route to host」。
# 旧环境曾开放 80 却漏了 443，客户端根本连不上 TLS 端口。
if systemctl is-active --quiet firewalld 2>/dev/null; then
  for p in 443/tcp 80/tcp 53/tcp 53/udp; do
    sudo firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 || true
  done
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
  echo "   已放行 443/tcp 80/tcp 53/tcp 53/udp"
else
  echo "   firewalld 未运行，跳过"
fi

echo "== 6/6 启动服务 =="
docker compose up -d
sleep 10
docker compose ps

echo
echo "== 部署后配置体检 =="
sudo ./tests/preflight.sh || true

echo
echo "✅ 部署完成。后续步骤："
echo "   1. 客户端安装根 CA：$(pwd)/ca/tproxy-ca.crt"
echo "   2. 客户端 DNS 指向：$HOST_IP"
echo "   3. 运行自检：./tests/acceptance.sh"
