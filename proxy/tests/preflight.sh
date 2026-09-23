#!/usr/bin/env bash
# proxy/tests/preflight.sh —— 测试【前】的配置体检
#
# 为什么需要它：2026-09-23 的实机验证中，连续踩到三个「配置层面」的坑，
# 而它们都不会让服务端自测变红，只有真实客户端才会暴露：
#
#   1. 宿主 /etc/hosts 里的旧 github 记录压过 dnsmasq 的 address= 劫持
#      （dnsmasq 读 hosts，且 hosts 优先级高于 address=）
#   2. firewalld 未放行 443/tcp —— nginx 在听，客户端却 No route to host
#   3. 客户端 yum 源仍指向已下线的 Nexus
#
# 结论：跑测试之前先体检。本脚本把这三类检查固化下来。
#
# 用法（在服务端 192.168.0.18 上运行）：
#   ./tests/preflight.sh

set -uo pipefail
fail=0
warn=0
SERVER_IP="${TPROXY_SERVER:-192.168.0.18}"

ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; fail=1; }
warn() { echo "  ⚠️  $1"; warn=1; }

echo "=== TProxy 配置体检（服务端 $(hostname)）==="
echo

echo "--- 1. 监听端口 ---"
for p in 443 80 53; do
  if ss -tln 2>/dev/null | grep -q ":${p} "; then ok "TCP $p 已监听"; else bad "TCP $p 未监听"; fi
done
ss -uln 2>/dev/null | grep -q ":53 " && ok "UDP 53 已监听" || bad "UDP 53 未监听"

echo
echo "--- 2. 防火墙（最易漏的一项）---"
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if [[ $EUID -eq 0 ]]; then
    ports=$(firewall-cmd --list-ports 2>/dev/null || echo "")
    for p in 443/tcp 80/tcp 53/udp; do
      if grep -q "$p" <<<"$ports"; then
        ok "firewalld 已放行 $p"
      else
        bad "firewalld 未放行 $p —— 客户端会 No route to host"
      fi
    done
  else
    # 非 root 读不到 firewalld 规则；若此处默认判失败会造成误报
    warn "非 root，无法读取 firewalld 规则 —— 请用 sudo 运行本脚本以检查此项"
    warn "  手工确认: sudo firewall-cmd --list-ports | grep -E '443/tcp|80/tcp|53/udp'"
  fi
else
  ok "firewalld 未运行（无需检查）"
fi

echo
echo "--- 3. 宿主 /etc/hosts 是否压过劫持 ---"
# dnsmasq 读宿主 hosts（host 网络），且 hosts 记录优先级【高于】address=。
# 若 hosts 里有被劫持域名，该域名的劫持会静默失效。
hijacked=$(grep -oP '^address=/\K[^/]+' /opt/TProxy/proxy/dnsmasq/dnsmasq.conf 2>/dev/null | sort -u)
conflict=0
for d in $hijacked; do
  if grep -qE "[[:space:]]${d}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    bad "/etc/hosts 含 $d —— 会压过劫持，该域名不会命中缓存"
    conflict=1
  fi
done
[[ $conflict -eq 0 ]] && ok "无 hosts 记录与被劫持域名冲突"

echo
echo "--- 4. dnsmasq 劫持生效抽查 ---"
for d in repo.openeuler.org github.com registry-1.docker.io pypi.org registry.npmjs.org; do
  got=$(dig +time=3 +tries=1 "@127.0.0.1" "$d" +short 2>/dev/null | head -1)
  if [[ "$got" == "$SERVER_IP" ]]; then
    ok "$d → $got"
  else
    bad "$d → ${got:-无响应}（期望 $SERVER_IP）"
  fi
done

echo
echo "--- 5. 容器健康 ---"
for c in v3-dnsmasq v3-tengine v3-gitcache v3-reg-docker; do
  st=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  health=$(docker inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo "none")
  case "$st" in
    running)
      if [[ "$health" == "unhealthy" ]]; then bad "$c: running 但 unhealthy"; else ok "$c: $st ($health)"; fi
      ;;
    *) bad "$c: $st" ;;
  esac
done

echo
echo "--- 6. 证书覆盖抽查 ---"
for d in repo.openeuler.org github.com pypi.org; do
  if [[ -f "/opt/TProxy/proxy/ca/certs/${d}.crt" ]]; then
    ok "$d 证书存在"
  else
    bad "$d 证书缺失（TLS 握手会失败）"
  fi
done

echo
echo "--- 7. 客户端视角可达性（从本机之外看）---"
warn "本项需在客户端执行 client/tests/test-client.sh 验证"
warn "服务端侧只能确认监听与放行，不能替代真实客户端测试"

echo
if [[ $fail -eq 0 ]]; then
  echo "PREFLIGHT-PASS（配置体检通过，可以跑测试）"
else
  echo "PREFLIGHT-FAIL（存在配置问题，先修复再测试）"
fi
exit $fail
