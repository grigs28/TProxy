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
BACKUP_HOSTS="$BACKUP_DIR/hosts.original"

# TProxy 会劫持的域名。客户端侧需要这份清单做两件事：
#   1. 自检时核对这些域名确实指向代理
#   2. 检查 /etc/hosts 有没有把它们钉在公网 IP 上 —— 那会让劫持完全失效
#
# ⚠️ **这份清单以服务端为准，不是抄一份放着**。
#   权威来源：`proxy/dnsmasq/dnsmasq.conf` 的 `address=` 规则。
#   守卫测试：`tests/test-hosts.sh` 会直接解析那份 dnsmasq.conf 并比对，
#   服务端加了域名而这里没跟 → 测试立刻红。
#
# 为什么这条守卫要指向服务端、而不是只比对 lib 与 dist 两份实现：
#   实测漂移过一次 —— 两份实现**一起**只写了 10 个，而服务端劫持 37 个。
#   少掉的 27 个里有 quay.io / ghcr.io / mirrors.aliyun.com / nodejs.org /
#   archive.ubuntu.com …，「检查 hosts 有没有钉死劫持域名」这条于是静默
#   漏掉三分之二；两份互相比对则永远是绿的。
#
# 顺序与 dnsmasq.conf 的分组保持一致，方便人工对照。
HIJACK_DOMAINS=(
  # openEuler
  repo.openeuler.org mirrors.openeuler.org dl-cdn.openeuler.openatom.cn
  # Ubuntu
  archive.ubuntu.com security.ubuntu.com cn.archive.ubuntu.com ports.ubuntu.com
  # CentOS / EPEL
  mirror.centos.org mirrorlist.centos.org dl.fedoraproject.org mirrors.fedoraproject.org
  # 国内镜像站
  mirrors.aliyun.com mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.huaweicloud.com
  # Docker 镜像仓库
  registry-1.docker.io auth.docker.io production.cloudflare.docker.com
  quay.io gcr.io ghcr.io k8s.gcr.io registry.k8s.io mcr.microsoft.com nvcr.io
  # Git 仓库
  github.com gitlab.com gitee.com
  # Python 包索引
  pypi.org files.pythonhosted.org pypi.tuna.tsinghua.edu.cn
  # Node.js 包索引
  registry.npmjs.org registry.npmmirror.com nodejs.org
  # Java 制品仓库
  repo1.maven.org repo.maven.apache.org maven.aliyun.com
)

# ---- 直连模式（应急）----
#
# 用途：.18 不可用时，把劫持域名钉到**源站**，机器照常上网。
# 不这么做的话，每次 DNS 查询都要先等 .18 超时（resolv.conf 里配的 2 秒）
# 才会落到公网 DNS —— 能通，但每个请求都慢一拍。
#
# ⚠️ 这是应急手段，不是长期配置：这些 IP 属于 CDN / 云厂商，会变
#    （实测 github.com 的 A 记录在几个月内就换过）。而且钉住之后，
#    那几个域名就**再也不走缓存**了 —— 恢复正常后请及时 --no-bypass。
#
# 数据来源：2026-09-23 用两个公网 DNS（223.5.5.5 / 119.29.29.29）实测，
# 两者结果一致，并与线上资料交叉核对过。github.com 给两个 IP：
# 140.82.116.3 是 GitHub 自有网络（西雅图），20.205.243.166 走 Azure 新加坡 ——
# 后者在境内延迟更好，且实测已稳定服务两年。
DIRECT_HOSTS=(
  "49.0.229.41        repo.openeuler.org"
  "49.0.230.196       mirrors.openeuler.org"
  "100.30.41.220      registry-1.docker.io"
  "104.18.43.178      auth.docker.io"
  "151.101.0.223      pypi.org"
  "151.101.0.223      files.pythonhosted.org"
  "104.16.0.34        registry.npmjs.org"
  "104.18.18.12       repo1.maven.org"
  "140.82.116.3       github.com"
  "20.205.243.166     github.com"
)

# 成对标记：撤销时按标记整体摘掉，不会误伤手工加的记录
BYPASS_BEGIN="# >>> TProxy 直连模式（应急，--no-bypass 撤销）"
BYPASS_END="# <<< TProxy 直连模式"

# 开启直连模式。幂等：已开启则重写这一块（便于更新 IP）。
bypass_on() {
  local f="${1:-/etc/hosts}" entry
  bypass_off "$f"                       # 先摘掉旧的，避免叠加

  {
    printf '\n%s\n' "$BYPASS_BEGIN"
    for entry in "${DIRECT_HOSTS[@]}"; do
      printf '%s\n' "$entry"
    done
    printf '%s\n' "$BYPASS_END"
  } >> "$f" || return 1
  return 0
}

# 撤销直连模式。没有开启时一个字节都不动。
bypass_off() {
  local f="${1:-/etc/hosts}" tmp
  grep -qF "$BYPASS_BEGIN" "$f" 2>/dev/null || return 0

  tmp=$(mktemp) || return 1
  if ! awk -v b="$BYPASS_BEGIN" -v e="$BYPASS_END" '
        index($0, b) { skip = 1; next }
        index($0, e) { skip = 0; next }
        !skip { print }
      ' "$f" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  # 用 cat 覆盖而非 mv：保住原文件的属主与 inode
  cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# 当前是否处于直连模式
bypass_active() {
  grep -qF "$BYPASS_BEGIN" "${1:-/etc/hosts}" 2>/dev/null
}

# ---- /etc/hosts 覆盖检查 ----
#
# 为什么必须查：/etc/nsswitch.conf 里 `hosts: files dns ...` —— **files 排在 dns 之前**，
# 所以 /etc/hosts 里的一条记录会稳稳压过 TProxy 的 DNS 劫持。
# 而自检用的 `dig` 绕过 NSS（直接问 nameserver），永远看不到它 ——
# 于是表现为「自检全绿、劫持其实完全没生效」，真实程序直连公网。
# 这个坑在本项目里出现过两次（.18 服务端、.19 客户端），故做成显式检查。

# 判断：列出 /etc/hosts 里钉死了的劫持域名。只读，不改任何东西。
# 匹配域名**及其子域** —— dnsmasq 的 address=/github.com/ 同样覆盖
# *.github.com，所以钉死 www.github.com 一样会破坏劫持。
hosts_pinned_domains() {
  local f="${1:-/etc/hosts}" d
  [[ -f "$f" ]] || return 0
  for d in "${HIJACK_DOMAINS[@]}"; do
    awk -v want="$d" '
      # 子域判定必须用「后缀相等」，不能用 index(...) == 长度差 ——
      # 后者在两串**等长**时会得到 0 == 0 而误判
      # （registry.npmjs.org 与 repo.openeuler.org 同为 18 字符）。
      function is_sub(host, d) {
        return host == d || substr(host, length(host) - length(d)) == "." d
      }
      { sub(/#.*/, "") }
      NF >= 2 {
        for (i = 2; i <= NF; i++) if (is_sub($i, want)) { print want; exit }
      }
    ' "$f"
  done
}

# 修正：删掉 /etc/hosts 里钉死劫持域名的行。
# **先判断** —— 一行都没命中时一个字节都不动（那是人家有意配的就别碰）。
hosts_unpin() {
  local f="${1:-/etc/hosts}" pinned
  pinned=$(hosts_pinned_domains "$f")
  [[ -n "$pinned" ]] || return 0

  # 只备份第一次，重复执行不覆盖（与 resolv.conf 的备份同理）
  if [[ ! -f "$BACKUP_HOSTS" ]]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    cp -a "$f" "$BACKUP_HOSTS" 2>/dev/null || true
  fi

  local tmp
  tmp=$(mktemp) || return 1
  if ! awk -v domains="${HIJACK_DOMAINS[*]}" '
        BEGIN { ndoms = split(domains, doms, " ") }
        function is_sub(host, d) {
          return host == d || substr(host, length(host) - length(d)) == "." d
        }
        {
          line = $0
          sub(/#.*/, "", line)
          n = split(line, a, /[ \t]+/)
          drop = 0
          for (i = 2; i <= n && !drop; i++)
            for (j = 1; j <= ndoms; j++)
              if (is_sub(a[i], doms[j])) { drop = 1; break }
          if (!drop) print $0
        }
      ' "$f" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  # 用 cat 覆盖而非 mv：保住原文件的属主与 inode
  cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

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

  # 配好 DNS 还不够：/etc/hosts 里的记录会把它整个压过去
  # （nsswitch 里 files 排在 dns 之前），而 dig 看不到这一点。
  # 不查的话这台机器看起来接入成功，实际劫持一个都没生效。
  # 直连模式是「我们自己写的 hosts 覆盖」，先整体摘掉再走常规流程
  if bypass_active; then
    echo "⚠ /etc/hosts 处于【直连模式】（应急用），将改回走代理"
    bypass_off && echo "  已撤销直连模式"
  fi

  local pinned d
  pinned=$(hosts_pinned_domains)
  if [[ -z "$pinned" ]]; then
    echo "/etc/hosts 无覆盖"
    return 0
  fi
  echo "⚠ /etc/hosts 钉死了这些劫持域名，DNS 劫持对它们无效："
  while read -r d; do
    [[ -n "$d" ]] && echo "    $d"
  done <<< "$pinned"
  if hosts_unpin; then
    echo "  已移除（原文件备份在 $BACKUP_HOSTS）"
    command -v nscd >/dev/null 2>&1 && nscd -i hosts >/dev/null 2>&1 || true
  else
    echo "  ⚠ 自动移除失败，请手工删除上述域名在 /etc/hosts 里的记录"
  fi
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

# 目标服务器是否**就是本机**。
#
# 为什么需要：`.18` 是服务端，它的 DNS 必须是公网 —— 若把它指向自己就成了环，
# 它连一个域名都查不出来（而它恰恰要为全网回源）。
# 所以服务端**不能**执行 install_dns。有了这个判据，脚本就能在服务端上跑
# 除 DNS 之外的全部检查与修复，而不是整条 `-i` 都跑不了。
# 实测：`.18` 的死 Nexus 仓库、git 残留都因此长期没被自动修过，只能手工抽函数。
is_self_target() {
  # ⚠️ 用 ${VAR:-} 取值：直接 source 本文件时（如测试）TPROXY_SERVER 可能没设，
  #    而调用方常带 set -u —— 不这样写会直接「未绑定的变量」退出。
  local want="${TPROXY_SERVER:-${TPROXY_DNS_PRIMARY:-}}" ip
  [[ -n "$want" ]] || return 1
  for ip in $(hostname -I 2>/dev/null); do
    [[ "$ip" == "$want" ]] && return 0
  done
  # 回退：直接读网卡。hostname -I 在精简系统（OpenWrt 等）上可能没有。
  ip -o -4 addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' \
    | grep -qx "$want" && return 0
  return 1
}
