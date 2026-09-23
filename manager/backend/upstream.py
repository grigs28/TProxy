"""新增上游：劫持规则 + 证书 + tengine 分流，三处联动。

为什么值得做成功能而不是让人手改：新增一个上游要同时改三个地方，
**漏任何一处都不会报错，只是静默不生效**——

  1. dnsmasq 的 address=      漏了 → 域名压根不被劫持
  2. ca/gen-cert.sh 签证书    漏了 → HTTPS 握手失败（TLS 断在证书上）
  3. tengine 的 server_name   漏了 → 请求落到 default_server 被 444 拒绝

安全要点：域名会被**直接拼进配置文件**，所以校验必须严格 ——
尤其要挡住换行（`evil.com\\naddress=/x/1.2.3.4` 能往 dnsmasq 注入任意规则）。
"""
import os
import re

# 类型 → tengine/conf.d 下的文件名。改这里前先对照实际 conf.d 内容。
CATEGORIES = {
    "os": "os-repo.conf",
    "docker": "registry.conf",
    "git": "git.conf",
    "python": "python.conf",
    "nodejs": "nodejs.conf",
    "java": "java.conf",
}

# 域名：可选通配前缀 + 至少两段 + 字母 TLD
_DOMAIN_RE = re.compile(
    r"^(\*\.)?"
    r"([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+"
    r"[a-zA-Z]{2,}$"
)

# 能破坏配置文件结构的字符。包含换行、注释符、shell 元字符。
# 注意不含 `*` —— `*.example.com` 是 dnsmasq 的合法通配写法。
# 中间出现 `*` 会被域名的正则挡下（标签字符集不含它），故不必在此拦。
_FORBIDDEN = set('\n\r\t ;|&$`\\"\'<>(){}[]#?~')


def validate_domain(domain):
    """校验域名。返回 (ok, errmsg)。

    这些字符必须挡住：换行能注入任意 dnsmasq 规则，分号能截断 nginx 指令，
    `$` 反引号在脚本语境里会被求值。
    """
    if domain is None or not str(domain).strip():
        return False, "域名不能为空"

    domain = str(domain)
    if domain != domain.strip():
        return False, "域名不能含首尾空白"
    if len(domain) > 253:
        return False, "域名过长（超过 253 字符）"

    bad = sorted(set(domain) & _FORBIDDEN)
    if bad:
        return False, f"域名含非法字符: {' '.join(repr(c) for c in bad)}"

    if not _DOMAIN_RE.match(domain):
        return False, "域名格式非法（示例：repo.example.org）"

    return True, ""


def _target_ip(base_dir):
    """劫持目标 IP。从 .env 的 HOST_IP 读，缺省 192.168.0.18。"""
    env_path = os.path.join(os.path.dirname(base_dir.rstrip("/")), ".env")
    try:
        with open(env_path, encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("HOST_IP="):
                    v = line.split("=", 1)[1].strip()
                    if v:
                        return v
    except OSError:
        pass
    return "192.168.0.18"


def _paths(base_dir):
    return {
        "dnsmasq": os.path.join(base_dir, "dnsmasq", "dnsmasq.conf"),
        "conf_d": os.path.join(base_dir, "tengine", "conf.d"),
        "ca": os.path.join(base_dir, "ca"),
    }


def preview_upstream(domain, category, base_dir):
    """返回将要做的改动，供界面展示后由人确认。

    只读，不碰任何文件。
    """
    ok, err = validate_domain(domain)
    if not ok:
        return {"ok": False, "msg": err}
    if category not in CATEGORIES:
        return {"ok": False,
                "msg": f"未知类型: {category}（可选: {', '.join(CATEGORIES)}）"}

    p = _paths(base_dir)
    conf_file = CATEGORIES[category]
    ip = _target_ip(base_dir)

    return {
        "ok": True,
        "msg": "",
        "domain": domain,
        "category": category,
        "needs_restart": True,
        "changes": [
            {
                "file": "dnsmasq/dnsmasq.conf",
                "action": "追加劫持规则",
                "diff": f"+ address=/{domain}/{ip}",
                "desc": f"把 {domain} 解析到代理 {ip}",
            },
            {
                "file": f"tengine/conf.d/{conf_file}",
                "action": "加入 server_name",
                "diff": f"+ {domain}",
                "desc": "让 tengine 按该域名分流（否则落到 default_server 被拒）",
            },
            {
                "file": f"ca/certs/{domain}.crt",
                "action": "签发证书",
                "diff": f"+ {domain}.crt / {domain}.key",
                "desc": "为该域名签发 TLS 证书（否则 HTTPS 握手失败）",
            },
        ],
        "note": (
            "生效需重启 dnsmasq 与 tengine —— 两者都是 :ro 文件挂载，"
            "仅 reload 不会重新挂载。"
        ),
    }


def _append_dnsmasq_rule(path, domain, ip):
    """追加 address= 规则。已存在则不重复（幂等）。"""
    line = f"address=/{domain}/{ip}"
    content = ""
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            content = f.read()

    if line in content:
        return False  # 已存在

    if content and not content.endswith("\n"):
        content += "\n"
    content += f"\n# 由管理界面添加\n{line}\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return True


def _add_server_name(path, domain):
    """把域名加进该文件里**每一段**未注释的 server_name。幂等。

    必须遍历全部而不是只改第一段：一个 conf 文件通常有 HTTP 与 HTTPS
    两段 server。只改第一段的话，域名在另一段上不匹配任何 server_name，
    请求会落到 default_server 被 444 拒掉 ——
    表现为「界面提示添加成功，但 https 根本用不了」。
    os-repo.conf 就是这种两段结构。

    server_name 常写成多行续行，追加到**首行**即可（首行不以 ; 结尾时
    不能加分号，否则会截断后面的续行）。
    """
    if not os.path.exists(path):
        raise FileNotFoundError(f"找不到分流配置: {path}")

    with open(path, encoding="utf-8") as f:
        content = f.read()

    lines = content.splitlines()
    changed = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        # 只看【未注释】的 server_name，避免把域名加到注释里
        if stripped.startswith("#") or not stripped.startswith("server_name"):
            continue
        names = stripped.split(None, 1)[1].rstrip(";").split()
        if domain in names:
            continue                      # 这一段已经有了
        new_line = line.rstrip()
        if new_line.endswith(";"):
            new_line = new_line[:-1].rstrip() + f" {domain};"
        else:
            new_line = new_line + f" {domain}"
        lines[i] = new_line
        changed = True

    if not changed:
        return False
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return True


def _default_signer(domain, ca_dir):
    """调用项目既有的 ca/gen-cert.sh 签发证书。"""
    import subprocess
    script = os.path.join(ca_dir, "gen-cert.sh")
    if not os.path.exists(script):
        return False, f"缺少签发脚本: {script}"
    try:
        r = subprocess.run([script, domain], cwd=ca_dir, capture_output=True,
                           text=True, timeout=60)
    except subprocess.SubprocessError as e:
        return False, f"签发异常: {e}"
    if r.returncode != 0:
        return False, (r.stderr or r.stdout or "签发失败").strip()[:200]
    return True, "已签发"


def apply_upstream(domain, category, base_dir, signer=None):
    """执行三处改动。任何一步失败都回滚已改的配置文件。

    回滚是必须的：否则会留下「配置改了、证书没签」的半残状态，
    而这种状态在下一层会表现为 HTTPS 握手失败，且很难联想到是这里的问题。
    """
    ok, err = validate_domain(domain)
    if not ok:
        return {"ok": False, "msg": err}
    if category not in CATEGORIES:
        return {"ok": False, "msg": f"未知类型: {category}"}

    signer = signer or _default_signer
    p = _paths(base_dir)
    conf_path = os.path.join(p["conf_d"], CATEGORIES[category])
    ip = _target_ip(base_dir)

    # 备份待改文件
    backups = {}
    for path in (p["dnsmasq"], conf_path):
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                backups[path] = f.read()

    changed = []
    try:
        if _append_dnsmasq_rule(p["dnsmasq"], domain, ip):
            changed.append("dnsmasq")

        if _add_server_name(conf_path, domain):
            changed.append("tengine")

        signed, msg = signer(domain, p["ca"])
        if not signed:
            raise RuntimeError(msg)
        changed.append("cert")

    except Exception as e:
        for path, content in backups.items():
            try:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
            except OSError:
                pass
        return {"ok": False, "msg": f"失败，已回滚配置改动: {e}"}

    if not changed:
        return {"ok": True, "msg": f"{domain} 已存在，无需改动", "changed": [],
                "needs_restart": False}

    return {
        "ok": True,
        "msg": f"已添加 {domain}（{', '.join(changed)}）",
        "changed": changed,
        "needs_restart": True,
    }
