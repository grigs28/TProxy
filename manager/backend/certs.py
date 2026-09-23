"""证书清单与到期检查。

用 `openssl x509 -enddate` 读取，而非引入 cryptography 依赖 ——
部署环境本就有 openssl（签发证书正是用它）。
"""
import datetime
import os
import re
import subprocess

_ENDDATE = re.compile(r"notAfter=(.+)")
# openssl 输出形如 "Mar  3 12:00:00 2027 GMT"（日期为空格填充，故用 %d 前导空格容忍）
_DATE_FMT = "%b %d %H:%M:%S %Y %Z"

# openssl 的 subject 形如 "CN=github.com"（1.1）或 "CN = github.com"（3.x）
_CN = re.compile(r"CN\s*=\s*([^,\n/]+)")
# SAN 扩展块：标题行之后直到下一个非缩进行，其中每行形如 "DNS:a.com, DNS:b.com"
_SAN_BLOCK = re.compile(
    r"X509v3 Subject Alternative Name:[^\n]*\n((?:[ \t]+[^\n]*\n?)+)")
_DNS = re.compile(r"DNS:([^,\s]+)")


def _parse_date(raw):
    if not raw:
        return None
    try:
        return datetime.datetime.strptime(raw.strip(), _DATE_FMT)
    except ValueError:
        # openssl 的日期格式随版本/locale 略有差异，解析失败则视为读不出
        return None


def cert_info(cert_path):
    """读一张证书的 CN、SAN 与有效期。读不出返回 None。

    一次 openssl 调用取全部字段：界面每 30 秒刷新一次而证书有 30+ 张，
    按字段分次调用会把进程创建开销成倍放大。

    注意不看返回码：证书没有 SAN 扩展时 `-ext subjectAltName` 会往 stderr
    抱怨并返回非零，但 stdout 里的 subject / 日期依然有效 —— 那种证书
    照样要能用（早期签的证书就没有 SAN）。
    """
    try:
        out = subprocess.run(
            ["openssl", "x509", "-in", cert_path, "-noout",
             "-subject", "-startdate", "-enddate", "-ext", "subjectAltName"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None

    out = out or ""
    m = _ENDDATE.search(out)
    na = _parse_date(m.group(1) if m else None)
    if na is None:
        return None

    m = re.search(r"notBefore=(.+)", out)
    nb = _parse_date(m.group(1) if m else None)

    m = _CN.search(out)
    cn = m.group(1).strip() if m else os.path.basename(cert_path)[:-4]

    m = _SAN_BLOCK.search(out)
    sans = _DNS.findall(m.group(1)) if m else []
    if not sans:
        # 没有 SAN 扩展时，CN 就是唯一被匹配的名字
        sans = [cn]

    # 用 timezone-aware 的当前时间再转 naive —— openssl 的 %Z 解析结果通常是
    # naive 的，两侧需保持同类型才能相减。utcnow() 已废弃。
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    return {
        "cn": cn,
        "sans": sans,
        "not_before": nb.strftime("%Y-%m-%d") if nb else "",
        "not_after": na.strftime("%Y-%m-%d"),
        "days_left": (na - now).days,
        "total_days": (na - nb).days if nb else None,
    }


def list_certs(certs_dir):
    """列出证书及其到期信息。

    损坏或无法解析的证书**跳过而非抛错** —— 一个坏文件不应让整个界面空白。
    """
    rows = []
    if not os.path.isdir(certs_dir):
        return rows

    for name in sorted(os.listdir(certs_dir)):
        if not name.endswith(".crt"):
            continue
        info = cert_info(os.path.join(certs_dir, name))
        if info is None:
            continue
        days = info["days_left"]
        rows.append({
            # 用文件名而非证书里的 CN：tengine 是按 $ssl_server_name 找文件的，
            # 文件名才是决定这张证书会不会被用上的那个键。
            "domain": name[:-4],
            "not_after": info["not_after"],
            "days_left": days,
            "expired": days < 0,
            "expiring_soon": 0 <= days <= 30,
            "sans": info["sans"],
            "total_days": info["total_days"],
        })
    return rows


def root_ca_info(ca_dir):
    """根 CA 的到期信息。读不到返回 None。

    单独拎出来是因为它的失效方式与域名证书**完全不同**：域名证书过期只
    影响一个域名，根 CA 到期会让所有域名同时失效，且每台客户端都必须
    重新安装。此前它压根不在界面上 —— 最要命的那张证书反而看不见。
    """
    info = cert_info(os.path.join(ca_dir, "tproxy-ca.crt"))
    if info is None:
        return None
    info["domain"] = "tproxy-ca"
    info["expired"] = info["days_left"] < 0
    info["expiring_soon"] = 0 <= info["days_left"] <= 180
    return info
