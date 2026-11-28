"""最近调用流水测试。

样例日志行按 `nginx.conf` 里 `log_format main` 的真实格式书写，
并且**同时覆盖有 `rt=` 的新行与没有 `rt=` 的旧行** —— 改 log_format 之后，
日志尾部会在一段时间内新旧混排，解析必须两种都认，否则列表会看起来是空的。
"""
import os
import tempfile

from backend.recent import parse_line, recent_requests, tail_lines

# 新格式（2026-11-28 起）
NEW = ('192.168.0.116 - [28/Nov/2026:04:42:26 +0000] '
       '"GET /openEuler-24.03-LTS-SP4/update/x86_64/repodata/repomd.xml HTTP/2.0" '
       '200 3586 "-" "libdnf (openEuler 24.03)" cache=HIT rt=0.123\n')

# 旧格式（没有 rt=）
OLD = ('192.168.0.50 - [28/Nov/2026:04:42:25 +0000] '
       '"GET /ubuntu/dists/noble-updates/InRelease HTTP/1.1" '
       '200 126125 "-" "curl/8.7.1" cache=MISS\n')

# UA 里带引号转义序列（pip 的真实形态），验证不会被引号带偏
UA_TRICKY = ('192.168.0.70 - [28/Nov/2026:04:42:24 +0000] '
             '"GET /simple/pip/ HTTP/1.1" 200 152212 "-" '
             '"pip/24.0 {\\x22ci\\x22:null}" cache=STALE rt=0.0456\n')


def test_parse_new_format():
    r = parse_line(NEW, "os")
    assert r is not None
    assert r["client"] == "192.168.0.116"
    assert r["service"] == "os"
    assert r["method"] == "GET"
    assert r["path"] == "/openEuler-24.03-LTS-SP4/update/x86_64/repodata/repomd.xml"
    assert r["status"] == 200
    assert r["bytes"] == 3586
    assert r["cache"] == "HIT"
    assert r["rt"] == 0.123
    assert r["time"].startswith("2026-11-28T04:42:26")


def test_parse_old_format_without_rt():
    """旧行没有 rt=，仍要能显示出来（rt 为 None）—— 否则改格式后列表会突然空白。"""
    r = parse_line(OLD, "os")
    assert r is not None
    assert r["cache"] == "MISS"
    assert r["rt"] is None
    assert r["path"] == "/ubuntu/dists/noble-updates/InRelease"


def test_ua_with_escaped_quotes_does_not_break():
    """UA 里有 \\x22 这类转义时，不能把后面的字段解析错位。"""
    r = parse_line(UA_TRICKY, "python")
    assert r is not None
    assert r["cache"] == "STALE"
    assert r["rt"] == 0.0456
    assert r["path"] == "/simple/pip/"


def test_garbage_line_returns_none():
    assert parse_line("this is not a log line", "os") is None
    assert parse_line("", "os") is None


def test_tail_lines_reads_only_the_end():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "a.log")
        with open(p, "w") as f:
            for i in range(5000):
                f.write(f"line{i}\n")
        got = tail_lines(p, 3)
        assert got == ["line4997", "line4998", "line4999"]


def test_tail_lines_missing_file_returns_empty():
    assert tail_lines("/nonexistent/x.log", 5) == []


def test_recent_merges_services_and_sorts_desc():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "os-repo-ssl.log"), "w") as f:
            f.write(NEW)
        with open(os.path.join(d, "python.log"), "w") as f:
            f.write(UA_TRICKY)
        with open(os.path.join(d, "git.log"), "w") as f:
            f.write(OLD)

        rows = recent_requests(d, limit=10)
        assert len(rows) == 3
        # 时间倒序：04:42:26 > 04:42:25 > 04:42:24
        assert [r["service"] for r in rows] == ["os", "git", "python"]


def test_recent_respects_limit():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "git.log"), "w") as f:
            for i in range(50):
                f.write(OLD.replace("04:42:25", f"04:42:{i:02d}"))
        rows = recent_requests(d, limit=5)
        assert len(rows) == 5


def test_unknown_log_files_ignored():
    """目录里多出的日志（比如 manager.log）不应被当成请求流水。"""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "strange.log"), "w") as f:
            f.write(NEW)
        assert recent_requests(d) == []
