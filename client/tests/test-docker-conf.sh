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

echo "== 标准化：保留 data-root，其余替换成标准 =="
cat > "$T/n.json" <<'EOF'
{
  "data-root": "/opt/docker",
  "registry-mirrors": ["https://docker.1ms.run"],
  "storage-driver": "overlay2",
  "log-driver": "syslog",
  "bip": "172.17.0.1/16",
  "insecure-registries": ["192.168.0.36:5000"]
}
EOF
docker_conf_normalize "$T/n.json" >/dev/null
python3 - "$T/n.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("data-root")=="/opt/docker", "data-root 必须保留"
assert "registry-mirrors" not in d, "mirrors 必须去掉"
assert d.get("log-driver")=="json-file", "log-driver 应换成标准值"
assert d.get("log-opts")=={"max-size":"50m","max-file":"5"}, f"log-opts 不对: {d.get('log-opts')}"
assert d.get("exec-opts")==["native.cgroupdriver=systemd"], f"exec-opts 不对: {d.get('exec-opts')}"
assert d.get("storage-driver")=="overlay2"
assert "bip" not in d and "insecure-registries" not in d, "非标准键应被替换掉"
print("  ✅ data-root 保留，其余已标准化")
PY
[[ $? -eq 0 ]] || fail=1

echo "== 被丢弃的键必须报出来（不能无声消失）=="
extra=$(docker_conf_extra_keys "$T/n.json" 2>/dev/null | tr '\n' ' ')
# 注意：此时文件已被标准化，故用另一份重测
cat > "$T/e.json" <<'EOF'
{"data-root": "/opt/docker", "bip": "172.17.0.1/16", "mtu": 1450}
EOF
extra=$(docker_conf_extra_keys "$T/e.json" | tr '\n' ' ')
if [[ "$extra" == *"bip"* && "$extra" == *"mtu"* && "$extra" != *"data-root"* ]]; then
    echo "  ✅ 报出 bip / mtu，且不含 data-root"
else
    echo "  ❌ 额外键报告不对: '$extra'"
    fail=1
fi

echo "== storage-driver 是异值时必须保留并告警（改了镜像会「消失」）=="
cat > "$T/s.json" <<'EOF'
{"data-root": "/opt/docker", "storage-driver": "devicemapper"}
EOF
if docker_conf_storage_driver "$T/s.json" | grep -q devicemapper; then
    echo "  ✅ 能读出异值驱动"
else
    echo "  ❌ 读不出驱动"
    fail=1
fi
docker_conf_normalize "$T/s.json" >/dev/null
if python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['storage-driver']=='devicemapper'" "$T/s.json" 2>/dev/null; then
    echo "  ✅ 异值驱动被保留（没有强行改成 overlay2）"
else
    echo "  ❌ 强行改了驱动 —— 这台机器的镜像会全部「消失」"
    fail=1
fi

echo "== 没有 data-root 时不该凭空加上 =="
printf '{"log-driver": "syslog"}\n' > "$T/nd.json"
docker_conf_normalize "$T/nd.json" >/dev/null
if python3 -c "import json,sys; assert 'data-root' not in json.load(open(sys.argv[1]))" "$T/nd.json" 2>/dev/null; then
    echo "  ✅ 未强行添加 data-root"
else
    echo "  ❌ 凭空加了 data-root"
    fail=1
fi

echo "== 已经是标准时不该重写（先判断）=="
printf '%s\n' '{"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"5"},"exec-opts":["native.cgroupdriver=systemd"],"storage-driver":"overlay2"}' > "$T/std.json"
if docker_conf_is_standard "$T/std.json"; then
    echo "  ✅ 识别为标准配置"
else
    echo "  ❌ 标准配置没被认出"
    fail=1
fi

echo "== 标准化后仍须是合法 JSON =="
python3 -c "import json,sys; json.load(open('$T/n.json'))" 2>/dev/null \
  && echo "  ✅ 合法" || { echo "  ❌ 产物非法"; fail=1; }

echo "== 两份实现不许分叉 =="
for fn in docker_conf_mirrors docker_conf_strip_mirrors docker_conf_data_root \
          docker_conf_normalize docker_conf_extra_keys docker_conf_storage_driver \
          docker_conf_is_standard; do
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
