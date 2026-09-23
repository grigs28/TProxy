"""配置解析测试。

解析器的正确性直接决定界面显示是否可信 —— 旧 proxy-manager 的 monitor
正是因正则与实际格式不符，界面恒显示空却不报错（静默假正常）。
故这里对「只提取该提取的、忽略注释、不混入其他指令」逐条断言。
"""
import os
import tempfile

from backend.config_read import parse_dnsmasq_rules, parse_nginx_servers

DNSMASQ_SAMPLE = """
listen-address=0.0.0.0
port=53
server=223.5.5.5
address=/repo.openeuler.org/192.168.0.18
address=/github.com/192.168.0.18
host-record=nt08.sxsy,192.168.0.38,192.168.0.48
# address=/commented-out.example/192.168.0.18
"""


def test_parse_dnsmasq_only_address_lines():
    """只应解析 address= 行：server= 是上游 DNS，host-record= 是内网域名，
    注释掉的行也不该混进来。"""
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
        f.write(DNSMASQ_SAMPLE)
        path = f.name
    try:
        rules = parse_dnsmasq_rules(path)
        domains = [r["domain"] for r in rules]
        assert "repo.openeuler.org" in domains
        assert "github.com" in domains
        assert len(rules) == 2, f"应只有 2 条劫持规则，实际 {len(rules)}: {domains}"
        assert all(r["target"] == "192.168.0.18" for r in rules)
    finally:
        os.unlink(path)


def test_parse_dnsmasq_missing_file_returns_empty():
    assert parse_dnsmasq_rules("/nonexistent-tproxy-test.conf") == []


NGINX_SAMPLE = """
# 这是注释里的 server_name 不应被解析
server {
    listen 443 ssl;
    server_name pypi.org files.pythonhosted.org;
    proxy_cache py_cache;
    proxy_pass https://$host$request_uri;
}
"""


def test_parse_nginx_extracts_names_and_cache_zone():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "python.conf"), "w") as f:
            f.write(NGINX_SAMPLE)
        servers = parse_nginx_servers(d)
        assert len(servers) == 1
        s = servers[0]
        assert s["file"] == "python.conf"
        assert "pypi.org" in s["server_name"]
        assert "files.pythonhosted.org" in s["server_name"]
        assert "443" in s["listen"]
        assert s["cache_zone"] == "py_cache"


def test_parse_nginx_ignores_commented_lines():
    """注释里的指令不得被解析 —— 否则界面会显示不存在的配置。"""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "x.conf"), "w") as f:
            f.write("# server_name ghost.example;\n")
        assert parse_nginx_servers(d) == []


def test_parse_nginx_missing_dir_returns_empty():
    assert parse_nginx_servers("/nonexistent-tproxy-dir") == []
