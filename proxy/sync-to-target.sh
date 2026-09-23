#!/usr/bin/env bash
# sync-to-target.sh —— 把本机（开发机）项目同步到目标机
#
# ⚠️ 必须用 --inplace，这不是可选优化：
#   rsync 默认写临时文件再 rename，会**改变文件 inode**；
#   而 Docker bind mount 绑定的是**挂载时刻的 inode** ——
#   容器会继续读到旧文件，表现为「配置改了、nginx -s reload 也执行了，
#   但行为完全没变」。这个陷阱极难自查，故固化成脚本而非依赖记忆。
#
# 用法:
#   ./sync-to-target.sh                  # 默认同步到 192.168.0.18
#   TPROXY_TARGET=192.168.0.20 ./sync-to-target.sh
set -euo pipefail

TARGET="${TPROXY_TARGET:-192.168.0.18}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

# SSH 传输方式：优先用 sshpass（配合 TPROXY_PASS 环境变量），否则回退到 ssh。
# 若两者都不可用（无 key 且无密码），rsync 会在非交互环境下静默失败 ——
# 那正是「明明同步了、目标机却没有新文件」的成因。
SSH_CMD="ssh -o StrictHostKeyChecking=no"
if [[ -n "${TPROXY_PASS:-}" ]] && command -v sshpass >/dev/null 2>&1; then
  SSH_CMD="sshpass -p ${TPROXY_PASS} ssh -o StrictHostKeyChecking=no"
fi

echo "同步 $SRC/  →  grigs@${TARGET}:/opt/TProxy/"
rsync -a --inplace \
  --exclude='.git' \
  --exclude='.superpowers' \
  --exclude='logs' \
  -e "$SSH_CMD" \
  "$SRC/" "grigs@${TARGET}:/opt/TProxy/" \
  || { echo "❌ 同步失败。请设置 TPROXY_PASS，或配置 SSH 免密登录。" >&2; exit 1; }

# 校验：确认关键文件真的到了目标机
remote_n=$(ssh ${TPROXY_PASS:+-o BatchMode=no} -o StrictHostKeyChecking=no "grigs@${TARGET}" \
           "grep -c '^  registry-' /opt/TProxy/proxy/docker-compose.yml" 2>/dev/null || echo "?")
echo "✅ 已同步（--inplace，保持 inode）；目标机 registry 服务数: $remote_n"
echo
echo "提示：若本次同步包含 nginx / dnsmasq / compose 配置变更，"
echo "      需在目标机重启对应容器才能生效（仅 reload 不重新挂载）："
echo "        ssh grigs@${TARGET} 'cd /opt/TProxy/proxy && docker compose restart tengine dnsmasq'"
