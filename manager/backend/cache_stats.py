"""缓存占用统计。

⚠️ 路径映射不是「六类都在 CACHE_BASE 下」——

`proxy/docker-compose.yml` 把 tengine 的缓存目录挂成
`${CACHE_BASE}/nginx:/var/cache/tproxy`，而 tengine 的四个
`proxy_cache_path` 是 `/var/cache/tproxy/{os,python,nodejs,java}`。
因此这四类的**真实路径是 `${CACHE_BASE}/nginx/<类型>`**；
只有 registry 与 git 各自独立在 CACHE_BASE 下。

早期版本按 `${CACHE_BASE}/<类型>` 统计，导致 os 缓存（当时已有 75MB 真实数据）
在界面上显示为「未启用」、python/nodejs/java 恒显示为空 ——
界面给出的答案与真实状态相反，正是本项目要消灭的那类事故。
"""
import os

# 各类缓存相对 CACHE_BASE 的真实路径
CACHE_PATHS = {
    "os":       "nginx/os",
    "python":   "nginx/python",
    "nodejs":   "nginx/nodejs",
    "java":     "nginx/java",
    "registry": "registry",
    "git":      "git",
}

CACHE_TYPES = list(CACHE_PATHS.keys())


def dir_usage(path):
    """返回目录的 {bytes, files}；目录不存在时返回零值而非抛错。"""
    total = 0
    files = 0
    if not os.path.isdir(path):
        return {"bytes": 0, "files": 0}

    for root, _dirs, names in os.walk(path):
        for n in names:
            p = os.path.join(root, n)
            try:
                total += os.path.getsize(p)
                files += 1
            except OSError:
                # 文件可能在遍历过程中被逐出（缓存淘汰/rename 完成）—— 跳过而非中断
                continue
    return {"bytes": total, "files": files}


def all_cache_usage(base):
    """列出六类缓存的占用。

    未创建的目录也返回（值为 0、enabled=False）—— 界面据此提示「未启用」，
    而不是静默不显示。

    注：目录大小含正在写入的文件（nginx 的 `use_temp_path=off` 让临时文件
    直接落在缓存目录内），故大文件回源期间数值会有瞬时抖动。这是已知且接受的：
    取大小不会读到「半截内容」，只是当时那一刻的数字偏小。
    """
    rows = []
    for t in CACHE_TYPES:
        path = os.path.join(base, CACHE_PATHS[t])
        u = dir_usage(path)
        rows.append({
            "type": t,
            "path": CACHE_PATHS[t],
            "bytes": u["bytes"],
            "files": u["files"],
            "enabled": os.path.isdir(path),
        })
    return rows
