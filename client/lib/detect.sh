#!/usr/bin/env bash
# client/lib/detect.sh —— 发行版与 DNS 管理机制检测
#
# 这两个检测决定后续走哪条分支：
#   · 发行版   决定 CA 装到哪个信任库（update-ca-certificates / update-ca-trust）
#   · DNS 机制 决定是否需要关闭 systemd-resolved（它会并行查询，破坏劫持）

detect_distro() {
  [[ -r /etc/os-release ]] || { echo "unknown"; return 0; }
  local ID="" ID_LIKE=""
  # shellcheck disable=SC1091
  . /etc/os-release
  # 必须转小写再匹配：openEuler 的 ID 实际是 "openEuler"（大写 E），
  # 直接匹配小写模式会漏判为 unknown
  local osid
  osid="$(printf '%s %s' "${ID:-}" "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
  case "$osid" in
    *ubuntu*|*debian*)                    echo "ubuntu" ;;
    *rhel*|*fedora*|*centos*|*openeuler*) echo "rhel" ;;
    *)                                    echo "unknown" ;;
  esac
}

detect_dns_manager() {
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "systemd-resolved"
  elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "networkmanager"
  elif command -v resolvconf >/dev/null 2>&1; then
    echo "resolvconf"
  else
    echo "unknown"
  fi
}
