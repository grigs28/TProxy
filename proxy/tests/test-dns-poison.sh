#!/usr/bin/env bash
# proxy/tests/test-dns-poison.sh —— CNAME 型劫持域名会不会被「一次追链」打穿
#
# 为什么单独一个文件、且自带 dnsmasq 实例：
#   这个缺陷是**有状态**的 —— 它取决于 dnsmasq 缓存里有没有那条 CNAME。
#   在跑着的生产实例上测，既测不准（缓存已被污染或恰好干净），
#   又会把生产缓存搞脏。所以自带实例、从零开始。
#
# ============================ 缺陷机理（2026-09-26 实测）============================
#
# `address=/域名/IP` **只提供 A 记录**。客户端查 AAAA 时
# （glibc 的 getaddrinfo 默认 A 与 AAAA 并行发送，所以这几乎必然发生）
# dnsmasq 无 AAAA 可答 → **转发上游** → 上游回复里该域名是条 **CNAME**。
#
# 此时劫持仍然正常。真正致命的是**下一步**：客户端拿到 CNAME 后会去追链 ——
# 直接查询 CNAME 目标（实测生产上 `debian.map.fastlydns.net` 被 6 台机器
# 直接查询 134 次）。这一步把**目标的真实 A 记录**灌进了 dnsmasq 缓存。
#
# 于是 dnsmasq 手里同时有了：
#     CNAME   deb.debian.org        → debian.map.fastlydns.net
#     A       debian.map.fastlydns.net → 151.101.x.x
# 而 **CNAME 是类型无关的** —— 此后连 A 查询也命中这条 CNAME，
# 链式追到真实公网 IP，**劫持彻底失效**。
#
# 生产实测（.18，`deb.debian.org`，16 台机器在用）：
#     query[A] deb.debian.org from 127.0.0.1
#     cached  deb.debian.org is <CNAME>            ← 不是 config …… is 192.168.0.18
#     cached  debian.map.fastlydns.net is 151.101.66.132
#
# 与既有那个坑（`dnsmasq-hijack-traps` 坑三）的区别：那个要**重启**才显形，
# 这个**运行中自行发生**，且 `min-cache-ttl=300` 让污染至少粘 5 分钟、
# 期间的每次查询都在续期。
#
# ============================ 修法：`local=/域名/` ============================
#
# 让 dnsmasq 对该域名**自认权威、永不转发**。AAAA 于是返回 NODATA
# （而不是转发拿回 CNAME），**CNAME 根本不再暴露给客户端**，追链路径从源头断掉。
#
# 实测两个反例（都是本轮验证过的）：
#   ❌ `filter-AAAA` —— 仍然转发、仍然缓存，无效。
#   ❌ 只加 `address=/域名/::` —— 能用，但会给客户端发一个假的 `::` 地址。
#
# ⚠️ 判定「某域名是不是 CNAME」必须**绕过被测实例**、直接问公网上游 ——
#    否则修好之后 AAAA 回 NODATA，测试会空洞地通过（什么都没测到）。
#
# 用法（需要 docker）：
#   ./tests/test-dns-poison.sh

set -uo pipefail

HOST_IP="${TPROXY_SERVER:-192.168.0.18}"
UPSTREAM="${TPROXY_UPSTREAM:-223.5.5.5}"
CONF="$(cd "$(dirname "$0")/../dnsmasq" && pwd)/dnsmasq.conf"
PORT="${TPROXY_TEST_PORT:-15353}"
NAME="tproxy-dnsmasq-poison-test"
WORK="$(mktemp -d)"

fail=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; fail=1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

q() {  # q <域名> <类型> —— 查被测实例
  dig +short +time=3 +tries=1 @127.0.0.1 -p "$PORT" "$1" "$2" 2>/dev/null \
    | sed 's/\.$//' | grep -E '^[0-9a-f:.]+$' || true
}
qup() {  # 直接问公网上游（判定 CNAME 用，绕过被测实例）
  dig +short +time=5 +tries=1 @"$UPSTREAM" "$1" AAAA 2>/dev/null \
    | grep -vE '^[0-9a-f:]+$' | sed 's/\.$//' | head -1 || true
}

echo "=== CNAME 型劫持域名的「追链打穿」测试（服务端 $HOST_IP）==="
echo

# ---- 准备：试验镜像 + 配置 ----
if ! docker image inspect dnsmasq:poison-test >/dev/null 2>&1; then
  echo "--- 构建试验镜像（用未被劫持的默认 CDN，避免自举问题）---"
  # ⚠️ 不能用项目的 Dockerfile：它把源换成 mirrors.aliyun.com，
  #    而那个域名**正是被劫持的** —— 在客户端机器上构建时容器不信任 TProxy CA，
  #    会报 certificate verify failed。这里刻意用默认 CDN 自举。
  printf 'FROM alpine:3.19\nRUN apk add --no-cache dnsmasq\n' > "$WORK/Dockerfile"
  docker build -t dnsmasq:poison-test "$WORK" >/dev/null 2>&1 \
    || { bad "试验镜像构建失败（需要能访问默认 alpine CDN）"; exit 1; }
fi

# 从**真实配置**生成试验配置：保留 address= 与 server= 例外，最后附上 local=
{
  echo "listen-address=0.0.0.0"
  echo "bind-interfaces"
  echo "port=53"
  echo "server=$UPSTREAM"
  echo "no-resolv"
  echo "no-poll"
  echo "cache-size=10000"
  # 与生产一致：正是它让污染至少粘 5 分钟
  echo "min-cache-ttl=300"
  echo "log-queries"
  echo "log-facility=-"
  command grep -E '^address=/' "$CONF"
  command grep -E '^server=/' "$CONF" | grep -v '/#$'
  command grep -E '^local=/'  "$CONF" 2>/dev/null || true
} > "$WORK/test.conf"

domains=$(command grep -oE '^address=/[^/]+/' "$CONF" | sed 's|address=/||;s|/$||' | sort -u)
n_dom=$(echo "$domains" | grep -c . || true)
echo "--- 发现 $n_dom 个劫持域名，其中真实为 CNAME 的将被逐个测试 ---"

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -p "$PORT:53/udp" -p "$PORT:53/tcp" \
  -v "$WORK/test.conf:/etc/dnsmasq.conf:ro" \
  dnsmasq:poison-test dnsmasq -k -C /etc/dnsmasq.conf >/dev/null 2>&1
sleep 2
if ! docker ps --filter "name=$NAME" --format '{{.Status}}' | grep -q Up; then
  bad "被测 dnsmasq 起不来：$(docker logs "$NAME" 2>&1 | tail -2 | tr '\n' ' ')"
  exit 1
fi

echo
echo "== 1. 基线：劫持本身是否生效 =="
for d in $(echo "$domains" | head -5); do
  [[ "$(q "$d" A | head -1)" == "$HOST_IP" ]] && ok "$d → $HOST_IP" || bad "$d 未返回 $HOST_IP"
done

echo
echo "== 2. 逐个 CNAME 型域名：走完追链四步后劫持是否仍成立 =="
tested=0
while read -r d; do
  [[ -z "$d" ]] && continue
  cname=$(qup "$d")
  [[ -z "$cname" ]] && continue          # 不是 CNAME → 不在本缺陷射程内
  tested=$((tested+1))
  # ① 先确认干净时是劫持的
  first=$(q "$d" A | head -1)
  # ② 查 AAAA（客户端 getaddrinfo 的真实行为）→ 拿到 CNAME
  q "$d" AAAA >/dev/null
  # ③ 追链：直接查 CNAME 目标 → 真实 A 记录进缓存
  q "$cname" A >/dev/null
  # ④ 再查原域名 A —— 这一步是断言点
  after=$(q "$d" A | head -1)
  if [[ "$after" == "$HOST_IP" ]]; then
    ok "$d（CNAME→$cname）追链后仍是 $HOST_IP"
  else
    bad "$d 被追链打穿：$HOST_IP → ${after:-空}（干净时=$first）"
  fi
done <<< "$domains"
[[ $tested -eq 0 ]] && bad "没找到任何 CNAME 型劫持域名 —— 测试没测到东西，请检查判定逻辑"
[[ $tested -gt 0 ]] && echo "  （共测 $tested 个 CNAME 型域名）"

echo
echo "== 3. 子域例外不能被 local= 压掉（关键交互）=="
# ⚠️ `local=/github.com/` 与 `server=/api.github.com/IP` 谁赢？
#    dnsmasq 里**更具体的域名优先**，所以例外应当仍然生效。
#    这是必须钉住的 —— 一旦例外失效，api/codeload 这些子域会被劫持到本机，
#    而 tengine 不服务它们，客户端会拿到不匹配的证书（实测过：dnf 报 SSL error）。
for d in $(command grep -E '^server=/' "$CONF" | grep -v '/#$' \
           | sed 's|^server=/||;s|/.*||' | sort -u); do
  r=$(q "$d" A | head -1)
  if [[ "$r" == "$HOST_IP" ]]; then
    bad "$d 被误劫持了（例外失效）"
  elif [[ -n "$r" ]]; then
    ok "$d 仍走上游 → $r"
  else
    bad "$d 解析不出（例外被破坏）"
  fi
done

echo
echo "== 4. 未劫持域名不受影响 =="
r=$(q www.baidu.com A | head -1)
[[ -n "$r" && "$r" != "$HOST_IP" ]] && ok "www.baidu.com → $r" \
  || bad "未劫持域名解析异常：'${r:-空}'"

echo
if [[ $fail -eq 0 ]]; then echo "DNS-POISON-PASS"; else echo "DNS-POISON-FAIL"; fi
exit $fail
