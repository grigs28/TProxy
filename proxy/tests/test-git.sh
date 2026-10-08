#!/usr/bin/env bash
# proxy/tests/test-git.sh —— 验证 git 缓存代理
# 在目标机运行。
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0

echo "== git 站点应能通过代理访问 =="
for d in github.com gitlab.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "$CA" --resolve "${d}:443:${TARGET}" \
    "https://${d}/" --max-time 30 2>/dev/null) || code="000"
  if [[ "$code" =~ ^(200|301|302|404)$ ]]; then
    echo "  ✅ $d -> HTTP $code"
  else
    echo "  ❌ $d -> HTTP $code"
    fail=1
  fi
done

echo "== 本机 smart-git 应在 8080 监听 =="
# 用端口监听判断，而非请求 / —— smart-git 不是网页服务器，根路径不对它做响应。
# （历史上这里查的是 gitcache 的 4999；2026-09-24 已换成 smart-git，127.0.0.1:8080。）
# ⚠️ smart-git 只听 127.0.0.1，故此项只在 TARGET 为本机时才有意义 ——
#    远程跑（TPROXY_TARGET=x.x.x.x）时 ss 查的是本机端口，必误报。
if [[ "$TARGET" == "127.0.0.1" ]]; then
  if ss -tln 2>/dev/null | grep -q ':8080 '; then
    echo "  ✅ 8080 已监听"
  else
    echo "  ❌ 8080 未监听（smart-git 未启动）"
    fail=1
  fi
else
  echo "  ⏭️  TARGET=$TARGET（远程），跳过本机端口检查"
fi

echo "== clone 入口（info/refs?service=git-upload-pack）应可达 =="
# 这是 git clone 的入口，也是缓存层真正处理的路径。
# ⚠️ 必须用小仓库（octocat/Hello-World）：git/git 这类巨型仓库首次回源
#    克隆必然超过 curl 超时 —— 曾经用它，这条断言永远 000 误报。
#    （「巨型上游仓库不该进缓存」本来就是既定原则，见 gitproxy/config.toml。）
code=$(curl -s -o /dev/null -w '%{http_code}' \
  --cacert "$CA" --resolve "github.com:443:${TARGET}" \
  "https://github.com/octocat/Hello-World.git/info/refs?service=git-upload-pack" \
  --max-time 60 2>/dev/null) || code="000"
if [[ "$code" =~ ^(200|301|302)$ ]]; then
  echo "  ✅ info/refs -> HTTP $code"
else
  echo "  ❌ info/refs -> HTTP $code"
  fail=1
fi

echo "== ⚠️ push 入口不得被路由到 gitcache =="
# gitcache 不支持 receive-pack，路由过去会让全内网 git push 失败。
# 该请求应直连上游：GitHub 对匿名 push 探测返回 401（需认证），
# 若得到 500/502 则说明被错误地交给了 gitcache。
pcode=$(curl -s -o /dev/null -w '%{http_code}' \
  --cacert "$CA" --resolve "github.com:443:${TARGET}" \
  "https://github.com/octocat/Hello-World.git/info/refs?service=git-receive-pack" \
  --max-time 60 2>/dev/null) || pcode="000"
if [[ "$pcode" =~ ^(200|301|302|401|403)$ ]]; then
  echo "  ✅ receive-pack 探测 -> HTTP $pcode（直连上游）"
else
  echo "  ❌ receive-pack 探测 -> HTTP $pcode（疑似被路由到 gitcache，push 会失败）"
  fail=1
fi

echo "== ⚠️ 带凭据的请求不得落入共享缓存 =="
# gitcache 缓存命中时不校验 Authorization：若私有仓库内容落入本地镜像，
# 任何内网客户端都能无凭据 clone。故带 Authorization 的请求应直连上游。
acode=$(curl -s -o /dev/null -w '%{http_code}' \
  --cacert "$CA" --resolve "github.com:443:${TARGET}" \
  -H "Authorization: Bearer invalid-probe-token" \
  "https://github.com/octocat/Hello-World.git/info/refs?service=git-upload-pack" \
  --max-time 60 2>/dev/null) || acode="000"
if [[ "$acode" =~ ^(200|301|302|401|403)$ ]]; then
  echo "  ✅ 带凭据请求 -> HTTP $acode（直连上游，未落入缓存）"
else
  echo "  ❌ 带凭据请求 -> HTTP $acode"
  fail=1
fi

echo "== ⚠️ 协议 v2 的 POST 必须直连（smart-git 不认识 v2，会返 500 文本）=="
# 背景（2026-10-08 实测，详见 docs/巡检日志/2026-10-08-git-500根因分析.md）：
#   smart-git 不支持 Git 协议 v2 的 POST 命令（command=ls-refs / command=fetch），
#   收到后返回 HTTP 500 + body "500 Internal Server Error\n"（Go http.Error）。
#   git 客户端按 pkt-line 协议解析响应体，前 4 字节是 "500 " ——
#   空格不是合法十六进制 → 「协议错误：错误的行长度字符：500」。
#   （那三个字符是**响应体文本的开头**，不是 HTTP 状态码的显示。）
#
#   真实 git 客户端不会中招（v2 是协商制，服务器无 v2 标识就回退 v0），
#   但固定发 v2 body 的实现（go-git / libgit2 / 某些 CI 工具）必中招。
#
#   所以 git.conf 的 map 必须把带 `Git-Protocol: version=2` 头的请求
#   **从一开始就分流直连**（不能等 500 后回落 —— 本 server 段
#   `proxy_request_buffering off`，POST 体已流走，回落必坏，历史上踩过）。
V2BIN=$(mktemp)
printf '0014command=ls-refs\n0000' > "$V2BIN"
v2code=$(curl -s -o /dev/null -w '%{http_code}' \
  --cacert "$CA" --resolve "github.com:443:${TARGET}" \
  -X POST "https://github.com/octocat/Hello-World.git/git-upload-pack" \
  -H "Content-Type: application/x-git-upload-pack-request" \
  -H "Git-Protocol: version=2" \
  --data-binary "@$V2BIN" --max-time 60 2>/dev/null) || v2code="000"
rm -f "$V2BIN"
if [[ "$v2code" =~ ^(200|401|403)$ ]]; then
  echo "  ✅ v2 POST -> HTTP $v2code（直连 GitHub，v2 应答正常）"
else
  echo "  ❌ v2 POST -> HTTP $v2code（进了缓存层：smart-git 不认 v2，返 500 文本会毁掉 git 的协议解析）"
  fail=1
fi

echo "== git.conf 必须有 v2 分流（静态守卫）=="
GITCONF="$(cd "$(dirname "$0")/../tengine/conf.d" && pwd)/git.conf"
if command grep -qE 'map \$http_git_protocol \$git_proto_v2' "$GITCONF" 2>/dev/null \
   && command grep -qE '\$git_cacheable\$git_is_push\$git_has_auth\$git_proto_v2' "$GITCONF" 2>/dev/null; then
  echo "  ✅ map 已含 git_proto_v2 维度"
else
  echo "  ❌ git.conf 缺 v2 分流 map —— v2 POST 会进缓存层被 smart-git 返 500"
  fail=1
fi

if [[ $fail -eq 0 ]]; then echo "GIT-ALL-PASS"; else echo "GIT-HAS-FAILURE"; fi
exit $fail
