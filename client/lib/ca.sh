#!/usr/bin/env bash
# client/lib/ca.sh —— 根 CA 安装（系统信任库 + 工具级信任库）
#
# 为什么需要「工具级」：系统信任库并不被所有工具读取。
#   · Docker daemon 用自己的一套 —— 必须放到 /etc/docker/certs.d/<域名>/ca.crt
#   · Java 用 JDK 自带的 cacerts —— 必须用 keytool 导入
# 而 dnf/apt/curl/pip/npm 读系统库，无需额外操作。

CA_DEST_NAME="tproxy-ca.crt"

# Docker 客户端不读系统 CA 库，必须按【域名】逐个放置 CA。
# 清单须与 dnsmasq 劫持的 Docker 域名一致 —— 漏一个，该仓库拉取就报证书错误。
docker_ca_domains() {
  cat <<'EOF'
registry-1.docker.io
auth.docker.io
production.cloudflare.docker.com
quay.io
gcr.io
ghcr.io
k8s.gcr.io
registry.k8s.io
mcr.microsoft.com
nvcr.io
EOF
}

install_system_ca() {
  local cert="$1"
  [[ -f "$cert" ]] || { echo "❌ 证书不存在: $cert"; return 1; }
  case "$(detect_distro)" in
    ubuntu)
      install -m 644 "$cert" "/usr/local/share/ca-certificates/$CA_DEST_NAME"
      update-ca-certificates 2>&1 | tail -2
      ;;
    rhel)
      install -m 644 "$cert" "/etc/pki/ca-trust/source/anchors/$CA_DEST_NAME"
      update-ca-trust extract
      ;;
    *)
      echo "❌ 不支持的发行版，请手动安装 $cert"
      return 1
      ;;
  esac
  echo "系统信任库已更新"
}

install_docker_ca() {
  local cert="$1"
  [[ -d /etc/docker ]] || { echo "未安装 docker，跳过"; return 0; }
  while read -r d; do
    [[ -z "$d" ]] && continue
    install -d -m 755 "/etc/docker/certs.d/$d"
    install -m 644 "$cert" "/etc/docker/certs.d/$d/ca.crt"
  done < <(docker_ca_domains)
  echo "Docker 证书目录已写入（$(docker_ca_domains | grep -c .) 个域名）"
  echo "⚠️  需重启 docker 才生效：systemctl restart docker"
}

# 某些运行时自带 CA bundle，**不读系统信任库**。最典型的是 conda：
# /opt/conda3/bin/curl 会使用 /opt/conda3/ssl/cacert.pem，
# 导致「系统装了根 CA、conda 的 curl 仍报 unknown CA」。
# 表现极具迷惑性：同一台机器上 /usr/bin/curl 正常，conda curl 失败。
# 标记行：回滚时据此精确删除追加内容，不误伤用户原有的证书
_RUNTIME_MARK="# TProxy Root CA"

_runtime_candidates() {
  # 必须同时扫描 /home/* —— 脚本以 root 运行，$HOME 是 /root，
  # 普通用户安装的 miniconda 不会被 $HOME 通配匹配到
  local pats=(
    /opt/conda*/ssl/cacert.pem
    /opt/miniconda*/ssl/cacert.pem
    /opt/anaconda*/ssl/cacert.pem
    /home/*/miniconda*/ssl/cacert.pem
    /home/*/anaconda*/ssl/cacert.pem
    /root/miniconda*/ssl/cacert.pem
    /root/anaconda*/ssl/cacert.pem
  )
  local p
  for p in "${pats[@]}"; do
    [[ -f "$p" ]] && printf '%s\n' "$p"
  done
}

# 追加标记**带上证书指纹**。
# 只写固定字串的话，根 CA 一换就会误判「已装过」而跳过 —— 客户端继续拿着
# 旧根，而 conda / miniconda 读的是自己的 ssl/cacert.pem、不读系统信任库，
# 表现为「换根后 conda/pip 连不上」，且完全看不出是信任锚没换。
_runtime_mark_for() {
  local cert="$1" fp
  fp=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null \
       | sed 's/.*=//; s/://g')
  printf '%s %s' "$_RUNTIME_MARK" "${fp:-unknown}"
}

# 确保 bundle 对普通用户可读。
# conda / pip 常以普通用户身份运行；bundle 若只剩 root 可读，
# 它们连自己的 CA 包都打不开，curl 只报 exit 77，
# 信息里完全看不出是权限问题。
# ⚠️ 不能用 [[ -r ]] 判断 —— 本脚本以 root 运行，root 永远读得到。
_runtime_make_readable() {
  local f="$1" mode
  mode=$(stat -c '%a' "$f" 2>/dev/null || echo "")
  [[ -n "$mode" ]] || return 0
  if (( (8#$mode & 8#004) == 0 )); then
    chmod 644 "$f" 2>/dev/null || true
  fi
  return 0
}

# 去掉此前追加的 TProxy 块（标记行起、到文件末尾）。没有则原样返回。
_runtime_strip() {
  local f="$1" tmp
  grep -qF "$_RUNTIME_MARK" "$f" 2>/dev/null || return 0
  tmp=$(mktemp) || return 1
  if ! awk -v mark="$_RUNTIME_MARK" 'index($0, mark) { exit } { print }' "$f" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  # 用 cat 覆盖而不是 mv：保留原文件的属主与 inode。
  # 这些 bundle 常在 root 独占的目录里，mv 会把属主换掉。
  cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

install_runtime_ca() {
  local cert="$1"
  local mark
  mark=$(_runtime_mark_for "$cert")
  local found=0
  local f
  while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qF "$mark" "$f" 2>/dev/null; then
      # 内容已是最新，但权限未必对。这条分支必须先修权限再跳过：
      # 一台机器只要曾经对过一次，之后每次跑都走到这里，
      # 不修的话它永远好不了。
      _runtime_make_readable "$f"
      echo "   $f 已是最新，跳过"
    elif ! _runtime_strip "$f"; then
      echo "   ⚠ $f 处理失败，跳过（请手工检查）"
    else
      {
        printf '\n%s\n' "$mark"
        cat "$cert"
      } >> "$f"
      _runtime_make_readable "$f"
      echo "   已更新 $f"
    fi
    found=1
  done < <(_runtime_candidates)

  [[ $found -eq 0 ]] && echo "未发现自带 CA bundle 的运行时，跳过"
  return 0
}

remove_runtime_ca() {
  local f
  while read -r f; do
    [[ -z "$f" ]] && continue
    grep -qF "$_RUNTIME_MARK" "$f" 2>/dev/null || continue
    # 删掉「标记行及其后的证书块」：标记行之后到文件末尾即为追加内容
    # （追加时总是在末尾，且证书 PEM 内不含我们的标记行）
    _runtime_strip "$f" || { echo "   ⚠ $f 处理失败，跳过"; continue; }
    echo "   已从 $f 移除 TProxy CA"
    # 去掉可能残留的尾部空行
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$f" 2>/dev/null || true
  done < <(_runtime_candidates)
  return 0
}

install_java_ca() {
  local cert="$1"
  local keystores=()

  # 遍历【所有】JDK —— 只装第一个会让其余 JDK 上的 Maven/Gradle 构建
  # 仍然报证书错误，而多 JDK 在开发机上很常见
  if [[ -n "${JAVA_HOME:-}" && -f "$JAVA_HOME/lib/security/cacerts" ]]; then
    keystores+=("$JAVA_HOME/lib/security/cacerts")
  fi
  local found
  while read -r found; do
    [[ -z "$found" ]] && continue
    # 去重（JAVA_HOME 可能与 /usr/lib/jvm 下的是同一个）
    local dup=0 k
    for k in "${keystores[@]:-}"; do
      [[ "$k" == "$found" ]] && dup=1 && break
    done
    [[ $dup -eq 0 ]] && keystores+=("$found")
  # ⚠️ 排除容器镜像层目录（*/overlay2/*）。
  # 当 Docker 的 data-root 在 /opt 下（实测 ai02 就是 /opt/docker）时，
  # `find /opt` 会扫进 overlay2 —— 那里是**容器自己的** JDK，
  # 改它们既无意义（容器不用宿主机的认证），又在动别人的镜像层。
  done < <(find /usr/lib/jvm /opt -name cacerts -path '*security*' \
             -not -path '*/overlay2/*' 2>/dev/null)

  if [[ ${#keystores[@]} -eq 0 ]]; then
    echo "未找到 JDK cacerts，跳过"
    return 0
  fi

  local ks
  for ks in "${keystores[@]}"; do
    # 先删再导入：alias 已存在时 keytool 会拒绝导入，
    # 那会让 CA 轮换后重跑脚本时 Java 库永远停留在旧证书
    keytool -delete -alias tproxy-ca -keystore "$ks" -storepass changeit >/dev/null 2>&1 || true
    if keytool -importcert -noprompt -trustcacerts \
        -alias tproxy-ca -file "$cert" -keystore "$ks" -storepass changeit >/dev/null 2>&1; then
      echo "   ✅ $ks"
    else
      echo "   ⚠️  $ks 导入失败（可能无写权限）"
    fi
  done
  echo "Java cacerts 已更新（${#keystores[@]} 个）"
}
