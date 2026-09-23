"""让 tests/ 下的用例能 import backend.* 与 app。

pytest 默认只把 rootdir 加进 sys.path；本项目的模块位于 manager/ 下，
故显式加入其父目录。
"""
import os
import sys

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
