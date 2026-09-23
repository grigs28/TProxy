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


def test_dir_usage_counts_plain_files_without_extension():
    """不按扩展名过滤。

    早期版本会跳过 .tmp/.temp，但那是基于一个错误假设 ——
    nginx 的缓存文件名是无扩展名的 MD5 散列，且本项目的四个
    proxy_cache_path 都设了 use_temp_path=off，写入中的文件直接落在
    缓存目录内、以纯数字命名。按后缀过滤既拦不住真实情况，
    又给人「已处理」的错觉。
    现在的取舍是：如实统计全部文件，接受大文件回源期间的数值抖动
    （取大小不会读到半截内容，只是瞬时偏小）。
    """
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "a1b2c3"), "wb") as f:
            f.write(b"x" * 10)
        with open(os.path.join(d, "0000000042"), "wb") as f:
            f.write(b"y" * 5)
        r = dir_usage(d)
        assert r["bytes"] == 15
        assert r["files"] == 2


def test_all_cache_usage_lists_six_types_including_disabled():
    """未创建的目录也要出现（值为 0）—— 否则界面无法提示「该类未启用」。"""
    with tempfile.TemporaryDirectory() as base:
        os.makedirs(os.path.join(base, "registry"))
        os.makedirs(os.path.join(base, "git"))
        rows = all_cache_usage(base)
        types = [r["type"] for r in rows]
        assert len(rows) == 6
        for t in ("os", "registry", "git", "python", "nodejs", "java"):
            assert t in types
        by_type = {r["type"]: r for r in rows}
        assert by_type["registry"]["enabled"] is True
        assert by_type["os"]["enabled"] is False
        assert by_type["python"]["enabled"] is False


def test_uses_real_path_mapping_not_flat_layout():
    """tengine 的四类缓存在 ${CACHE_BASE}/nginx/ 之下，不是 CACHE_BASE 根下。

    这是真实部署的布局（compose 把 ${CACHE_BASE}/nginx 挂成 /var/cache/tproxy）。
    早期版本按扁平布局统计，导致已有 75MB 真实数据的 os 缓存被界面报成「未启用」，
    python/nodejs/java 恒显示为空 —— 界面给出的答案与真实状态相反。
    """
    with tempfile.TemporaryDirectory() as base:
        for t in ("os", "python", "nodejs", "java"):
            d = os.path.join(base, "nginx", t)
            os.makedirs(d)
            with open(os.path.join(d, "blob"), "wb") as f:
                f.write(b"x" * 100)
        os.makedirs(os.path.join(base, "registry"))
        os.makedirs(os.path.join(base, "git"))

        by_type = {r["type"]: r for r in all_cache_usage(base)}

        for t in ("os", "python", "nodejs", "java"):
            assert by_type[t]["enabled"] is True, f"{t} 应被识别为已启用"
            assert by_type[t]["bytes"] == 100, f"{t} 应统计到 nginx/{t} 下的数据"
        assert by_type["os"]["path"] == "nginx/os"


def test_flat_layout_leftovers_do_not_register_as_enabled():
    """顶层遗留的空目录不应让界面误报「已启用」——真实数据不在这里。"""
    with tempfile.TemporaryDirectory() as base:
        for t in ("python", "nodejs", "java"):
            os.makedirs(os.path.join(base, t))
        by_type = {r["type"]: r for r in all_cache_usage(base)}
        for t in ("python", "nodejs", "java"):
            assert by_type[t]["enabled"] is False, f"顶层空目录 {t} 不应算作已启用"
