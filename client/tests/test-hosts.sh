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

echo "== 劫持域名清单必须【随服务端】，不能两份互抄 =="
# client/lib/*.sh 与 dist/tp.client.sh 是同一工具的两份实现，各自手工维护。
# 但「两份彼此一致」是**不够的** —— 它们可以一起漏掉服务端新增的域名。
# 实测就是这么发生的：两份都只写了 10 个，而服务端 dnsmasq 劫持 **37** 个
# （少掉 quay.io / ghcr.io / mirrors.aliyun.com / nodejs.org … 共 27 个），
# 于是「检查 /etc/hosts 有没有钉死劫持域名」这条会静默漏掉三分之二。
#
# 所以基准取**服务端那份 dnsmasq.conf**，两份实现都跟它比。
_SRV_CONF="$DIR/../proxy/dnsmasq/dnsmasq.conf"
# ⚠️ 先去掉注释再抽域名。否则分组注释里的 `# Node.js 包索引` 会贡献出
# 一个假域名 `ode.js` —— 实测就是这么误报的。同类教训：**扫代码前先剥注释**。
_lib_domains=$(sed -n '/^HIJACK_DOMAINS=(/,/^)/p' "$DIR/lib/dns.sh" \
                 | sed 's/#.*//' | grep -oE '[a-z0-9.-]+\.[a-z]{2,}' | sort -u)
_dist_domains=$(sed -n '/^HIJACK_DOMAINS=(/,/^)/p' "$DIR/dist/tp.client.sh" \
                 | sed 's/#.*//' | grep -oE '[a-z0-9.-]+\.[a-z]{2,}' | sort -u)
if [[ -f "$_SRV_CONF" ]]; then
    _srv_domains=$(grep -oE '^address=/\K[^/]+' "$_SRV_CONF" 2>/dev/null | sort -u)
    if [[ -z "$_srv_domains" ]]; then
        _srv_domains=$(sed -n 's|^address=/\([^/]*\)/.*|\1|p' "$_SRV_CONF" | sort -u)
    fi
    for pair in "lib:$_lib_domains" "dist:$_dist_domains"; do
        who="${pair%%:*}"; got="${pair#*:}"
        miss=$(comm -23 <(printf '%s\n' "$_srv_domains") <(printf '%s\n' "$got"))
        extra=$(comm -13 <(printf '%s\n' "$_srv_domains") <(printf '%s\n' "$got"))
        if [[ -z "$miss" && -z "$extra" ]]; then
            echo "  ✅ $who 与服务端一致（$(wc -l <<<"$_srv_domains") 个）"
        else
            echo "  ❌ $who 与服务端 dnsmasq.conf 不一致"
            [[ -n "$miss"  ]] && echo "     少了: $(tr '\n' ' ' <<<"$miss")"
            [[ -n "$extra" ]] && echo "     多了: $(tr '\n' ' ' <<<"$extra")"
            fail=1
        fi
    done
    # 两份实现彼此也要一致（否则会出现「这份报了那份没报」）
    if [[ "$_lib_domains" == "$_dist_domains" ]]; then
        echo "  ✅ 两份实现彼此一致"
    else
        echo "  ❌ 两份实现不一致"
        fail=1
    fi
else
    echo "  ⏭  找不到 $_SRV_CONF，跳过（无法核对服务端）"
fi
for fn in hosts_pinned_domains hosts_unpin bypass_on bypass_off bypass_active; do
    if grep -q "^${fn}()" "$DIR/lib/dns.sh" && grep -q "^${fn}()" "$DIR/dist/tp.client.sh"; then
        echo "  ✅ 两份都有 $fn"
    else
        echo "  ❌ 有一份缺少 $fn"
        fail=1
    fi
done

echo "== 直连模式：写入 / 撤销 =="
# 用途：.18 不可用时把劫持域名钉到源站 —— 否则每次 DNS 查询都要先等 .18
# 超时（2 秒）才落到公网 DNS。属于应急，不是长期方案。
B="$T/bypass"
printf '127.0.0.1 localhost\n185.199.108.133 raw.githubusercontent.com\n' > "$B"

bypass_on "$B" >/dev/null
if grep -qF "$BYPASS_BEGIN" "$B" && grep -qF "$BYPASS_END" "$B"; then
    echo "  ✅ 写入带标记"
else
    echo "  ❌ 没写标记，事后无法整体撤销"
    fail=1
fi
n=$(sed -n "/$BYPASS_BEGIN/,/$BYPASS_END/p" "$B" | grep -cE '^[0-9]')
if [[ "$n" -eq "${#DIRECT_HOSTS[@]}" ]]; then
    echo "  ✅ 写入 ${n} 条源站记录"
else
    echo "  ❌ 记录数不对（期望 ${#DIRECT_HOSTS[@]}，实际 $n）"
    fail=1
fi
if grep -q "140.82.116.3" "$B" && grep -q "151.101.0.223" "$B"; then
    echo "  ✅ 含 github 与 pypi 的源站 IP"
else
    echo "  ❌ 缺少关键源站 IP"
    fail=1
fi

# 直连模式本身就是「/etc/hosts 覆盖劫持域名」，所以判断函数必须能认出它 ——
# 这样重新接入时才能自动改回走代理
if hosts_pinned_domains "$B" | grep -qx "github.com"; then
    echo "  ✅ 能被 hosts_pinned_domains 认出（重新接入会改回走代理）"
else
    echo "  ❌ 认不出来，重新接入时清不掉"
    fail=1
fi

bypass_off "$B" >/dev/null
if grep -qF "$BYPASS_BEGIN" "$B"; then
    echo "  ❌ 撤销后标记还在"
    fail=1
else
    echo "  ✅ 标记已清除"
fi
if grep -q "140.82.116.3" "$B"; then
    echo "  ❌ 撤销后源站 IP 还在"
    fail=1
else
    echo "  ✅ 源站记录已清除"
fi
if grep -q "127.0.0.1 localhost" "$B" && grep -q "raw.githubusercontent.com" "$B"; then
    echo "  ✅ 原有记录未受影响"
else
    echo "  ❌ 误伤了原有记录"
    fail=1
fi

echo "== 撤销后再撤销应是安全的（幂等）=="
before=$(md5sum "$B" | cut -d' ' -f1)
bypass_off "$B" >/dev/null
if [[ "$before" == "$(md5sum "$B" | cut -d' ' -f1)" ]]; then
    echo "  ✅ 重复撤销不动文件"
else
    echo "  ❌ 重复撤销改了文件"
    fail=1
fi

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "HOSTS-PASS"; else echo "HOSTS-FAIL"; fi
exit $fail
