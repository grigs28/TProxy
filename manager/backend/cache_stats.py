"""缓存占用统计。

⚠️ 只统计【已完成】的文件：nginx 的临时文件以 .tmp/.temp 结尾且可能仍在写入，
计入会导致统计值抖动，甚至读到半截文件的大小。
"""
import os

CACHE_TYPES = ["os", "registry", "git", "python", "nodejs", "java"]

_SKIP_SUFFIX = (".tmp", ".temp")


def dir_usage(path):
    """返回目录的 {bytes, files}；目录不存在时返回零值而非抛错。"""
    total = 0
    files = 0
    if not os.path.isdir(path):
        return {"bytes": 0, "files": 0}

    for root, _dirs, names in os.walk(path):
        for n in names:
            if n.endswith(_SKIP_SUFFIX):
                continue
            p = os.path.join(root, n)
            try:
                total += os.path.getsize(p)
                files += 1
            except OSError:
                # 文件可能在遍历过程中被 nginx 删除 —— 跳过而非中断整次统计
                continue
    return {"bytes": total, "files": files}


def all_cache_usage(base):
    """列出六类缓存的占用。

    未创建的目录也返回（值为 0，enabled=False）—— 界面需要据此提示「该类未启用」，
    而不是静默不显示。
    """
    rows = []
    for t in CACHE_TYPES:
        path = os.path.join(base, t)
        u = dir_usage(path)
        rows.append({
            "type": t,
            "bytes": u["bytes"],
            "files": u["files"],
            "enabled": os.path.isdir(path),
        })
    return rows
