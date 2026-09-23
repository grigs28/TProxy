"""tengine 分流配置（conf.d/*.conf）的读写。

⚠️ 这是**能写 nginx 配置**的功能，写错会导致代理整体不可用。

**已知局限**：容器内没有 nginx 可执行文件，无法用 `nginx -t` 做真正的语法
校验。这里只做结构性检查（非空、花括号配对），**不能替代真实校验**。
改完务必按返回的提示重启并在界面确认各缓存仍正常。

（若日后要真正的校验，可把 nginx 二进制加进镜像，或把校验放到宿主机执行。）
"""
import os
import re

# 只允许 字母/数字开头 + 字母数字连字符下划线 + .conf
_CONF_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*\.conf$")


def validate_conf_name(name):
    """文件名校验。它会参与路径拼接，必须挡住穿越与分隔符。"""
    if not name or not str(name).strip():
        return False, "文件名不能为空"
    name = str(name)
    if "/" in name or "\\" in name:
        return False, "文件名不能含路径分隔符"
    if name.startswith("."):
        return False, "文件名不能以点开头"
    if not _CONF_NAME_RE.match(name):
        return False, "文件名只能包含字母、数字、连字符、下划线，且以 .conf 结尾"
    return True, ""


def _strip_noise(text):
    """去掉注释与引号内容 —— 其中的花括号不应参与配对统计。"""
    text = re.sub(r"#[^\n]*", "", text)
    text = re.sub(r'"[^"]*"', '""', text)
    text = re.sub(r"'[^']*'", "''", text)
    return text


def validate_conf_content(content):
    """结构性校验。返回 (ok, errmsg)。"""
    if content is None or not str(content).strip():
        return False, "内容不能为空"

    clean = _strip_noise(str(content))
    opens = clean.count("{")
    closes = clean.count("}")
    if opens != closes:
        return False, f"花括号不配对：{{ 有 {opens} 个，}} 有 {closes} 个"

    if opens == 0:
        return False, "内容里没有 server 块（缺少 { }）"

    return True, ""


def list_confs(confd_dir):
    """列出 conf.d 下的配置文件。"""
    rows = []
    if not os.path.isdir(confd_dir):
        return rows
    for name in sorted(os.listdir(confd_dir)):
        if not name.endswith(".conf"):
            continue
        path = os.path.join(confd_dir, name)
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        rows.append({"name": name, "size": size})
    return rows


def read_conf(confd_dir, name):
    """读一个配置文件；不存在或名字非法返回 None。"""
    ok, _ = validate_conf_name(name)
    if not ok:
        return None
    path = os.path.join(confd_dir, name)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def write_conf(confd_dir, name, content):
    """写入配置。校验失败时**不动原文件**。"""
    ok, err = validate_conf_name(name)
    if not ok:
        return False, err

    ok, err = validate_conf_content(content)
    if not ok:
        return False, err

    path = os.path.join(confd_dir, name)
    if not os.path.isfile(path):
        return False, f"文件不存在: {name}（新增请用「新建分流配置」）"

    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError as e:
        return False, f"写入失败: {e}"
    return True, "已保存"


_TEMPLATE = """# 由管理界面创建
# 改完需重启 tengine：docker compose restart tengine
server {{
    listen 443 ssl;
    http2 on;
    server_name example.com;

    ssl_certificate     /etc/nginx/certs/$ssl_server_name.crt;
    ssl_certificate_key /etc/nginx/certs/$ssl_server_name.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/{name}.log main;

    proxy_connect_timeout 30s;
    proxy_read_timeout 1800s;
    proxy_set_header Host $host;
    proxy_ssl_server_name on;
    proxy_redirect off;

    location / {{
        proxy_pass https://$host$request_uri;
    }}
}}
"""


def add_conf(confd_dir, name):
    """新建一个分流配置（带模板）。已存在则拒绝，避免误覆盖。"""
    ok, err = validate_conf_name(name)
    if not ok:
        return False, err

    path = os.path.join(confd_dir, name)
    if os.path.exists(path):
        return False, f"{name} 已存在（如需修改请用编辑）"

    content = _TEMPLATE.format(name=name[:-5])  # 去掉 .conf 做日志名
    ok, err = validate_conf_content(content)
    if not ok:  # 模板自身不合法说明代码有问题，宁可报错也不要写坏配置
        return False, f"内部错误：模板不合法（{err}）"

    try:
        os.makedirs(confd_dir, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError as e:
        return False, f"创建失败: {e}"
    return True, f"已创建 {name}"
