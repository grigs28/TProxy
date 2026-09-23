"""Flask API 测试。

所有路径通过环境变量注入，使测试可在临时目录上运行，
不触碰真实配置与缓存。
"""
import os

import pytest

from app import create_app


@pytest.fixture
def client(monkeypatch, tmp_path):
    (tmp_path / "conf").mkdir()
    (tmp_path / "certs").mkdir()
    monkeypatch.setenv("TPROXY_CACHE_BASE", str(tmp_path))
    monkeypatch.setenv("TPROXY_CONF_D", str(tmp_path / "conf"))
    monkeypatch.setenv("TPROXY_DNSMASQ_CONF", str(tmp_path / "dnsmasq.conf"))
    monkeypatch.setenv("TPROXY_CERTS_DIR", str(tmp_path / "certs"))
    app = create_app()
    app.config["TESTING"] = True
    return app.test_client()


def test_status_ok(client):
    r = client.get("/api/status")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_cache_lists_six_types(client):
    r = client.get("/api/cache")
    assert r.status_code == 200
    types = [row["type"] for row in r.get_json()["types"]]
    assert len(types) == 6, f"应有六类，实际 {types}"


def test_rules_empty_when_no_config(client):
    """无配置时应返回空列表，而非 500 —— 界面据此显示「未解析到规则」。"""
    r = client.get("/api/rules")
    assert r.status_code == 200
    body = r.get_json()
    assert body["rules"] == []
    assert body["servers"] == []


def test_rules_parses_injected_config(client, tmp_path, monkeypatch):
    dnsmasq = tmp_path / "dnsmasq.conf"
    dnsmasq.write_text("address=/example.test/192.168.0.18\n")
    (tmp_path / "conf" / "x.conf").write_text(
        "server {\n  listen 443 ssl;\n  server_name a.test;\n  proxy_cache z_cache;\n}\n"
    )
    r = client.get("/api/rules")
    body = r.get_json()
    assert len(body["rules"]) == 1
    assert body["rules"][0]["domain"] == "example.test"
    assert len(body["servers"]) == 1


def test_certs_empty_without_cert_files(client):
    r = client.get("/api/certs")
    assert r.status_code == 200
    assert r.get_json()["certs"] == []
