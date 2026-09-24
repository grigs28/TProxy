#!/usr/bin/env bash
# client/tests/test-fallback.sh —— 没有分发平台（/opt/grigs/bas.sh）时的兜底
#
# 为什么值得测：`dist/tp.client.sh` 开头是
#     source /opt/grigs/bas.sh 2>/dev/null || { ...兜底... }
# 兜底是给**没装平台**的机器用的。实测 .9(CentOS 7) / .17(istoreos) /
# .78(Debian 12) 就是这种机器，而兜底当时有两个毛病：
#   1. 缺 print_color —— 脚本第 1653 行直接报「print_color: 未找到命令」
#   2. print_* 不支持 printf 语义 —— 输出里全是字面 `%s`，数字全丢
# 两个都在**本机测不出来**（本机有 bas.sh），只有真机跑才暴露。
#
# 所以这里不跑整个脚本，而是把兜底块**抽出来单独执行**。
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/dist/tp.client.sh"

fail=0
T=$(mktemp -d)

# 抽出 `source ... || { ... }` 这一整块，把 `source ... || ` 去掉、**留下 `{`**
# —— 只删 source 那半行，否则剩下一个孤零零的 `}` 会语法错（我第一版就是这么错的）
awk '/^source \/opt\/grigs\/bas\.sh/,/^}/' "$SCRIPT" \
  | sed '1s#^source /opt/grigs/bas\.sh 2>/dev/null || ##' > "$T/fallback.sh"
if [[ ! -s "$T/fallback.sh" ]]; then
  echo "  ❌ 抽不出兜底块 —— 脚本结构变了，本测试要跟着改"
  rm -rf "$T"; echo "FALLBACK-FAIL"; exit 1
fi

echo "== 兜底块能独立执行吗 =="
if ! bash -c "source '$T/fallback.sh'" 2>"$T/err"; then
  echo "  ❌ 兜底块本身执行报错:"; sed 's/^/     /' "$T/err"
  fail=1
else
  echo "  ✅ 能执行"
fi

echo "== 脚本从 bas.sh 调的每个函数，兜底都要有 =="
# 只有被 `command -v` 保护起来的才算可选 —— 那种调用不到也不影响运行
OPTIONAL="ins_dnf"
bas_fns=$(command grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' /opt/grigs/bas.sh 2>/dev/null | tr -d '()' | sort -u)
if [[ -z "$bas_fns" ]]; then
  echo "  ⏭  本机没有 /opt/grigs/bas.sh，跳过（无法枚举平台函数）"
else
  dist_fns=$(command grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$SCRIPT" | tr -d '()' | sort -u)
  fb_fns=$(command grep -oE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$T/fallback.sh" | tr -d ' ()' | sort -u)
  # ⚠️ 必须在**去掉注释后**的代码里找调用。否则注释里提到某个函数名
  # （比如解释 bas.sh 的 print_* 内部走 translate）就会被当成"脚本调用了它"，
  # 报出假缺失 —— 我第一版就是这么误报 translate 的。
  code=$(sed 's/#.*//' "$SCRIPT")
  missing=""
  while read -r fn; do
    [[ -z "$fn" ]] && continue
    # 脚本用了它（且不是自己定义的）
    command grep -qE "(^|[^a-zA-Z_])${fn}([[:space:]]|$)" <<<"$code" || continue
    command grep -qx "$fn" <<<"$dist_fns" && continue
    command grep -qx "$fn" <<<"$OPTIONAL" && continue
    command grep -qx "$fn" <<<"$fb_fns" && continue
    missing+="$fn "
  done <<< "$bas_fns"
  if [[ -z "$missing" ]]; then
    echo "  ✅ 没有遗漏"
  else
    echo "  ❌ 兜底缺少: $missing  → 无平台的机器上会「未找到命令」"
    fail=1
  fi
fi

echo "== 兜底函数要支持 printf 语义（%s 必须被替换）=="
out=$(bash -c "source '$T/fallback.sh'; print_info '目标服务器: %s' '192.168.0.18'")
if [[ "$out" == *"192.168.0.18"* && "$out" != *"%s"* ]]; then
  echo "  ✅ print_info 的 %s 被替换了"
else
  echo "  ❌ print_info 输出了字面 %s: '$out'"
  fail=1
fi
out=$(bash -c "source '$T/fallback.sh'; print_warning '有 metalink（%s 个文件）' '3'")
if [[ "$out" == *"3"* && "$out" != *"%s"* ]]; then
  echo "  ✅ print_warning 的数字没丢"
else
  echo "  ❌ print_warning 输出: '$out'"
  fail=1
fi

echo "== print_color 必须存在且不报错 =="
out=$(bash -c "source '$T/fallback.sh'; print_color '绿' '### tp.client.sh ###'" 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *"tp.client.sh"* ]]; then
  echo "  ✅ print_color 可用（输出剔除 ANSI 后：$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out"))"
else
  echo "  ❌ print_color 不可用（rc=$rc）: $out"
  fail=1
fi

echo "== 无参数时不该崩（%s 少于参数、完全没有参数）=="
for c in "print_info '纯文本'" "print_info" "print_step ''" "print_success 'a' 'b' 'c'"; do
  if ! bash -c "source '$T/fallback.sh'; $c" >/dev/null 2>"$T/e2"; then
    echo "  ❌ '$c' 报错:"; sed 's/^/     /' "$T/e2"; fail=1
  fi
done
[[ $fail -eq 0 ]] && echo "  ✅ 边界情况不崩"

echo "== 两份实现不许分叉：脚本里仍要有兜底块 =="
if command grep -q '^source /opt/grigs/bas\.sh' "$SCRIPT" && command grep -q 'print_color()' "$T/fallback.sh"; then
  echo "  ✅ 兜底块完好"
else
  echo "  ❌ 兜底块缺失或被删"
  fail=1
fi

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "FALLBACK-PASS"; else echo "FALLBACK-FAIL"; fi
exit $fail
