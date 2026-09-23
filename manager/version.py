"""管理端版本号与静态资源指纹。

两个东西，用途不同，别混：

* `VERSION` —— **阶段版本**，人工维护，与 `docs/stages/` 的阶段汇总编号一致。
  看到它就直到当前部署对应到哪一批改动。

* `asset_version()` —— **静态资源指纹**，由 index.html 与 app.js 的内容算出。
  用途是让浏览器缓存失效。它必须是自动的：靠人记得改版本号这条路已经断过一次
  —— 改了 app.js 却忘了改 index.html 里的 `?v=`，结果是浏览器一直跑旧脚本，
  而现象是「新功能没生效」，排查时几乎不会想到缓存。
"""
import hashlib
import os

#: 当前阶段版本。规则见 docs/stages/README.md（三位数逐位逢十进位）
VERSION = "0.2.8"

_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

#: 参与指纹的静态文件。新增静态资源要加进来，否则它不会失效。
_ASSETS = ("index.html", "app.js")


def get_version():
    return os.environ.get("MANAGER_VERSION", VERSION).strip() or VERSION


def asset_version(static_dir=None):
    """静态资源指纹：内容一变，指纹就变。取 8 位十六进制。

    缺文件也照样算得出指纹（把「文件缺失」本身算进去），
    不能让一个缺失的静态文件把整个界面变成 500。
    """
    d = static_dir or _STATIC_DIR
    h = hashlib.sha256()
    for name in _ASSETS:
        try:
            with open(os.path.join(d, name), "rb") as f:
                h.update(f.read())
        except OSError:
            h.update(b"missing:" + name.encode())
        # 分隔符：否则 ("ab","c") 与 ("a","bc") 会算出同一个指纹
        h.update(b"\x00")
    return h.hexdigest()[:8]
