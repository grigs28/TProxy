#!/usr/bin/env bash
# client/tests/test-docker-conf.sh —— Docker daemon.json 的处理
#
# 为什么值得测：改了别人的 daemon.json 又写坏，Docker 会起不来 ——
# 那是比「缓存没命中」严重得多的故障。所以这里重点验证：
#   · 只动 registry-mirrors，其余键一个不碰
#   · JSON 非法时**不写**，宁可不动也不能写坏
#   · 先判断：没有 mirrors 时一个字节都不动
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/docker.sh
source "$DIR/lib/docker.sh"

fail=0
T=$(mktemp -d)

echo "== 检出 registry-mirrors =="
cat > "$T/a.json" <<'EOF'
{
  "data-root": "/opt/docker",
  "registry-mirrors": ["https://docker.1ms.run", "https://docker.m.daocloud.io"],
  "log-driver": "json-file"
}
EOF
got=$(docker_conf_mirrors "$T/a.json" | tr '\n' ' ')
if [[ "$got" == *"docker.1ms.run"* && "$got" == *"docker.m.daocloud.io"* ]]; then
  echo "  ✅ 检出 2 个镜像站"
else
  echo "  ❌ 检出失败: $got"
  fail=1
fi

echo "== 去掉 mirrors，其余键必须原样保留 =="
docker_conf_strip_mirrors "$T/a.json" >/dev/null
python3 - "$T/a.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert "registry-mirrors" not in d, "mirrors 没被去掉"
assert d.get("data-root")=="/opt/docker", "data-root 被改坏了"
assert d.get("log-driver")=="json-file", "log-driver 被改坏了"
print("  ✅ mirrors 已去掉，data-root / log-driver 原样保留")
PY
[[ $? -eq 0 ]] || fail=1

echo "== 嵌套与其他键的类型不能被破坏 =="
cat > "$T/b.json" <<'EOF'
{
  "registry-mirrors": ["https://a.example"],
  "log-opts": {"max-size": "50m", "max-file": "5"},
  "exec-opts": ["native.cgroupdriver=systemd"],
  "features": {"buildkit": true},
  "insecure-registries": ["192.168.0.36:5000"]
}
EOF
docker_conf_strip_mirrors "$T/b.json" >/dev/null
python3 - "$T/b.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert "registry-mirrors" not in d
assert d["log-opts"]=={"max-size":"50m","max-file":"5"}
assert d["exec-opts"]==["native.cgroupdriver=systemd"]
assert d["features"]=={"buildkit":True}
assert d["insecure-registries"]==["192.168.0.36:5000"]
print("  ✅ 嵌套对象、数组、其他键全部完好")
PY
[[ $? -eq 0 ]] || fail=1

echo "== data-root 只读不写 =="
dr=$(docker_conf_data_root "$T/a.json")
if [[ "$dr" == "/opt/docker" ]]; then
    echo "  ✅ 能读出 data-root（$dr）"
else
    echo "  ❌ 读不出 data-root: '$dr'"
    fail=1
fi
# 上面已经 strip 过一次，data-root 必须还在
if python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['data-root']=='/opt/docker'" "$T/a.json" 2>/dev/null; then
    echo "  ✅ strip 之后 data-root 仍在"
else
    echo "  ❌ data-root 被动过了 —— 改它会让容器全部「消失」"
    fail=1
fi
echo "== 先判断：没有 mirrors 时一个字节都不动 =="
printf '{\n  "data-root": "/opt/docker"\n}\n' > "$T/c.json"
before=$(md5sum "$T/c.json" | cut -d' ' -f1)
docker_conf_strip_mirrors "$T/c.json" >/dev/null
if [[ "$before" == "$(md5sum "$T/c.json" | cut -d' ' -f1)" ]]; then
  echo "  ✅ 没动文件"
else
  echo "  ❌ 没有问题却改了文件"
  fail=1
fi

echo "== JSON 非法时必须拒绝改写（宁可不动也不能写坏）=="
printf '{ this is not json\n' > "$T/bad.json"
before=$(md5sum "$T/bad.json" | cut -d' ' -f1)
if docker_conf_strip_mirrors "$T/bad.json" >/dev/null 2>&1; then
  echo "  ❌ 非法 JSON 却报成功"
  fail=1
else
  echo "  ✅ 正确地拒绝了"
fi
if [[ "$before" == "$(md5sum "$T/bad.json" | cut -d' ' -f1)" ]]; then
  echo "  ✅ 非法 JSON 未被写坏"
else
  echo "  ❌ 非法 JSON 被覆盖了 —— Docker 会起不来"
  fail=1
fi

echo "== 文件不存在时安全返回 =="
if docker_conf_mirrors "$T/nope.json" >/dev/null 2>&1; then
  echo "  ✅ 不存在的文件不报错"
else
  echo "  ❌ 处理不存在的文件时出错"
  fail=1
fi

echo "== 两份实现不许分叉 =="
for fn in docker_conf_mirrors docker_conf_strip_mirrors; do
  if grep -q "^${fn}()" "$DIR/lib/docker.sh" && grep -q "^${fn}()" "$DIR/dist/tp.client.sh"; then
    echo "  ✅ 两份都有 $fn"
  else
    echo "  ❌ 有一份缺少 $fn"
    fail=1
  fi
done

rm -rf "$T"
if [[ $fail -eq 0 ]]; then echo "DOCKERCONF-PASS"; else echo "DOCKERCONF-FAIL"; fi
exit $fail
