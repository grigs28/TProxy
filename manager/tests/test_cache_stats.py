"""缓存占用统计测试。"""
import os
import tempfile

from backend.cache_stats import dir_usage, all_cache_usage


def test_dir_usage_sums_file_sizes():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "a"), "wb") as f:
            f.write(b"x" * 100)
        os.makedirs(os.path.join(d, "sub"))
        with open(os.path.join(d, "sub", "b"), "wb") as f:
            f.write(b"y" * 50)
        r = dir_usage(d)
        assert r["bytes"] == 150
        assert r["files"] == 2


def test_dir_usage_missing_dir_returns_zero():
    r = dir_usage("/nonexistent-path-tproxy-test")
    assert r["bytes"] == 0 and r["files"] == 0


def test_dir_usage_skips_in_progress_temp_files():
    """nginx 的临时文件以 .tmp 结尾且可能仍在写入。

    计入会导致统计抖动，甚至读到半截文件的大小 —— 必须跳过。
    """
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "done"), "wb") as f:
            f.write(b"x" * 10)
        with open(os.path.join(d, "writing.tmp"), "wb") as f:
            f.write(b"y" * 999)
        r = dir_usage(d)
        assert r["bytes"] == 10, "临时文件不应计入"
        assert r["files"] == 1


def test_all_cache_usage_lists_six_types_including_disabled():
    """未创建的目录也要出现（值为 0）—— 否则界面无法提示「该类未启用」。"""
    with tempfile.TemporaryDirectory() as base:
        for t in ("os", "registry", "git"):
            os.makedirs(os.path.join(base, t))
        rows = all_cache_usage(base)
        types = [r["type"] for r in rows]
        assert len(rows) == 6
        for t in ("os", "registry", "git", "python", "nodejs", "java"):
            assert t in types
        by_type = {r["type"]: r for r in rows}
        assert by_type["os"]["enabled"] is True
        assert by_type["python"]["enabled"] is False
        assert by_type["python"]["bytes"] == 0
