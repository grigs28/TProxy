#!/usr/bin/env bash
# client/tests/test-gpgkey.sh —— dnf 仓库的「签名 key 未导入」检查
#
# 为什么值得查：`gpgcheck=1` 的仓库若签名 key 没导入，症状是
# **`dnf makecache` 一切正常、只有装包才报 `GPG check FAILED`** ——
# 非常容易误判成「网络问题」或「仓库坏了」。
#
# 实测（.14 / .18，2026-09-25）：gh-cli.repo 的 gpgkey 指向 keyserver 上的
# 单个 key（0x23F3D4EA75716059），而 GitHub CLI 轮换了签名密钥 ——
# gh 2.101.0 是用 62313325 签的，配的却是 75716059：
#   The GPG keys listed ... are not correct for this package. / GPG check FAILED
#
# 便宜的检测点：仓库**元数据**的签名 key 与**包**是同一个（实测都是 62313325），
# 所以取 repomd.xml.asc（约 800 字节）就够，不必下载几十 MB 的包。
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/repair.sh
source "$DIR/lib/repair.sh"

fail=0
T=$(mktemp -d)
FIX="$DIR/tests/fixtures/repomd.xml.asc"

echo "== 从真实 repomd.xml.asc 解出签名 keyid =="
id=$(gpgkey_id_from_asc "$FIX")
if [[ "$id" == "62313325" ]]; then
  echo "  ✅ 解出 62313325（与 rpm -q gpg-pubkey 的格式一致：后 8 位小写）"
else
  echo "  ❌ 期望 62313325，实际 '$id'"
  fail=1
fi

echo "== 空文件 / 非签名文件不能崩，返回空 =="
: > "$T/empty.asc"
[[ -z "$(gpgkey_id_from_asc "$T/empty.asc")" ]] && echo "  ✅ 空文件返回空" \
  || { echo "  ❌ 空文件有输出"; fail=1; }
printf 'not a signature\n' > "$T/junk.asc"
[[ -z "$(gpgkey_id_from_asc "$T/junk.asc")" ]] && echo "  ✅ 垃圾内容返回空" \
  || { echo "  ❌ 垃圾内容有输出"; fail=1; }

echo "== 用 file:// 假仓库端到端验（不依赖网络）=="
mkdir -p "$T/repo/repodata"
cp "$FIX" "$T/repo/repodata/repomd.xml.asc"
mkdir -p "$T/rd"
cat > "$T/rd/ok.repo" <<EOF
[ok-repo]
name=key 已导入的仓库
baseurl=file://$T/repo
enabled=1
gpgcheck=1
gpgkey=file://$T/repo/key.asc
EOF
# 把夹具的 key 假装成「已导入」
rpm_imported_keys() { echo "62313325"; }
export -f rpm_imported_keys 2>/dev/null || true
# 用子 shell 载入被覆盖的函数再跑
out=$(bash -c "
  source '$DIR/lib/repair.sh'
  rpm_imported_keys() { echo '62313325'; }
  dnf_gpgkey_missing '$T/rd'
")
if [[ -z "$out" ]]; then
  echo "  ✅ key 已导入时不报"
else
  echo "  ❌ 误报: $out"
  fail=1
fi

out=$(bash -c "
  source '$DIR/lib/repair.sh'
  rpm_imported_keys() { echo 'deadbeef'; }
  dnf_gpgkey_missing '$T/rd'
")
if [[ "$out" == *"ok-repo"* && "$out" == *"62313325"* ]]; then
  echo "  ✅ key 未导入时报出来（含 repoid 与 keyid）"
else
  echo "  ❌ 没报出来: '$out'"
  fail=1
fi

echo "== gpgcheck=0 的仓库不查（不校验就不该报）=="
mkdir -p "$T/rd2"
cat > "$T/rd2/nocheck.repo" <<EOF
[nocheck]
name=不校验的仓库
baseurl=file://$T/repo
enabled=1
gpgcheck=0
EOF
out=$(bash -c "
  source '$DIR/lib/repair.sh'
  rpm_imported_keys() { echo 'deadbeef'; }
  dnf_gpgkey_missing '$T/rd2'
")
[[ -z "$out" ]] && echo "  ✅ 没报" || { echo "  ❌ 误报: $out"; fail=1; }

echo "== 取得不到 repomd.xml.asc 时不误报（宁可漏报也不假报）=="
mkdir -p "$T/rd3"
cat > "$T/rd3/bad.repo" <<'EOF'
[bad]
name=地址不通
baseurl=file:///nonexistent-path-xyz
enabled=1
gpgcheck=1
EOF
out=$(bash -c "
  source '$DIR/lib/repair.sh'
  rpm_imported_keys() { echo 'deadbeef'; }
  dnf_gpgkey_missing '$T/rd3'
")
[[ -z "$out" ]] && echo "  ✅ 没误报" || { echo "  ❌ 误报: $out"; fail=1; }

echo "== 函数定义必须在主 dispatch 之前 =="
# ⚠️ 这个错本轮**犯了两次**（工具链那次、GPG 这次）：把函数追加到文件末尾，
#    而 `case "$ACTION" in` 在它之前 —— bash 执行到哪定义到哪，
#    运行时就是「未找到命令」。单测全绿也挡不住（测试是 source 整个文件）。
_disp=$(command grep -n '^case "\$ACTION" in' "$DIR/dist/tp.client.sh" | head -1 | cut -d: -f1)
while read -r fn; do
  [[ -z "$fn" ]] && continue
  _ln=$(grep -n "^${fn}()" "$DIR/dist/tp.client.sh" | head -1 | cut -d: -f1)
  if [[ -n "$_ln" && "$_ln" -lt "$_disp" ]]; then
    echo "  ✅ $fn 在第 $_ln 行（dispatch 在 $_disp）"
  else
    echo "  ❌ $fn 在第 ${_ln:-?} 行，晚于 dispatch（$_disp）—— 运行时会「未找到命令」"
    fail=1
  fi
done <<< "$(printf '%s\n' gpgkey_id_from_asc rpm_imported_keys dnf_gpgkey_missing)"

echo "== 两份实现不许分叉 =="
for fn in gpgkey_id_from_asc rpm_imported_keys dnf_gpgkey_missing; do
  if grep -q "^${fn}()" "$DIR/lib/repair.sh" && grep -q "^${fn}()" "$DIR/dist/tp.client.sh"; then
    echo "  ✅ 两份都有 $fn"
  else
    echo "  ❌ 有一份缺少 $fn"
    fail=1
  fi
done

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "GPGKEY-PASS"; else echo "GPGKEY-FAIL"; fi
exit $fail
