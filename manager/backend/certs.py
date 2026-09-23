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


def _not_after(cert_path):
    try:
        out = subprocess.run(
            ["openssl", "x509", "-in", cert_path, "-noout", "-enddate"],
            check=True, capture_output=True, text=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None

    m = _ENDDATE.search(out)
    if not m:
        return None
    raw = m.group(1).strip()
    try:
        return datetime.datetime.strptime(raw, _DATE_FMT)
    except ValueError:
        # openssl 的日期格式随版本/locale 略有差异，解析失败则跳过该证书
        return None


def list_certs(certs_dir):
    """列出证书及其到期信息。

    损坏或无法解析的证书**跳过而非抛错** —— 一个坏文件不应让整个界面空白。
    """
    rows = []
    if not os.path.isdir(certs_dir):
        return rows

    # 用 timezone-aware 的当前时间再转 naive —— openssl 的 %Z 解析结果通常是
    # naive 的，两侧需保持同类型才能相减。utcnow() 已废弃。
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    for name in sorted(os.listdir(certs_dir)):
        if not name.endswith(".crt"):
            continue
        na = _not_after(os.path.join(certs_dir, name))
        if na is None:
            continue
        days = (na - now).days
        rows.append({
            "domain": name[:-4],
            "not_after": na.strftime("%Y-%m-%d"),
            "days_left": days,
            "expired": days < 0,
            "expiring_soon": 0 <= days <= 30,
        })
    return rows
