"""管理端版本号与静态资源指纹。

三个东西，用途不同，别混：

* **版本号** —— 唯一来源是仓库根的 `CHANGELOG.md`，取其中第一条 `## [x.y.z]`。
  本模块不自己存一份：两份各自维护的版本号必然会分叉，
  而「界面显示的版本和实际部署的不是一回事」是最难查的那类问题。
  规则见 `docs/stages/README.md`（三位十进制、逐位逢十进位）。

* `asset_version()` —— **静态资源指纹**，由 index.html 与 app.js 的内容算出。
  用途是让浏览器缓存失效。它必须是自动的：靠人记得改版本号这条路已经断过一次
  —— 改了 app.js 却忘了改 index.html 里的 `?v=`，结果是浏览器一直跑旧脚本，
  而现象是「新功能没生效」，排查时几乎不会想到缓存。

* `read_changelog()` —— 整份更新日志，供界面点版本号时展示。
"""
import hashlib
import os
import re

#: 容器内 CHANGELOG.md 的挂载点（见 proxy/docker-compose.yml 的 manager.volumes）。
#: 本机直接跑时同一路径也存在（仓库根），故不需要额外配置。
DEFAULT_CHANGELOG = "/opt/TProxy/CHANGELOG.md"

#: 读不出 CHANGELOG 时的回退值。刻意用全 0 —— 界面上一眼能看出不对劲，
#: 而不是悄悄显示一个看起来正常的版本号。
VERSION_FALLBACK = "0.0.0"

_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

#: 参与指纹的静态文件。新增静态资源要加进来，否则它不会失效。
_ASSETS = ("index.html", "app.js")

#: 版本条目标题，形如 `## [0.2.8] - 2026-09-23`
_VERSION_HEADING = re.compile(r"^##\s+\[(\d+\.\d+\.\d+)\]", re.M)


def changelog_path():
    return os.environ.get("TPROXY_CHANGELOG", "").strip() or DEFAULT_CHANGELOG


def read_changelog(path=None):
    """读整份更新日志。读不到返回空串 —— 界面顶栏也靠这个文件，
    不能因为一个缺文件就把整页变成 500。"""
    try:
        with open(path or changelog_path(), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def version_from_changelog(path=None):
    """取当前版本：文件里第一条 `## [x.y.z]`。

    更新日志按新到旧排列，故第一条就是当前版本。解析不出返回 None，
    由调用方决定回退 —— 不能瞎猜一个版本号出来。
    """
    m = _VERSION_HEADING.search(read_changelog(path))
    return m.group(1) if m else None


def get_version():
    """当前版本号。

    优先级：环境变量（便于灰度或多实例对照）→ CHANGELOG.md → 回退值。
    """
    env = os.environ.get("MANAGER_VERSION", "").strip()
    return env or version_from_changelog() or VERSION_FALLBACK


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
