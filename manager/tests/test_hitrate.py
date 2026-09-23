"""命中率统计测试。

所有样例日志行都按 nginx.conf 里 `log_format main` 的真实格式书写 ——
格式不符正是旧 proxy-manager 的翻车点，故这里不做任何简化。
"""
import os
import tempfile

from backend.hitrate import parse_log_hitrate, all_hitrate

# 真实格式：... "curl/8.4.0" cache=HIT
LINE = '127.0.0.1 - [23/Sep/2026:05:09:28 +0000] "GET / HTTP/1.1" 200 696 "-" "curl/8.4.0" cache={}\n'


def _write(d, name, states):
    p = os.path.join(d, name)
    with open(p, "w") as f:
        for s in states:
            f.write(LINE.format(s))
    return p


def test_counts_hit_and_miss():
    with tempfile.TemporaryDirectory() as d:
        p = _write(d, "a.log", ["HIT", "HIT", "MISS"])
        r = parse_log_hitrate(p)
        assert r["hit"] == 2
        assert r["miss"] == 1
        assert r["rate"] == 66.7


def test_stale_and_updating_count_as_hit():
    """STALE / UPDATING 都由缓存提供了响应，必须算命中。

    若把它们排除，命中率会被系统性低估 ——
    而这两种状态恰恰出现在「缓存正被有效使用」的时刻。
    """
    with tempfile.TemporaryDirectory() as d:
        p = _write(d, "a.log", ["HIT", "STALE", "UPDATING", "MISS"])
        r = parse_log_hitrate(p)
        assert r["hit"] == 3, f"STALE/UPDATING 应计入命中，实际 hit={r['hit']}"
        assert r["miss"] == 1
        assert r["rate"] == 75.0


def test_empty_status_counts_as_uncached_not_miss():
    """`cache=` 为空表示该路径未启用 proxy_cache（如 registry/git），
    既不是命中也不是未命中 —— 计入 miss 会虚低命中率。"""
    with tempfile.TemporaryDirectory() as d:
        p = _write(d, "a.log", ["", "", "HIT"])
        r = parse_log_hitrate(p)
        assert r["uncached"] == 2
        assert r["hit"] == 1
        assert r["miss"] == 0
        assert r["rate"] == 100.0, "未启用缓存的请求不应拉低命中率"


def test_lines_without_marker_ignored():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "a.log")
        with open(p, "w") as f:
            f.write("这是没有 cache 标记的行\n")
            f.write(LINE.format("HIT"))
        r = parse_log_hitrate(p)
        assert r["hit"] == 1
        assert r["uncached"] == 0


def test_missing_file_returns_none_rate():
    r = parse_log_hitrate("/nonexistent-tproxy.log")
    assert r["rate"] is None
    assert r["total"] == 0


def test_all_hitrate_includes_backend_cached_types():
    """registry/git 的缓存由后端自管，tengine 侧无数据，需明确标注而非报 0%。"""
    with tempfile.TemporaryDirectory() as d:
        _write(d, "os-repo.log", ["HIT", "MISS"])
        _write(d, "os-repo-ssl.log", ["HIT"])
        _write(d, "python.log", ["HIT"])
        rows = all_hitrate(d)
        by_type = {r["type"]: r for r in rows}

        # os 跨两个日志文件汇总
        assert by_type["os"]["hit"] == 2
        assert by_type["os"]["rate"] == 66.7
        assert by_type["python"]["rate"] == 100.0
        assert by_type["registry"]["backend_cached"] is True
        assert by_type["registry"]["rate"] is None, "后端自缓存不应报 0%"
        assert by_type["git"]["backend_cached"] is True


def test_rate_is_none_when_no_judged_requests():
    with tempfile.TemporaryDirectory() as d:
        _write(d, "nodejs.log", ["", ""])
        rows = {r["type"]: r for r in all_hitrate(d)}
        assert rows["nodejs"]["rate"] is None
