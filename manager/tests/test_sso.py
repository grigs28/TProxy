"""管理端 SSO 认证测试。

管理端接入 yz-login 统一登录，且**只允许管理员进入** ——
`is_admin` 必须严格等于 1，其余一律拒绝。

这些测试对应三条不可退让的规则：
  1. 未登录不得看到任何数据（包括 API）
  2. 登录成功但非管理员，仍然不得进入
  3. 只有 is_admin==1 才放行
"""
import json

import pytest

from app import create_app

YZ = "http://192.168.0.8"


class FakeResp:
    def __init__(self, payload, status=200):
        self._payload = payload
        self.status_code = status

    def json(self):
        return self._payload


def _fake_verify(user):
    """返回一个替换 requests.get 的假实现：对 /api/ticket/verify 返回给定用户。"""
    def _get(url, **kwargs):
        assert url.startswith(YZ + "/api/ticket/verify"), f"意外的请求: {url}"
        if user is None:
            return FakeResp({"ok": False, "msg": "ticket 无效或已过期"}, status=403)
        return FakeResp({"ok": True, **user}, status=200)
    return _get


@pytest.fixture
def client(monkeypatch, tmp_path):
    (tmp_path / "conf").mkdir()
    (tmp_path / "certs").mkdir()
    (tmp_path / "logs").mkdir()
    monkeypatch.setenv("TPROXY_CACHE_BASE", str(tmp_path))
    monkeypatch.setenv("TPROXY_CONF_D", str(tmp_path / "conf"))
    monkeypatch.setenv("TPROXY_DNSMASQ_CONF", str(tmp_path / "dnsmasq.conf"))
    monkeypatch.setenv("TPROXY_CERTS_DIR", str(tmp_path / "certs"))
    monkeypatch.setenv("TPROXY_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setenv("YZ_LOGIN_URL", YZ)
    monkeypatch.setenv("YZ_APP_REF", "id:55")
    monkeypatch.setenv("MANAGER_SECRET_KEY", "test-secret-key")
    monkeypatch.setenv("MANAGER_BASE_URL", "http://192.168.0.18:5557")
    app = create_app()
    app.config["TESTING"] = True
    return app.test_client()


# ---------- 未登录 ----------

def test_index_redirects_to_yz_login(client):
    r = client.get("/")
    assert r.status_code == 302
    loc = r.headers["Location"]
    # 必须带上应用引用，而不是硬编码回调 URL
    assert loc == f"{YZ}/login?from=id:55", f"实际跳转到: {loc}"


def test_all_api_endpoints_require_login(client):
    """未登录访问任何 API 都不得返回数据。

    这是管理端接入 SSO 的**核心目的** —— 此前它没有任何认证，
    只能靠绑回环来保护。
    """
    for ep in ("/api/status", "/api/cache", "/api/rules",
               "/api/certs", "/api/hitrate"):
        r = client.get(ep)
        assert r.status_code == 401, f"{ep} 未登录却返回 {r.status_code}"


# ---------- 回调 ----------

def test_callback_without_ticket_is_rejected(client):
    r = client.get("/callback")
    assert r.status_code == 400


def test_callback_with_invalid_ticket_redirects_to_login(client, monkeypatch):
    monkeypatch.setattr("backend.sso.requests.get", _fake_verify(None))
    r = client.get("/callback?ticket=bad")
    assert r.status_code in (302, 403), f"实际 {r.status_code}"
    if r.status_code == 302:
        assert "/login" in r.headers["Location"]


# ---------- 授权：只有管理员 ----------

def test_non_admin_is_denied(client, monkeypatch):
    """能登录 ≠ 能进管理端。非管理员即使 ticket 有效也必须被拒。"""
    monkeypatch.setattr("backend.sso.requests.get",
                        _fake_verify({"id": 7, "username": "u7",
                                      "display_name": "普通用户", "is_admin": 0}))
    r = client.get("/callback?ticket=ok")
    assert r.status_code == 403, f"非管理员应被拒，实际 {r.status_code}"

    # 且不得建立可用的登录态
    r2 = client.get("/api/status")
    assert r2.status_code == 401, "非管理员不得获得访问权"


def test_non_admin_string_zero_also_denied(client, monkeypatch):
    """`is_admin` 可能是字符串 "0"（JSON 序列化差异），不得被当成真值放行。"""
    monkeypatch.setattr("backend.sso.requests.get",
                        _fake_verify({"id": 7, "username": "u7",
                                      "display_name": "普通用户", "is_admin": "0"}))
    r = client.get("/callback?ticket=ok")
    assert r.status_code == 403, f'is_admin="0" 应被拒，实际 {r.status_code}'


def test_missing_is_admin_field_denied(client, monkeypatch):
    """缺少 is_admin 字段时按非管理员处理（fail-closed）。"""
    monkeypatch.setattr("backend.sso.requests.get",
                        _fake_verify({"id": 7, "username": "u7",
                                      "display_name": "普通用户"}))
    r = client.get("/callback?ticket=ok")
    assert r.status_code == 403


def test_admin_is_allowed_and_can_read_apis(client, monkeypatch):
    monkeypatch.setattr("backend.sso.requests.get",
                        _fake_verify({"id": 1, "username": "10015200",
                                      "display_name": "张三", "is_admin": 1}))
    r = client.get("/callback?ticket=ok")
    assert r.status_code == 302, f"管理员应被放行，实际 {r.status_code}"

    # 放行后各 API 应可访问
    for ep in ("/api/status", "/api/cache", "/api/rules",
               "/api/certs", "/api/hitrate"):
        rr = client.get(ep)
        assert rr.status_code == 200, f"{ep} -> {rr.status_code}"


def test_ticket_on_root_also_works(client, monkeypatch):
    """兼容「回调 URL 配成首页」的情况。

    否则会死循环：首页收到 ticket 却不处理 → 重定向到 SSO → 又跳回首页…
    """
    monkeypatch.setattr("backend.sso.requests.get",
                        _fake_verify({"id": 1, "username": "10015200",
                                      "display_name": "张三", "is_admin": 1}))
    r = client.get("/?ticket=ok")
    assert r.status_code == 302
    assert client.get("/api/status").status_code == 200, "带 ticket 访问首页也应完成登录"


def test_root_ticket_still_denies_non_admin(client, monkeypatch):
    monkeypatch.setattr("backend.sso.requests.get",
                        _fake_verify({"id": 7, "username": "u7",
                                      "display_name": "普通用户", "is_admin": 0}))
    r = client.get("/?ticket=ok")
    assert r.status_code == 403


def test_logout_clears_session(client, monkeypatch):
    monkeypatch.setattr("backend.sso.requests.get",
                        _fake_verify({"id": 1, "username": "a",
                                      "display_name": "管理员", "is_admin": 1}))
    client.get("/callback?ticket=ok")
    assert client.get("/api/status").status_code == 200

    client.get("/logout")
    assert client.get("/api/status").status_code == 401, "登出后不应可访问"


# ---------- 配置 ----------

def test_login_url_uses_configured_app_ref(client, monkeypatch, tmp_path):
    """应用引用走配置，便于换环境时不必改代码。"""
    monkeypatch.setenv("YZ_APP_REF", "id:99")
    app = create_app()
    app.config["TESTING"] = True
    c = app.test_client()
    r = c.get("/")
    assert "from=id:99" in r.headers["Location"]
