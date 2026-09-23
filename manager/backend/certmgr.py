"""签发与重新签发域名证书。

为什么值得做成功能：证书是「加了域名却忘了签」这条静默失效链的第二环 ——
漏签在服务端不报任何错，只在客户端表现为 TLS 握手失败，而现场线索全无。

四条要紧的约束：

1. **通配符域名直接拒绝**。tengine 用
   `ssl_certificate /etc/nginx/certs/$ssl_server_name.crt` 按 SNI 取文件，
   而 SNI 永远是具体主机名，不可能等于 `*.example.com` ——
   放行只会得到一张「签了但永远不会被选中」的证书。

2. **重新签发必须原子**。覆盖的是正在使用的 .crt/.key，而失败会同时毁掉两者：
   `openssl genrsa -out` 立刻截断旧私钥，`openssl x509 -req -out` 则在报错
   **之前**就把旧证书清成 0 字节（实测，见 test_resign_failure_keeps_old_cert_usable）。
   留下两个空文件 = 该域名 HTTPS 彻底失效。原子性由 gen-cert.sh 保证
   （先在工作目录签好再 mv 落位），本模块只负责调用与校验。

3. **有效期不得超过根 CA 剩余期**。超过了不会报错，只是从根 CA 过期那刻起
   整条链就不再被信任，而界面还在显示「还有 2000 天」——
   一个 UI 专门用来回答的问题被答错。

4. **签了的域名要登记进 domains.txt**。它是根 CA 重建时的重签清单，
   不登记则该域名在重建后凭空消失。
"""
import os
import re
import subprocess

from backend.certs import cert_info
from backend.upstream import validate_domain

#: 叶子证书默认有效期。根长叶短 —— 根 CA 30 年（见 rootca.DEFAULT_ROOT_DAYS），
#: 叶子 10 年。叶子到期重签一次即可（客户端无感），
#: 根 CA 换一次要动每一台客户端，故此生只换一次。
DEFAULT_DAYS = 3650
MAX_DAYS = 36500

_SAN_SPLIT = re.compile(r"[\s,;]+")


def parse_sans(raw):
    """把附加域名解析成去重后的列表。

    逗号、空格、分号、换行都当分隔符 —— 用户从别处粘贴列表时格式不可控。
    **列表入参同样接受**：换根时 SAN 是从原证书读回来的，手上本就是列表；
    只认字符串会把 `['a.com']` 连同方括号引号一起当成域名，直接校验失败。

    拆分是安全的：每一段随后都要过 validate_domain，
    能通过校验的字符串里不可能再含换行或 shell 元字符。
    """
    if not raw:
        return []
    if isinstance(raw, (list, tuple, set, frozenset)):
        chunks = []
        for item in raw:
            chunks.extend(_SAN_SPLIT.split(str(item)))
    else:
        chunks = _SAN_SPLIT.split(str(raw).strip())

    out, seen = [], set()
    for part in chunks:
        part = part.strip()
        if not part or part in seen:
            continue
        seen.add(part)
        out.append(part)
    return out


def parse_days(days):
    """严格取整数天数。

    `'3650'` 与 `3650` 都接受；`'1.5'`/`1.5`/`True` 一律拒绝 ——
    静默把用户填的有效期截断成整数，比报错更糟。
    """
    if isinstance(days, bool):       # bool 是 int 的子类，True 会悄悄变成 1
        return None
    if isinstance(days, int):
        return days
    s = str(days).strip()
    if not s.isdigit():
        return None
    return int(s)


def validate_cert_request(cn, sans, days):
    """校验签发参数。返回 (ok, err, cleaned)。

    域名复用 upstream.validate_domain —— 同一套规则一份实现，
    免得两处校验严宽不一，从松的那处被绕进去。
    """
    ok, err = validate_domain(cn)
    if not ok:
        return False, err, None
    if str(cn).startswith("*."):
        return False, _WILDCARD_MSG, None

    n = parse_days(days)
    if n is None:
        return False, "有效期必须是整数天数", None
    if not 1 <= n <= MAX_DAYS:
        return False, f"有效期需在 1 - {MAX_DAYS} 天之间", None

    clean = []
    for s in parse_sans(sans):
        if s == cn:
            continue                 # 与 CN 重复的 SAN 会让证书里出现重复条目
        ok, err = validate_domain(s)
        if not ok:
            return False, f"附加域名 {s}：{err}", None
        if s.startswith("*."):
            return False, f"附加域名 {s}：{_WILDCARD_MSG}", None
        clean.append(s)

    if len(clean) + 1 > 100:
        return False, "域名过多（含主域名最多 100 个）", None

    return True, "", {"cn": str(cn), "sans": clean, "days": n}


_WILDCARD_MSG = "不支持通配符域名（tengine 按 SNI 逐域名取证书文件，通配证书不会被选中）"


def _effective_days(days, ca_dir):
    """按根 CA 剩余期裁剪有效期。返回 (天数, 说明或空串)。"""
    info = cert_info(os.path.join(ca_dir, "tproxy-ca.crt"))
    if info is None:
        return days, ""
    left = info["days_left"]
    # 容 1 天：days_left 是向下取整的，刚签好的根 CA 会报 3649 而非 3650。
    # 不容这 1 天，「按默认值 3650 天签发」这条最常见路径会次次弹出裁剪警告，
    # 而真正的告警就在这种噪音里被忽略。多出的不足一天由根 CA 的到期日兜住。
    if left <= 0 or days <= left + 1:
        return days, ""
    eff = max(1, left)
    return eff, (f"有效期已按根 CA 剩余期裁剪为 {eff} 天 —— 根 CA 只剩 {left} 天，"
                 f"签比它更长的有效期没有意义：根 CA 一过期整条链就不被信任了")


def _in_domains_txt(ca_dir, domain):
    path = os.path.join(ca_dir, "domains.txt")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s and not s.startswith("#") and domain in s.split():
                    return True
    except OSError:
        return False
    return False


def _append_domains_txt(ca_dir, cn, sans):
    """登记到 domains.txt，供根 CA 重建时重签。已登记则不动。

    一行可含多个域名，首个是 CN、其余是 SAN —— 与 deploy.sh 的读取方式一致。
    """
    if _in_domains_txt(ca_dir, cn):
        return False
    path = os.path.join(ca_dir, "domains.txt")
    try:
        content = ""
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                content = f.read()
        if content and not content.endswith("\n"):
            content += "\n"
        with open(path, "w", encoding="utf-8") as f:
            f.write(content + " ".join([cn] + list(sans)) + "\n")
    except OSError:
        return False
    return True


def _run_gen_cert(script, cn, sans, days, ca_dir):
    """调用 gen-cert.sh。有效期经环境变量 DAYS 传入（脚本内缺省 3650）。"""
    env = dict(os.environ)
    env["DAYS"] = str(days)
    r = subprocess.run([script, cn] + list(sans), cwd=ca_dir, env=env,
                       capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout, r.stderr


def preview_sign(cn, sans, days, ca_dir):
    """返回将要做的改动供人确认。只读，不碰任何文件。"""
    ok, err, clean = validate_cert_request(cn, sans, days)
    if not ok:
        return {"ok": False, "msg": err}

    exists = os.path.exists(
        os.path.join(ca_dir, "certs", f"{clean['cn']}.crt"))
    eff, clamp_note = _effective_days(clean["days"], ca_dir)
    names = [clean["cn"]] + clean["sans"]

    changes = [{
        "file": f"ca/certs/{clean['cn']}.crt",
        "action": "重新签发（覆盖）" if exists else "签发",
        "diff": f"{clean['cn']}  ←  SAN: {', '.join(names)}  ·  {eff} 天",
        "desc": ("该域名已有证书，签发成功后旧证书被替换。"
                 if exists else "该域名当前没有证书。")
                + "客户端只信任根 CA，故无需向任何客户端重新分发。",
    }]

    if not _in_domains_txt(ca_dir, clean["cn"]):
        changes.append({
            "file": "ca/domains.txt",
            "action": "登记域名",
            "diff": "+ " + " ".join(names),
            "desc": "根 CA 重建时按此文件重签；不登记则该域名重建后会没有证书",
        })

    notes = ["证书由 tengine 按 SNI 变量路径逐次读取，通常立即生效；"
             "若客户端仍报证书错误，执行："
             "cd /opt/TProxy/proxy && docker compose restart tengine"]
    if clamp_note:
        notes.append(clamp_note)

    return {
        "ok": True,
        "msg": "",
        "domain": clean["cn"],
        "days": eff,
        "needs_restart": False,
        "changes": changes,
        "note": "　".join(notes),
    }


def sign_cert(cn, sans, days, ca_dir, runner=None):
    """签发（或重新签发）证书。返回 {ok, msg, ...}。

    签发失败时原证书必须原封不动 —— 这一点由 gen-cert.sh 的原子替换保证，
    本函数只负责「不谎报成功」：脚本报成功但文件不存在同样算失败。
    """
    ok, err, clean = validate_cert_request(cn, sans, days)
    if not ok:
        return {"ok": False, "msg": err}

    eff, clamp_note = _effective_days(clean["days"], ca_dir)
    cert_path = os.path.join(ca_dir, "certs", f"{clean['cn']}.crt")
    existed = os.path.exists(cert_path)

    script = os.path.join(ca_dir, "gen-cert.sh")
    if runner is None:
        if not os.path.exists(script):
            return {"ok": False, "msg": f"缺少签发脚本：{script}"}
        runner = _run_gen_cert

    try:
        rc, out, errout = runner(script, clean["cn"], clean["sans"], eff, ca_dir)
    except Exception as e:                      # noqa: BLE001 —— 统一转为可展示的失败
        return {"ok": False, "msg": f"签发异常：{e}"}

    if rc != 0:
        return {"ok": False,
                "msg": "签发失败，原证书未改动："
                       + (errout or out or "").strip()[:200]}

    if not os.path.exists(cert_path):
        return {"ok": False, "msg": "签发脚本报成功，但证书文件不存在"}

    _append_domains_txt(ca_dir, clean["cn"], clean["sans"])

    msg = (f"已{'重新签发' if existed else '签发'} {clean['cn']}"
           f"（有效期 {eff} 天")
    if clean["sans"]:
        msg += f"，含 {len(clean['sans'])} 个附加域名"
    msg += "）"

    notes = [clamp_note] if clamp_note else []
    if not _in_domains_txt(ca_dir, clean["cn"]):
        notes.append("未能登记到 ca/domains.txt，根 CA 重建后该证书不会被重签")

    return {
        "ok": True,
        "msg": msg + ("。" + "；".join(notes) if notes else ""),
        "domain": clean["cn"],
        "days": eff,
        "changed": ["cert"],
        "needs_restart": False,
    }
