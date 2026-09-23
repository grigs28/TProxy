#!/usr/bin/env bash
# client/lib/dns.sh —— 客户端 DNS 配置
#
# 核心约束：必须保证代理优先、且它不可用时能兜底到公网 —— 这要求 DNS 查询是
# 【串行】的（首个超时才试下一个）。glibc resolver 默认串行，而 systemd-resolved
# 会并行查询多个 DNS 取最快返回，公网结果会抢在代理之前，使劫持彻底失效。
# 因此 Ubuntu 上必须关闭 systemd-resolved。

# 主 DNS 由 client-setup.sh 在解析 --server 后注入；
# 直接 source 本文件（如测试）时回落到默认值。
TPROXY_DNS_PRIMARY="${TPROXY_SERVER:-192.168.0.18}"
TPROXY_DNS_FALLBACK=("223.5.5.5" "119.29.29.29")

BACKUP_DIR="/var/backups/tproxy-client"
BACKUP_ORIGINAL="$BACKUP_DIR/resolv.conf.original"

# 注意：不含 202.99.192.68 —— 运营商 DNS 存在劫持/污染（spec §4.3 明确禁用）。
# 114.114.114.114 实测延迟高 5-6 倍，亦已淘汰。
dns_server_list() {
  printf '%s\n' "$TPROXY_DNS_PRIMARY"
  printf '%s\n' "${TPROXY_DNS_FALLBACK[@]}"
}

render_resolv_conf() {
  echo "# TProxy 客户端配置 —— 由 client-setup.sh 生成"
  echo "# 顺序即优先级：串行查询，代理优先，其后为公网兜底"
  dns_server_list | while read -r s; do
    echo "nameserver $s"
  done
  # 缩短单次超时：代理不可用时快速切到兜底，而不是卡默认 5 秒
  echo "options timeout:2 attempts:1"
}

# 备份原始配置。
#
# ⚠️ 只备份【第一次】的原始状态，重复运行不覆盖 ——
# 否则第二次运行会用「上一次的 TProxy 配置」覆盖真正的原始配置，
# 导致 --rollback 恢复出一个仍指向代理的文件，回滚等于没做
# （而 systemd-resolved 已被关闭，表现为「回滚了但行为没变」，极难排查）。
backup_dns_config() {
  mkdir -p "$BACKUP_DIR"
  if [[ ! -f "$BACKUP_ORIGINAL" ]]; then
    # 用 cp -aL 解引用符号链接：Ubuntu 上 /etc/resolv.conf 通常是指向
    # /run/systemd/resolve/stub-resolv.conf 的链接，-a 会备份链接本身，
    # 而我们随后会删掉该链接并停用服务，回滚时就得到一个死链接。
    cp -aL /etc/resolv.conf "$BACKUP_ORIGINAL" 2>/dev/null || true
  fi
  echo "$BACKUP_ORIGINAL"
}

# 关闭 systemd-resolved 并解除它对 /etc/resolv.conf 的接管。
# 不做这一步，下面写的 resolv.conf 会被它覆盖，且并行查询会让劫持失效。
disable_systemd_resolved() {
  systemctl disable --now systemd-resolved 2>/dev/null || true
  rm -f /etc/resolv.conf
  : > /etc/resolv.conf
  chmod 644 /etc/resolv.conf
}

# NetworkManager 管理的系统：仅写 /etc/resolv.conf 不够 ——
# NM 会在连接重启、DHCP 续约、服务重启时把它重写回去，劫持静默失效。
# 故通过 nmcli 把 DNS 写进连接配置本身。
configure_dns_networkmanager() {
  local conn
  conn=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
         | grep -v ':lo$' | head -1 | cut -d: -f1)
  if [[ -z "$conn" ]]; then
    echo "   ⚠️  未找到活动连接，仅写入 /etc/resolv.conf（重启网络后可能失效）"
    return 1
  fi
  local dns_join
  dns_join=$(dns_server_list | paste -sd' ')
  if nmcli con mod "$conn" ipv4.dns "$dns_join" ipv4.ignore-auto-dns yes >/dev/null 2>&1; then
    echo "   已写入 NetworkManager 连接 '$conn'（ipv4.ignore-auto-dns=yes）"
    nmcli con up "$conn" >/dev/null 2>&1 || true
    return 0
  fi
  echo "   ⚠️  nmcli 配置失败，仅写入 /etc/resolv.conf"
  return 1
}

write_resolv_conf() {
  render_resolv_conf > /etc/resolv.conf
}

configure_dns() {
  backup_dns_config >/dev/null
  local mgr
  mgr=$(detect_dns_manager)
  case "$mgr" in
    systemd-resolved)
      # 关闭服务并把配置落成普通文件，避免被它覆盖
      disable_systemd_resolved
      write_resolv_conf
      ;;
    networkmanager)
      # 先写文件保证立即生效，再写进连接配置保证重启后仍在
      write_resolv_conf
      configure_dns_networkmanager || true
      ;;
    *)
      write_resolv_conf
      ;;
  esac
  # 清掉可能存在的本地 DNS 缓存，避免改了配置却仍解析到旧结果
  command -v nscd >/dev/null 2>&1 && nscd -i hosts >/dev/null 2>&1 || true
  echo "DNS 已配置（检测到机制: $mgr）"
}

# 供 --rollback 调用
restore_dns_config() {
  if [[ -f "$BACKUP_ORIGINAL" ]]; then
    rm -f /etc/resolv.conf
    cp -aL "$BACKUP_ORIGINAL" /etc/resolv.conf
    echo "已从 $BACKUP_ORIGINAL 恢复原始 DNS 配置"
    return 0
  fi
  echo "⚠️  未找到原始配置备份，请手动检查 /etc/resolv.conf"
  return 1
}
