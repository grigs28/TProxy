#!/usr/bin/env bash
# client-setup.sh —— 把本机接入 TProxy 透明缓存
#
# 用法:
#   sudo ./client-setup.sh                     # 从默认地址取根 CA
#   sudo ./client-setup.sh --ca /path/ca.crt   # 用本地 CA 文件（服务端不可达时）
#   sudo ./client-setup.sh --server 192.168.0.18
#   sudo ./client-setup.sh --rollback          # 回滚
#
# 脚本会修改：DNS 配置、系统信任库、Docker 证书目录、Java cacerts、运行时 CA bundle。
# --rollback 可撤销 DNS / 系统信任库 / Docker 部分；
# Java cacerts 与 systemd-resolved 的恢复需按回滚输出的提示手工处理。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/detect.sh
source "$DIR/lib/detect.sh"
# shellcheck source=lib/dns.sh
source "$DIR/lib/dns.sh"
# shellcheck source=lib/ca.sh
source "$DIR/lib/ca.sh"

TPROXY_SERVER="${TPROXY_SERVER:-192.168.0.18}"
# 导出：让其成为子进程（tests/test-client.sh）可见的环境变量，
# 否则自检仍按默认地址断言，用 --server 接入的机器会被误报为 CLIENT-FAIL
export TPROXY_SERVER
CA_FILE=""

# ---- 回滚（必须在参数解析之前定义，--rollback 会立即调用它）----
do_rollback() {
  echo "=== 回滚 TProxy 客户端配置 ==="

  # 恢复【首次】备份的原始配置（不是最近一次）
  restore_dns_config

  case "$(detect_distro)" in
    ubuntu)
      rm -f "/usr/local/share/ca-certificates/$CA_DEST_NAME"
      update-ca-certificates --fresh >/dev/null 2>&1 || true
      ;;
    rhel)
      rm -f "/etc/pki/ca-trust/source/anchors/$CA_DEST_NAME"
      update-ca-trust extract 2>/dev/null || true
      ;;
  esac
  echo "已从系统信任库移除 CA"

  # 只删我们安装的那些域名 —— 不能通配删除整个 certs.d，
  # 那会连带删掉用户为自己的私有 registry 配置的 CA（不可恢复）
  if [[ -d /etc/docker/certs.d ]]; then
    while read -r d; do
      [[ -z "$d" ]] && continue
      rm -f "/etc/docker/certs.d/$d/ca.crt" 2>/dev/null || true
      rmdir "/etc/docker/certs.d/$d" 2>/dev/null || true
    done < <(docker_ca_domains)
    echo "已移除 TProxy 的 Docker 证书（未触碰其他 CA；需重启 docker 生效）"
  fi

  # 运行时 CA bundle：按标记块精确删除追加内容
  remove_runtime_ca

  echo
  echo "⚠️  以下需手动处理："
  echo "   · Java cacerts：keytool -delete -alias tproxy-ca -keystore <JDK>/lib/security/cacerts"
  echo "   · systemd-resolved 若原为启用状态：systemctl enable --now systemd-resolved"
  echo "   · 若用 NetworkManager，连接配置里的 DNS 需手工改回："
  echo "     nmcli con mod <连接> ipv4.ignore-auto-dns no && nmcli con up <连接>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ca)       CA_FILE="${2:-}"; shift 2 ;;
    --server)   TPROXY_SERVER="${2:-}"; shift 2 ;;
    --rollback) do_rollback; exit 0 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *)          echo "未知参数: $1（用 --help 查看用法）"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "❌ 需要 root 权限（会修改 DNS 与系统信任库）。请用 sudo 运行。"
  exit 1
fi

echo "=== TProxy 客户端接入 ==="
echo "服务端  : $TPROXY_SERVER"
echo "发行版  : $(detect_distro)"
echo "DNS 机制: $(detect_dns_manager)"
echo

echo "== 1/4 配置 DNS =="
configure_dns
echo

echo "== 2/4 获取根 CA =="
if [[ -z "$CA_FILE" ]]; then
  CA_FILE="/tmp/tproxy-ca.crt"
  echo "从 http://${TPROXY_SERVER}/tproxy-ca.crt 下载..."
  # 先确保能解析到服务端（此时 DNS 已由本脚本配好）
  if ! curl -fsSL --max-time 20 "http://${TPROXY_SERVER}/tproxy-ca.crt" -o "$CA_FILE"; then
    echo "❌ 下载失败。可改用 --ca 指定本地 CA 文件，或确认服务端可达。"
    exit 1
  fi
fi
if ! openssl x509 -in "$CA_FILE" -noout -subject 2>/dev/null; then
  echo "❌ $CA_FILE 不是合法证书"
  exit 1
fi
openssl x509 -in "$CA_FILE" -noout -subject
echo

echo "== 3/4 安装 CA =="
install_system_ca "$CA_FILE"
install_docker_ca "$CA_FILE"
install_java_ca "$CA_FILE"
install_runtime_ca "$CA_FILE"
echo

echo "== 4/4 验证 =="
"$DIR/tests/test-client.sh" || true

echo
echo "✅ 接入完成。"
echo "   注意：Docker 需重启才生效 —— systemctl restart docker"
