#!/usr/bin/env bash
# client/tests/test-help.sh —— 帮助必须是「现在就要用这条命令的人」能快速看完的
#
# 原先两个入口的帮助都失控过：
#   · dist 版把整个文件头注释当帮助打印，共 57 行 —— 要找的那个参数
#     淹没在「为什么这么设计」的说明里
#   · client-setup.sh 用写死的行号 sed -n '2,12p'，头部注释一增删，
#     帮助就会开始打印代码（漏出 "}" 之类）
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail=0

# 帮助是给人扫一眼的，不是设计文档。维护者的取舍理由留在源码注释里。
MAX_LINES=24

# 两个入口的参数集不同，不能套用同一份清单：
#   client-setup.sh   给仓库内直接用，参数是 --ca/--server/--rollback
#   dist/tp.client.sh 给下发到节点执行，参数是 -i/-c/-d/-s/-r
while IFS='|' read -r entry opts; do
  name=$(basename "$entry")
  echo "== $name =="

  help=$(bash "$entry" -h 2>/dev/null)
  if [[ -z "$help" ]]; then
    echo "  ❌ -h 没有任何输出"
    fail=1
    continue
  fi

  lines=$(printf '%s\n' "$help" | wc -l)
  if (( lines <= MAX_LINES )); then
    echo "  ✅ 帮助 $lines 行（上限 $MAX_LINES）"
  else
    echo "  ❌ 帮助 $lines 行，超过 $MAX_LINES —— 又变回设计文档了"
    fail=1
  fi

  # 每个支持的选项都必须在帮助里出现，否则加了参数没人知道
  missing=""
  for opt in $opts; do
    grep -q -- "$opt" <<<"$help" || missing="$missing $opt"
  done
  if [[ -z "$missing" ]]; then
    echo "  ✅ 选项齐全"
  else
    echo "  ❌ 帮助里没有:$missing"
    fail=1
  fi

  # 帮助里不该漏出 shell 代码 —— 硬编码行号一旦错位就是这个症状
  if grep -qE '^\s*\}\s*$|\(\)\s*\{|^\s*(exit|return|local|fi|esac)\b' <<<"$help"; then
    echo "  ❌ 帮助里漏出了 shell 代码："
    grep -nE '^\s*\}\s*$|\(\)\s*\{|^\s*(exit|return|local|fi|esac)\b' <<<"$help" | sed 's/^/       /'
    fail=1
  else
    echo "  ✅ 没有漏出代码"
  fi

  # 刻意不检查「是否夹带设计说明」—— 那条线画不清：
  # 「脚本会修改哪些东西」「回滚只撤销一部分」既是说明也是用户需要知道的。
  # 能客观守住的是行数上限，那才是真正要防的东西。
done <<< "$DIR/client-setup.sh|--ca --server --rollback -h
$DIR/dist/tp.client.sh|-i -c -d -s -r --server -h"

if [[ $fail -eq 0 ]]; then echo "HELP-PASS"; else echo "HELP-FAIL"; fi
exit $fail
