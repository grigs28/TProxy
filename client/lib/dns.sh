#!/usr/bin/env bash
# client/lib/dns.sh —— 客户端 DNS 配置
#
# 核心约束：必须保证 .18 优先、且它不可用时能兜底到公网 —— 这要求 DNS 查询是
# 【串行】的（首个超时才试下一个）。glibc resolver 默认串行，而 systemd-resolved
# 会并行查询多个 DNS 取最快返回，公网结果会抢在 .18 之前，使劫持彻底失效。
# 因此 Ubuntu 上必须关闭 systemd-resolved。

TPROXY_DNS_PRIMARY="192.168.0.18"
TPROXY_DNS_FALLBACK=("223.5.5.5" "119.29.29.29")

# 注意：不含 202.99.192.68 —— 运营商 DNS 存在劫持/污染（spec §4.3 明确禁用）。
# 114.114.114.114 实测延迟高 5-6 倍，亦已淘汰。
dns_server_list() {
  printf '%s\n' "$TPROXY_DNS_PRIMARY"
  printf '%s\n' "${TPROXY_DNS_FALLBACK[@]}"
}

render_resolv_conf() {
  echo "# TProxy 客户端配置 —— 由 client-setup.sh 生成"
  echo "# 顺序即优先级：串行查询，.18 优先，其后为公网兜底"
  dns_server_list | while read -r s; do
    echo "nameserver $s"
  done
  # 缩短单次超时：.18 不可用时快速切到兜底，而不是卡默认 5 秒
  echo "options timeout:2 attempts:1"
}

backup_dns_config() {
  local stamp dir
  stamp=$(date +%Y%m%d-%H%M%S)
  dir="/var/backups/tproxy-client"
  mkdir -p "$dir"
  cp -a /etc/resolv.conf "$dir/resolv.conf.$stamp" 2>/dev/null || true
  echo "$dir/resolv.conf.$stamp"
}

# 关闭 systemd-resolved 并解除它对 /etc/resolv.conf 的接管。
# 不做这一步，下面写的 resolv.conf 会被它覆盖，且并行查询会让劫持失效。
disable_systemd_resolved() {
  systemctl disable --now systemd-resolved 2>/dev/null || true
  # 断开 stub 链接，使 /etc/resolv.conf 成为普通文件而非指向 127.0.0.53 的符号链接
  rm -f /etc/resolv.conf
  : > /etc/resolv.conf
  chmod 644 /etc/resolv.conf
}

write_resolv_conf() {
  render_resolv_conf > /etc/resolv.conf
}

configure_dns() {
  backup_dns_config >/dev/null
  local mgr
  mgr=$(detect_dns_manager)
  if [[ "$mgr" == "systemd-resolved" ]]; then
    disable_systemd_resolved
  fi
  write_resolv_conf
  echo "DNS 已配置（检测到机制: $mgr）"
}
