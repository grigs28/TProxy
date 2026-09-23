"""tengine 分流配置（conf.d）的读写测试。

这个功能让界面能直接编辑 nginx 配置 —— 写错会导致**代理整体不可用**，
所以校验的重点在文件名（防路径穿越）与内容（防写坏）。

注意：容器内没有 nginx 可执行文件，无法用 `nginx -t` 做语法校验，
只能做结构性检查（非空、花括号配对）。这是已知的局限。
"""
import os

import pytest

from backend.confd import (
    add_conf,
    list_confs,
    read_conf,
    validate_conf_name,
    validate_conf_content,
    write_conf,
)


# ---------- 文件名校验 ----------

@pytest.mark.parametrize("name", ["registry.conf", "os-repo.conf", "my_upstream.conf"])
def test_valid_conf_names(name):
    ok, _ = validate_conf_name(name)
    assert ok


@pytest.mark.parametrize("name,why", [
    ("../etc/passwd", "路径穿越"),
    ("../../x.conf", "路径穿越"),
    ("sub/dir.conf", "含路径分隔符"),
    ("/etc/passwd", "绝对路径"),
    ("registry.txt", "非 .conf 后缀"),
    ("", "空"),
    (".hidden.conf", "以点开头"),
    ("a b.conf", "含空格"),
    ("a;b.conf", "含分号"),
    ("a\nb.conf", "含换行"),
])
def test_invalid_conf_names_rejected(name, why):
    """文件名会参与路径拼接，必须挡住穿越与分隔符。"""
    ok, _ = validate_conf_name(name)
    assert not ok, f"非法文件名被接受（{why}）: {name!r}"


# ---------- 内容校验 ----------

def test_content_must_not_be_empty():
    ok, msg = validate_conf_content("   \n\n")
    assert not ok
    assert "空" in msg


def test_content_braces_must_balance():
    """花括号不配对是最常见的写坏方式，nginx 会拒绝启动。"""
    ok, msg = validate_conf_content("server {\n  listen 80;\n")
    assert not ok
    assert "括号" in msg or "{" in msg


def test_content_with_brackets_inside_quotes_is_ok():
    """引号里的花括号不应参与配对统计。"""
    ok, _ = validate_conf_content(
        'server {\n  listen 80;\n  add_header X "{}";\n}\n'
    )
    assert ok


def test_valid_content_accepted():
    ok, _ = validate_conf_content("server {\n    listen 80;\n    server_name a.com;\n}\n")
    assert ok


# ---------- 读写 ----------

@pytest.fixture
def confd(tmp_path):
    d = tmp_path / "conf.d"
    d.mkdir()
    (d / "registry.conf").write_text("server {\n    listen 443;\n}\n")
    (d / "git.conf").write_text("server {\n    listen 443;\n}\n")
    return d


def test_list_confs(confd):
    rows = list_confs(str(confd))
    names = [r["name"] for r in rows]
    assert "registry.conf" in names
    assert "git.conf" in names
    assert len(rows) == 2


def test_read_conf(confd):
    c = read_conf(str(confd), "registry.conf")
    assert "listen 443" in c


def test_read_missing_conf_returns_none(confd):
    assert read_conf(str(confd), "nope.conf") is None


def test_write_conf_updates_existing(confd):
    ok, msg = write_conf(str(confd), "registry.conf", "server {\n    listen 80;\n}\n")
    assert ok, msg
    assert "listen 80" in (confd / "registry.conf").read_text()


def test_write_conf_rejects_bad_name(confd):
    ok, _ = write_conf(str(confd), "../evil.conf", "x")
    assert not ok


def test_write_conf_rejects_bad_content(confd):
    before = (confd / "registry.conf").read_text()
    ok, _ = write_conf(str(confd), "registry.conf", "server {")
    assert not ok
    assert (confd / "registry.conf").read_text() == before, "校验失败时不应改动文件"


def test_add_conf_creates_new(confd):
    ok, msg = add_conf(str(confd), "newrepo.conf")
    assert ok, msg
    assert (confd / "newrepo.conf").exists()


def test_add_conf_refuses_overwrite(confd):
    """已存在就拒绝 —— 避免误覆盖现有分流配置。"""
    ok, msg = add_conf(str(confd), "registry.conf")
    assert not ok
    assert "已存在" in msg


def test_add_conf_template_is_valid_nginx():
    """新建的模板本身必须能通过内容校验。"""
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "conf.d"))
        ok, msg = add_conf(os.path.join(d, "conf.d"), "t.conf")
        assert ok, msg
        content = open(os.path.join(d, "conf.d", "t.conf")).read()
        ok2, msg2 = validate_conf_content(content)
        assert ok2, f"模板自身不合法: {msg2}"
