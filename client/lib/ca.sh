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
install_runtime_ca() {
  local cert="$1"
  local found=0
  local candidates=()
  for pat in /opt/conda*/ssl/cacert.pem /opt/miniconda*/ssl/cacert.pem \
             /opt/anaconda*/ssl/cacert.pem "$HOME"/miniconda*/ssl/cacert.pem \
             "$HOME"/anaconda*/ssl/cacert.pem; do
    # 未匹配的 glob 会原样返回，故需 -f 判断
    [[ -f "$pat" ]] && candidates+=("$pat")
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "未发现自带 CA bundle 的运行时，跳过"
    return 0
  fi

  for f in "${candidates[@]}"; do
    if grep -qF "TProxy Root CA" "$f" 2>/dev/null; then
      echo "   $f 已含 TProxy CA，跳过"
    else
      {
        printf '\n# TProxy Root CA\n'
        cat "$cert"
      } >> "$f"
      echo "   已追加到 $f"
    fi
    found=1
  done
  [[ $found -eq 1 ]] && echo "⚠️  自带 CA bundle 的工具（如 conda 的 curl/python）现已信任本代理"
  return 0
}

install_java_ca() {
  local cert="$1"
  local ks=""
  # 优先 JAVA_HOME，其次在常见路径下找
  if [[ -n "${JAVA_HOME:-}" && -f "$JAVA_HOME/lib/security/cacerts" ]]; then
    ks="$JAVA_HOME/lib/security/cacerts"
  else
    ks=$(find /usr/lib/jvm -name cacerts -path '*security*' 2>/dev/null | head -1)
  fi
  if [[ -z "$ks" ]]; then
    echo "未找到 JDK cacerts，跳过"
    return 0
  fi
  keytool -importcert -noprompt -trustcacerts \
    -alias tproxy-ca -file "$cert" -keystore "$ks" -storepass changeit 2>&1 | tail -2
  echo "Java cacerts 已更新: $ks"
}
