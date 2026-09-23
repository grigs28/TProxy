"""缓存命中率统计 —— 回答「缓存到底有没有在起作用」。

这是本项目最初的痛点：旧系统里 7 个 registry 崩溃了 1.7 万次、
缓存长期为零，却因为「看不见」而无人察觉。命中率是判断缓存是否
真正生效的直接证据。

⚠️ 解析必须对照 nginx.conf 的实际 `log_format main`：
      '$remote_addr - [$time_local] "$request" $status $body_bytes_sent '
      '"$http_referer" "$http_user_agent" cache=$upstream_cache_status'
   即行尾形如 `cache=HIT`。旧 proxy-manager 的 monitor 正是因正则与实际格式
   不符（它期望 `cache_status="HIT"`），匹配不到任何行、界面恒为空却不报错。
"""
import collections
import os
import re

# 各类缓存对应的 nginx 日志文件。
#
# registry 与 git 不在此列：它们在 tengine 中配的是 `proxy_cache off`，
# 缓存由 registry:2 / gitcache 各自管理，tengine 日志里没有命中标记
# （实测这些日志的 `cache=` 全为空）。
LOG_MAP = {
    "os":     ["os-repo.log", "os-repo-ssl.log"],
    "python": ["python.log"],
    "nodejs": ["nodejs.log"],
    "java":   ["java.log"],
}

# 由后端自缓存、tengine 层无命中率的类型
BACKEND_CACHED = ("registry", "git")

# 视为「命中」的状态。
#
# STALE 与 UPDATING 也算：它们都由缓存提供了响应 ——
# STALE 是返回过期副本同时后台刷新，UPDATING 是刷新进行中仍以副本应答。
# 只有真正回源取全量内容的才是不命中。
HIT_STATES = {"HIT", "STALE", "UPDATING", "REVALIDATED"}
MISS_STATES = {"MISS", "BYPASS", "EXPIRED"}

_STATUS_RE = re.compile(r"cache=([A-Za-z]*)")

# 从日志行里取 HTTP 状态码。
# 只认「引号后紧跟两个数字」这一处 —— 那是 `"$request" $status $body_bytes_sent`，
# 而日志里被引号包起来的只有 request / referer / user_agent 三个字段，
# 其中只有 request 后面跟数字。search 取第一个匹配，正好是状态码。
_STATUS_CODE_RE = re.compile(r'"\s+(\d{3})\s+\d+')

# 单次统计最多回看的行数 —— 日志可能很大，只关心近期表现
DEFAULT_TAIL = 20000


def _tail_lines(path, limit):
    """高效读取文件最后 limit 行（deque 固定长度，不会把整个文件读进内存）。"""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return collections.deque(f, maxlen=limit)


def parse_log_hitrate(path, tail=DEFAULT_TAIL):
    """统计单个日志文件的命中/未命中数。

    四类，互不重叠：

      hit      由缓存提供的响应（HIT / STALE / UPDATING / REVALIDATED）
      miss     真的回源取了内容回来
      failed   4xx / 5xx —— **不进命中率的分母**，但单独报出来
      uncached 未启用 proxy_cache 的请求（`cache=` 为空）

    `failed` 为什么要单列而不是直接丢掉：404 不代表「缓存没起作用」——
    那个东西本来就不存在，缓存无从提供，算作未命中就是让指标回答错的问题
    （实测 .19 上 openEuler 的 metalink 接口 404 每小时刷 168 次，
    把 system 类命中率从 ~61% 压到 31.7%）。但**只排除不显示**又会走到另一个
    极端：上游整体 404 这种真故障会被藏起来，指标一片大好而客户端全在报错 ——
    那正是本项目最要防的静默失效。所以：不进分母，但必须看得见。
    """
    result = {"hit": 0, "miss": 0, "failed": 0, "uncached": 0,
              "total": 0, "rate": None}
    if not os.path.isfile(path):
        return result

    try:
        lines = _tail_lines(path, tail)
    except OSError:
        return result

    for line in lines:
        m = _STATUS_RE.search(line)
        if not m:
            continue
        state = m.group(1).upper()
        if not state:
            # `cache=` 为空：该 location 未启用 proxy_cache
            result["uncached"] += 1
            continue

        cm = _STATUS_CODE_RE.search(line)
        if cm and int(cm.group(1)) >= 400:
            result["failed"] += 1
            continue

        if state in HIT_STATES:
            result["hit"] += 1
        elif state in MISS_STATES:
            result["miss"] += 1
        else:
            # 未知状态不猜测归属，计入 uncached 以免虚增命中率
            result["uncached"] += 1

    judged = result["hit"] + result["miss"]
    result["total"] = judged
    if judged:
        result["rate"] = round(result["hit"] * 100.0 / judged, 1)
    return result


def all_hitrate(log_dir):
    """汇总各类缓存的命中率。"""
    rows = []
    for t, files in LOG_MAP.items():
        agg = {"hit": 0, "miss": 0, "failed": 0, "uncached": 0,
               "total": 0, "rate": None}
        for name in files:
            r = parse_log_hitrate(os.path.join(log_dir, name))
            for k in ("hit", "miss", "failed", "uncached", "total"):
                agg[k] += r[k]
        judged = agg["hit"] + agg["miss"]
        agg["total"] = judged
        agg["rate"] = round(agg["hit"] * 100.0 / judged, 1) if judged else None
        agg["type"] = t
        rows.append(agg)

    for t in BACKEND_CACHED:
        rows.append({
            "type": t, "hit": 0, "miss": 0, "failed": 0, "uncached": 0,
            "total": 0, "rate": None, "backend_cached": True,
        })
    return rows
