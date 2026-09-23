#!/usr/bin/env bash
# client/lib/docker.sh —— Docker daemon 配置的处理
#
# 只做一件事：处理 `registry-mirrors`。
#
# 为什么盯它：配了 registry-mirrors 的机器，Docker **优先走镜像站**，
# 只有全部失效时才回落到 registry-1.docker.io —— 而那个才是被 TProxy
# 劫持到本地缓存的域名。实测：在一台配了 5 个镜像站的机器上拉镜像，
# TProxy 的 registry 日志**一行都没增加**，缓存完全没被用上。
#
# 范围：registry-mirrors **只作用于 Docker Hub**。ghcr.io / quay.io /
# gcr.io / nvcr.io / mcr 不受影响，那些仍然走 TProxy 缓存。
#
# ⚠️ 刻意不碰 data-root：它逐机不同，且改它会让 Docker 换个根目录找数据 ——
#    现有容器与镜像会全部「消失」（数据没丢，但 Docker 看不见），
#    要恢复得把数据搬过去。为「统一配置」付这个代价不值得。

DOCKER_DAEMON_JSON="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"

# 判断：列出已配置的 registry-mirrors，每行一个。只读。
docker_conf_mirrors() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
ms = d.get("registry-mirrors")
if isinstance(ms, list):
    for m in ms:
        print(m)
PY
}

# 读取 data-root 的值。**只用于报告，任何情况下都不修改它。**
#
# 为什么专门列出来：它逐机不同，且改它会让 Docker 换个根目录去找数据 ——
# 现有容器与镜像会全部「消失」（数据没丢，但 Docker 看不见），
# 要恢复得把数据搬过去。所以这个键必须「看见但不碰」。
docker_conf_data_root() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = d.get("data-root")
if isinstance(v, str):
    print(v)
PY
}

# daemon.json 是否合法 JSON。非法返回 1。
docker_conf_valid() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$f" 2>/dev/null
}

# 标准 daemon.json 的键值（data-root 除外 —— 它只保留、不设定）
DOCKER_STD_LOG_DRIVER="json-file"
DOCKER_STD_LOG_OPTS='{"max-size": "50m", "max-file": "5"}'
DOCKER_STD_EXEC_OPTS='["native.cgroupdriver=systemd"]'
DOCKER_STD_STORAGE_DRIVER="overlay2"

# 标准之外、且不是 data-root 的键 —— 标准化时会被替换掉。
# 单独列出来是为了**在被丢弃前报给用户**：无声消失的配置最难查。
docker_conf_extra_keys() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
keep = {"data-root", "registry-mirrors",
        "log-driver", "log-opts", "exec-opts", "storage-driver"}
for k in d:
    if k not in keep:
        print(k)
PY
}

# 读出 storage-driver 的现值。只读。
docker_conf_storage_driver() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = d.get("storage-driver")
if isinstance(v, str):
    print(v)
PY
}

# 现在是否已经就是标准配置（data-root 与异值 storage-driver 不计）。
# 用于「先判断」—— 已经是标准就不该重写文件，那是无谓的 churn。
docker_conf_is_standard() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  docker_conf_valid "$f" || return 1
  [[ -z "$(docker_conf_mirrors "$f")" ]] || return 1
  [[ -z "$(docker_conf_extra_keys "$f")" ]] || return 1

  local drv
  drv=$(docker_conf_storage_driver "$f")
  [[ -z "$drv" || "$drv" == "$DOCKER_STD_STORAGE_DRIVER" ]] || return 1

  STDD_LOG="$DOCKER_STD_LOG_DRIVER" \
  STDD_LOGO="$DOCKER_STD_LOG_OPTS" \
  STDD_EXECO="$DOCKER_STD_EXEC_OPTS" \
  python3 - "$f" <<'PY' 2>/dev/null
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
ok = (d.get("log-driver") == os.environ["STDD_LOG"]
      and d.get("log-opts") == json.loads(os.environ["STDD_LOGO"])
      and d.get("exec-opts") == json.loads(os.environ["STDD_EXECO"]))
sys.exit(0 if ok else 1)
PY
}

# 标准化：保留 data-root，其余键写成标准值。
#
# ⚠️ storage-driver 是**条件保留**的：它与 data-root 同类 ——
#    改了会让 Docker 去别的地方找镜像层，现有镜像与容器会全部「消失」。
#    所以本机已是别的驱动时，保留原值不改（由调用方告警）。
#
# **先判断**：文件不存在或 JSON 非法时不动手。
# **宁可不改也不能写坏**：写坏 daemon.json 会让 Docker 起不来。
docker_conf_normalize() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  docker_conf_valid "$f" || return 3
  command -v python3 >/dev/null 2>&1 || return 2

  local tmp rc
  tmp=$(mktemp) || return 1

  STDD_LOG="$DOCKER_STD_LOG_DRIVER" \
  STDD_LOGO="$DOCKER_STD_LOG_OPTS" \
  STDD_EXECO="$DOCKER_STD_EXEC_OPTS" \
  STDD_DRV="$DOCKER_STD_STORAGE_DRIVER" \
  python3 - "$f" >"$tmp" 2>/dev/null <<'PY'
import json, os, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    old = json.load(fh)

new = {}
# data-root：只保留，不设定 —— 改了会让现有容器与镜像「消失」
if isinstance(old.get("data-root"), str):
    new["data-root"] = old["data-root"]

new["log-driver"] = os.environ["STDD_LOG"]
new["log-opts"] = json.loads(os.environ["STDD_LOGO"])
new["exec-opts"] = json.loads(os.environ["STDD_EXECO"])

# storage-driver 同理：本机已是别的驱动就保留，强行改会让镜像「消失」
cur = old.get("storage-driver")
drv = os.environ["STDD_DRV"]
new["storage-driver"] = cur if (isinstance(cur, str) and cur != drv) else drv

print(json.dumps(new, indent=2, ensure_ascii=False))
PY
  rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"; return 1
  fi
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi

  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/daemon.json.original"
  if [[ ! -f "$bk" ]]; then
    mkdir -p "$(dirname "$bk")" 2>/dev/null || true
    cp -a "$f" "$bk" 2>/dev/null || true
  fi
  cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# 去掉 registry-mirrors，其余键原样保留。
#
# **先判断**：没有该项时一个字节都不动。
# **宁可不改也不能写坏**：JSON 非法、或 python3 不可用时直接失败返回，
# 绝不尝试用 sed 之类的文本手段去「修」JSON —— 写坏了 Docker 起不来，
# 那是比「缓存没命中」严重得多的故障。
docker_conf_strip_mirrors() {
  local f="${1:-$DOCKER_DAEMON_JSON}"
  [[ -f "$f" ]] || return 0
  # 先判合法性：非法 JSON 会让 Docker 起不来，本身就是要报出来的问题。
  # 放在「有没有 mirrors」之前 —— 否则解析失败返回空，会被误当成
  # 「没有 mirrors、无需处理」而静默通过。
  docker_conf_valid "$f" || return 3
  [[ -n "$(docker_conf_mirrors "$f")" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 2

  local tmp rc
  tmp=$(mktemp) || return 1

  # 用 python3 而不是 sed/awk：JSON 不是面向行的，
  # 文本手段处理嵌套结构迟早出错，而写坏 daemon.json 会让 Docker 起不来
  python3 - "$f" >"$tmp" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
d.pop("registry-mirrors", None)
print(json.dumps(d, indent=2, ensure_ascii=False))
PY
  rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"; return 1
  fi
  # 再校验一次产物 —— 宁可不动，也不能把坏文件写进去
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  # 先备份（只备第一次），再用 cat 覆盖 —— 保住原文件的属主与 inode
  local bk="${BACKUP_DIR:-/var/backups/tproxy-client}/daemon.json.original"
  if [[ ! -f "$bk" ]]; then
    mkdir -p "$(dirname "$bk")" 2>/dev/null || true
    cp -a "$f" "$bk" 2>/dev/null || true
  fi
  cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}
