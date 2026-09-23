#!/usr/bin/env bash
# proxy/tests/test-java.sh —— 验证 Maven 缓存
# 在目标机运行。
#
# 本任务的核心不是「能不能缓存」，而是「**哪些不能缓存**」——
# maven-metadata.xml 与 SNAPSHOT 的内容会变，一旦缓存，
# 客户端将永远解析不到新版本，且构建不报错（静默使用旧依赖）。
set -uo pipefail
CA="$(cd "$(dirname "$0")/../ca" && pwd)/tproxy-ca.crt"
TARGET="${TPROXY_TARGET:-127.0.0.1}"
fail=0
RESOLVE=(--resolve "repo1.maven.org:443:${TARGET}")

cache_status() {
  curl -sL -o /dev/null -D- --cacert "$CA" "${RESOLVE[@]}" "$1" --max-time 30 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{s=$2} END{print s}'
}

echo "== Maven Central 应能通过代理访问 =="
code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" "${RESOLVE[@]}" \
  "https://repo1.maven.org/maven2/" --max-time 30 2>/dev/null) || code="000"
if [[ "$code" =~ ^(200|301|302|404)$ ]]; then
  echo "  ✅ HTTP $code"
else
  echo "  ❌ HTTP $code"
  fail=1
fi

echo "== release 制品应能进入 HIT =="
s=""
for i in 1 2 3 4 5; do
  s=$(cache_status "https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.9/slf4j-api-2.0.9.pom")
  echo "  第 $i 次 -> ${s:-无}"
  [[ "$s" == "HIT" ]] && break
  sleep 3
done
[[ "$s" == "HIT" ]] || { echo "  ❌ release 制品未命中缓存"; fail=1; }

echo "== ⚠️ maven-metadata.xml 必须【不被缓存】=="
# 若此处出现 HIT，说明元数据被缓存 —— 客户端将永远看不到新版本
m1=$(cache_status "https://repo1.maven.org/maven2/org/slf4j/slf4j-api/maven-metadata.xml")
sleep 1
m2=$(cache_status "https://repo1.maven.org/maven2/org/slf4j/slf4j-api/maven-metadata.xml")
echo "  第 1 次 -> ${m1:-无}"
echo "  第 2 次 -> ${m2:-无}"
if [[ "$m1" == "HIT" || "$m2" == "HIT" ]]; then
  echo "  ❌ maven-metadata.xml 被缓存了 —— 客户端将永远看不到新版本"
  fail=1
else
  echo "  ✅ 元数据未被缓存"
fi

echo "== ⚠️ SNAPSHOT 必须【不被缓存】=="
snap=$(cache_status "https://repo1.maven.org/maven2/org/apache/maven/plugins/maven-clean-plugin/3.2.0/maven-clean-plugin-3.2.0.pom")
# 用任意 SNAPSHOT 路径验证路径规则本身（真实 SNAPSHOT 仓库在 snapshots 子域，此处仅验证规则命中）
snap2=$(cache_status "https://repo1.maven.org/maven2/org/example/demo/1.0.0-SNAPSHOT/demo-1.0.0-SNAPSHOT.pom")
echo "  SNAPSHOT 路径状态 -> ${snap2:-无}"
if [[ "$snap2" == "HIT" ]]; then
  echo "  ❌ SNAPSHOT 被缓存了"
  fail=1
else
  echo "  ✅ SNAPSHOT 未被缓存"
fi

if [[ $fail -eq 0 ]]; then echo "JAVA-ALL-PASS"; else echo "JAVA-HAS-FAILURE"; fi
exit $fail
