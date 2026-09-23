#!/usr/bin/env bash
# client/tests/test-hosts.sh —— /etc/hosts 覆盖劫持域名的检测与修正
#
# 为什么值得单独测：这个坑在本项目里让 DNS 劫持**静默失效过两次**
# （.18 服务端、.19 客户端），两次都报着绿灯 ——
# 因为 nsswitch 里 files 排在 dns 之前，/etc/hosts 永远压过 DNS，
# 而自检用的 dig 绕过 NSS，永远看不到它。
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/dns.sh
source "$DIR/lib/dns.sh"

fail=0

# 造一个假的 hosts 文件，避免碰真实的 /etc/hosts
T=$(mktemp -d)
H="$T/hosts"
cat > "$H" <<'EOF'
127.0.0.1   localhost
::1         localhost

# 下面这些是别人手工钉的，注释里的不该被当成记录
# 20.205.243.166  pypi.org

20.205.243.166   github.com
20.205.243.166   www.github.com
185.199.108.133  raw.githubusercontent.com
1.2.3.4          registry-1.docker.io   registry.npmjs.org
EOF

echo "== 判断：应检出被钉死的劫持域名 =="
# 报的是【被破坏的劫持域名】，不是 /etc/hosts 里的每一条主机名 ——
# 用户关心的是「哪个域名的劫持失效了」，而不是文件里写了几行。
pinned=$(hosts_pinned_domains "$H")
for d in github.com registry-1.docker.io registry.npmjs.org; do
    if grep -qx "$d" <<<"$pinned"; then
        echo "  ✅ 检出 $d"
    else
        echo "  ❌ 漏检 $d"
        fail=1
    fi
done

# 子域也算：dnsmasq 的 address=/github.com/ 同样覆盖 *.github.com，
# 所以钉死 www.github.com 一样破坏劫持 —— 但要归到 github.com 名下
if [[ "$(grep -c . <<<"$pinned")" -eq 3 ]]; then
    echo "  ✅ 子域归到所属域名，不重复计数"
else
    echo "  ❌ 检出条目数不对（期望 3）：$(tr '\n' ' ' <<<"$pinned")"
    fail=1
fi

echo "== 判断：不该误报 =="
# 不在劫持列表里的域名，钉了也是人家有意为之（比如绕开 GitHub raw 访问问题）
if grep -qx "raw.githubusercontent.com" <<<"$pinned"; then
    echo "  ❌ 误报了 raw.githubusercontent.com（它不在劫持列表里）"
    fail=1
else
    echo "  ✅ 未误报非劫持域名"
fi
# 被注释掉的记录不算数
if grep -qx "pypi.org" <<<"$pinned"; then
    echo "  ❌ 把注释里的记录也当成了覆盖"
    fail=1
else
    echo "  ✅ 忽略注释行"
fi

echo "== 修正：只删劫持域名，其余原封不动 =="
hosts_unpin "$H" >/dev/null
# 主域与子域的行都要清掉
if grep -qE "(^|[[:space:]])(www\.)?github\.com([[:space:]]|$)" "$H" \
   || grep -q "registry.npmjs.org" "$H"; then
    echo "  ❌ 劫持域名没被清干净"
    fail=1
else
    echo "  ✅ 主域与子域的行都已清除"
fi
if grep -q "raw.githubusercontent.com" "$H"; then
    echo "  ✅ 非劫持域名保留"
else
    echo "  ❌ 把非劫持域名也删了 —— 那是人家有意配的"
    fail=1
fi
if grep -q "127.0.0.1   localhost" "$H" && grep -q "localhost" "$H"; then
    echo "  ✅ 原有记录完好"
else
    echo "  ❌ 破坏了原有记录"
    fail=1
fi
if grep -q "^# 20.205" "$H"; then
    echo "  ✅ 注释保留"
else
    echo "  ❌ 注释被删了"
    fail=1
fi

echo "== 先判断：干净的文件一个字节都不该动 =="
C="$T/clean"
printf '127.0.0.1 localhost\n' > "$C"
before=$(md5sum "$C" | cut -d' ' -f1)
hosts_unpin "$C" >/dev/null
after=$(md5sum "$C" | cut -d' ' -f1)
if [[ "$before" == "$after" ]]; then
    echo "  ✅ 没有问题时不动文件"
else
    echo "  ❌ 没有问题却改了文件"
    fail=1
fi

echo "== 重复执行为幂等 =="
hosts_unpin "$H" >/dev/null
n=$(grep -c "github.com" "$H" || true)
if [[ "$n" -eq 0 ]]; then
    echo "  ✅ 重复执行安全"
else
    echo "  ❌ 重复执行有问题"
    fail=1
fi

echo "== 两份实现不许分叉 =="
# client/lib/*.sh 与 dist/tp.client.sh 是同一工具的两份实现，各自手工维护。
# 劫持域名清单一旦分叉，就会出现「这份报了那份没报」的怪事。
_lib_domains=$(sed -n '/^HIJACK_DOMAINS=(/,/^)/p' "$DIR/lib/dns.sh" \
                 | grep -oE '[a-z0-9.-]+\.[a-z]{2,}' | sort | tr '\n' ' ')
_dist_domains=$(sed -n '/^HIJACK_DOMAINS=(/,/^)/p' "$DIR/dist/tp.client.sh" \
                 | grep -oE '[a-z0-9.-]+\.[a-z]{2,}' | sort | tr '\n' ' ')
if [[ -n "$_lib_domains" && "$_lib_domains" == "$_dist_domains" ]]; then
    echo "  ✅ 劫持域名清单一致（$(wc -w <<<"$_lib_domains") 个）"
else
    echo "  ❌ 两份的劫持域名清单不一致"
    echo "     lib : $_lib_domains"
    echo "     dist: $_dist_domains"
    fail=1
fi
for fn in hosts_pinned_domains hosts_unpin; do
    if grep -q "^${fn}()" "$DIR/lib/dns.sh" && grep -q "^${fn}()" "$DIR/dist/tp.client.sh"; then
        echo "  ✅ 两份都有 $fn"
    else
        echo "  ❌ 有一份缺少 $fn"
        fail=1
    fi
done

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "HOSTS-PASS"; else echo "HOSTS-FAIL"; fi
exit $fail
