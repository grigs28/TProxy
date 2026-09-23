"""管理端版本号。

与 `docs/stages/` 的阶段汇总编号保持一致 —— 那套编号记录的是
「每组功能落地到哪个程度」，用它做界面版本号，看到版本就知道
当前部署对应到哪一批改动。

可用环境变量 MANAGER_VERSION 覆盖（便于灰度或多实例对照）。
"""
import os

#: 当前版本。规则见 docs/stages/README.md（三位数逐位逢十进位）
VERSION = "0.2.7"


def get_version():
    return os.environ.get("MANAGER_VERSION", VERSION).strip() or VERSION
