"""最近调用流水 —— 回答「刚刚谁在用什么」。

与 `hitrate` 的分工：

  · `hitrate.py` 是**聚合**：过去一段时间整体命中率好不好
  · 本模块是**流水**：刚刚发生的那几条请求，谁、要什么、快不快、命中没

⚠️ 一个必须说清的事实：**tengine 的 access log 是在请求完成时写的**，
   所以这里展示的是「最近完成」，不是「正在传输」。
   界面文案也照此写（「最近调用」而不是「正在下载」）——
   想看真正的在途需要 njs 记录请求开始，属于后续阶段。

数据来源：`nginx.conf` 的 `log_format main`：

    '$remote_addr - [$time_local] "$request" '
    '$status $body_bytes_sent "$http_referer" '
    '"$http_user_agent" cache=$upstream_cache_status rt=$request_time'

`rt=` 是 2026-11-28 新加的。**解析必须兼容没有 rt 的旧行** ——
否则改完 log_format 的头几分钟（旧行还在尾部）整个列表会是空的，
看起来像"功能坏了"。
"""

import os
import re
from datetime import datetime

# 日志文件 → 服务名（界面上的「服务」列）
LOG_SERVICE = {
    "os-repo.log": "os",
    "os-repo-ssl.log": "os",
    "python.log": "python",
    "nodejs.log": "nodejs",
    "java.log": "java",
    "git.log": "git",
    "registry.log": "registry",
}

DEFAULT_LIMIT = 30

# 只解析到 bytes 为止；后面还有 referer / UA / cache / rt。
# UA 里可能出现 `"`，所以**不能**用一个从头到尾的大正则 —— 见 parse_line。
_HEAD_RE = re.compile(
    r'^(?P<client>\S+)\s+-\s+\[(?P<time>[^\]]+)\]\s+'
    r'"(?P<request>[^"]*)"\s+(?P<status>\d{3})\s+(?P<bytes>\d+)'
)

_TIME_FMT = "%d/%b/%Y:%H:%M:%S %z"


def tail_lines(path, n, chunk=65536):
    """从文件尾部读最后 n 行 —— **不读整个文件**。

    ⚠️ 不能照搬 `hitrate._tail_lines` 的 `deque(f, maxlen=n)`：
       那是把整个文件读一遍再做裁剪。git.log 已 14MB，
       而本接口是几秒一轮询 —— 全读会造成明显的 I/O。
       这里 seek 到末尾、倒着按块读，读够 n 行就停。

    返回的字符串已解码（非法字节替换，不抛异常）。
    """
    if n <= 0:
        return []
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            pos = f.tell()
            data = b""
            # 多读一行，保证第一行是完整的（可能从半行开始）
            while pos > 0 and data.count(b"\n") <= n:
                step = min(chunk, pos)
                pos -= step
                f.seek(pos)
                data = f.read(step) + data
            lines = data.split(b"\n")
            if pos > 0:
                lines = lines[1:]          # 丢掉可能被截断的首行
            if lines and lines[-1] == b"":
                lines.pop()
            return [x.decode("utf-8", "replace") for x in lines[-n:]]
    except OSError:
        return []


def parse_line(line, service):
    """把一行 access log 解析成字典；不认识的行返回 None（跳过而不报错）。

    从右往左剥 `rt=` 与 `cache=`：UA 里可能含引号，从左侧正向匹配到 UA
    就会错位；这两个字段固定在行尾，从右切分更稳。
    """
    line = line.rstrip("\r\n")
    if not line:
        return None

    head, sep, rt = line.rpartition(" rt=")
    if not sep:
        head, rt = line, ""            # 兼容没有 rt 的旧行
    head, sep2, cache = head.rpartition(" cache=")
    if not sep2:
        head, cache = head, ""

    m = _HEAD_RE.match(head)
    if not m:
        return None

    request = m.group("request")
    method, _, rest = request.partition(" ")
    path = rest.rsplit(" ", 1)[0] if " " in rest else rest

    try:
        ts = datetime.strptime(m.group("time"), _TIME_FMT).isoformat()
    except ValueError:
        ts = m.group("time")           # 解析不了就原样给出，不丢这一行

    try:
        rt_v = float(rt.strip()) if rt.strip() else None
    except ValueError:
        rt_v = None

    try:
        status = int(m.group("status"))
        size = int(m.group("bytes"))
    except ValueError:
        return None

    return {
        "time": ts,
        "client": m.group("client"),
        "service": service,
        "method": method,
        "path": path,
        "status": status,
        "bytes": size,
        "cache": cache.strip(),
        "rt": rt_v,
    }


def recent_requests(log_dir, limit=DEFAULT_LIMIT):
    """最近完成的请求，按时间倒序。

    每个日志取最后 `limit` 行再合并排序 —— 单个服务再忙也挤不掉其他服务。
    """
    rows = []
    for name, service in LOG_SERVICE.items():
        path = os.path.join(log_dir, name)
        if not os.path.isfile(path):
            continue
        for line in tail_lines(path, limit):
            r = parse_line(line, service)
            if r:
                rows.append(r)

    # ISO 时间字符串（带 +00:00）可直接按字典序排
    rows.sort(key=lambda r: r["time"], reverse=True)
    return rows[:limit]
