"""Flask API 测试。

所有路径通过环境变量注入，使测试可在临时目录上运行，
不触碰真实配置与缓存。
"""
import os
import subprocess

import pytest

from app import create_app


@pytest.fixture
def client(monkeypatch, tmp_path):
    (tmp_path / "conf").mkdir()
    (tmp_path / "certs").mkdir()
    (tmp_path / "logs").mkdir()
    # 签发/上游端点都要求显式注入配置根目录 —— 不注入会落到
    # DEFAULTS 里的 /opt/TProxy/proxy，也就是**生产目录**
    (tmp_path / "proxy" / "ca").mkdir(parents=True)
    monkeypatch.setenv("TPROXY_CACHE_BASE", str(tmp_path))
    monkeypatch.setenv("TPROXY_CONF_D", str(tmp_path / "conf"))
    monkeypatch.setenv("TPROXY_DNSMASQ_CONF", str(tmp_path / "dnsmasq.conf"))
    monkeypatch.setenv("TPROXY_CERTS_DIR", str(tmp_path / "certs"))
    monkeypatch.setenv("TPROXY_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setenv("TPROXY_PROXY_DIR", str(tmp_path / "proxy"))
    # 必须显式指向临时目录 —— 不设就会落到默认的 NAS 发布目录，
    # 测试会往生产用的分发目录里写根 CA
    (tmp_path / "dist").mkdir()
    monkeypatch.setenv("TPROXY_DIST_DIR", str(tmp_path / "dist"))
    monkeypatch.setenv("MANAGER_SECRET_KEY", "test-secret-key")
    app = create_app()
    app.config["TESTING"] = True
    c = app.test_client()
    # 这些用例关注数据解析本身，认证由 test_sso.py 覆盖 ——
    # 这里直接置入已登录的管理员 session，避免每个用例都走一遍 SSO
    with c.session_transaction() as sess:
        sess["user"] = {"id": 1, "username": "tester", "display_name": "测试管理员"}
    return c


def test_status_ok(client):
    r = client.get("/api/status")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_status_reports_version_and_user(client):
    """界面顶栏要显示版本号与登录人名，二者都由该接口提供。"""
    d = client.get("/api/status").get_json()
    assert d["version"], "缺少版本号"
    assert d["version"].count(".") == 2, f"版本号格式异常: {d['version']}"
    assert d["user"]["display_name"] == "测试管理员"


# ---- 静态资源版本：自动失效 ----
# 人工改版本号这条链断过一次：改了 app.js 却忘了改 index.html 里的 ?v=，
# 结果是浏览器一直跑旧脚本，现象却表现为「新功能没生效」。

def test_status_reports_build_fingerprint(client):
    d = client.get("/api/status").get_json()
    assert d["build"], "缺少构建指纹 —— 界面无法分辨部署的是哪一版"


def test_asset_version_tracks_content(tmp_path):
    from version import asset_version
    (tmp_path / "index.html").write_text("a")
    (tmp_path / "app.js").write_text("b")

    v1 = asset_version(str(tmp_path))
    assert v1 == asset_version(str(tmp_path)), "同一内容应得到同一指纹"

    (tmp_path / "app.js").write_text("c")
    assert asset_version(str(tmp_path)) != v1, \
        "内容变了指纹却没变 —— 浏览器会一直用缓存的旧脚本"


def test_asset_version_covers_each_static_file(tmp_path):
    """两个文件都要进指纹，漏一个就等于那个文件不会失效。"""
    from version import asset_version
    (tmp_path / "index.html").write_text("a")
    (tmp_path / "app.js").write_text("b")
    v1 = asset_version(str(tmp_path))

    (tmp_path / "index.html").write_text("z")
    assert asset_version(str(tmp_path)) != v1


def test_asset_version_missing_files_does_not_crash(tmp_path):
    """静态目录缺文件时仍要能算出一个指纹，而不是让整页 500。"""
    from version import asset_version
    assert asset_version(str(tmp_path))


def test_index_substitutes_asset_version(client):
    """占位符必须被替换掉。

    漏替换的表现很有迷惑性：浏览器去请求 /static/app.js?v=__ASSET_V__，
    匹配不上任何缓存键，但也没人会发现 —— 直到某次改动没生效。
    """
    html = client.get("/").get_data(as_text=True)
    assert "__ASSET_V__" not in html, "占位符未被替换"
    assert "app.js?v=" in html


def test_index_references_current_asset_version(client):
    """index.html 里带的指纹必须等于当前静态资源的指纹。

    不等就意味着：内容变了、URL 没变 → 浏览器继续用旧的 app.js。
    这条是「自动升级」真正要保证的不变量。
    """
    from version import asset_version
    html = client.get("/").get_data(as_text=True)
    assert f"app.js?v={asset_version()}" in html


# ---- CHANGELOG ----
# 版本号写在 CHANGELOG.md 里，其他地方读它 —— 单一来源，不会各写各的。

def test_changelog_version_is_parsed_from_file(tmp_path):
    from version import version_from_changelog
    p = tmp_path / "CHANGELOG.md"
    p.write_text("# 更新日志\n\n## [1.2.3] - 2026-01-01\n\n### 新增\n- x\n")
    assert version_from_changelog(str(p)) == "1.2.3"


def test_changelog_version_takes_the_first_entry(tmp_path):
    """最新的在最上面 —— 取第一条，不是随便一条。"""
    from version import version_from_changelog
    p = tmp_path / "CHANGELOG.md"
    p.write_text("## [0.9.9] - 2026-01-02\n\n## [0.9.8] - 2026-01-01\n")
    assert version_from_changelog(str(p)) == "0.9.9"


@pytest.mark.parametrize("text", [
    "",
    "# 更新日志\n还没有任何版本\n",
    "## [abc] - 2026-01-01\n",
    "## 1.2.3\n",              # 缺方括号
    "## [1.2] - 2026-01-01\n",  # 不是三位
])
def test_changelog_version_rejects_garbage(tmp_path, text):
    """解析不出就返回 None，由调用方决定回退 —— 不能瞎猜一个版本号出来。"""
    from version import version_from_changelog
    p = tmp_path / "CHANGELOG.md"
    p.write_text(text)
    assert version_from_changelog(str(p)) is None


def test_changelog_version_missing_file(tmp_path):
    from version import version_from_changelog
    assert version_from_changelog(str(tmp_path / "nope.md")) is None


def test_repo_changelog_has_a_valid_version():
    """仓库里的 CHANGELOG.md 必须真的能被解析出版本号。

    这条是防漂移的闸门：格式写歪了、或忘了加版本条目，
    界面上的版本号会变成回退值，而那时已经部署上线了。
    """
    from version import version_from_changelog
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    v = version_from_changelog(os.path.join(repo, "CHANGELOG.md"))
    assert v, "无法从仓库根的 CHANGELOG.md 解析出版本号"
    assert v.count(".") == 2


def test_get_version_prefers_env(monkeypatch):
    """环境变量仍要能覆盖，便于灰度或多实例对照。"""
    from version import get_version
    monkeypatch.setenv("MANAGER_VERSION", "9.9.9")
    assert get_version() == "9.9.9"


def test_api_changelog_returns_markdown(client, monkeypatch, tmp_path):
    p = tmp_path / "CL.md"
    p.write_text("# 更新日志\n\n## [1.2.3] - 2026-01-01\n\n### 新增\n- 一条\n")
    monkeypatch.setenv("TPROXY_CHANGELOG", str(p))

    r = client.get("/api/changelog")
    assert r.status_code == 200
    d = r.get_json()
    assert "一条" in d["markdown"]
    assert d["version"] == "1.2.3"


def test_api_changelog_missing_file_does_not_500(client, monkeypatch, tmp_path):
    """文件读不到也要返回可用结构 —— 界面顶栏靠它显示版本，不能整页崩。"""
    monkeypatch.setenv("TPROXY_CHANGELOG", str(tmp_path / "nope.md"))
    r = client.get("/api/changelog")
    assert r.status_code == 200
    assert r.get_json()["markdown"] == ""


def test_api_changelog_requires_login(client):
    with client.session_transaction() as sess:
        sess.clear()
    assert client.get("/api/changelog").status_code == 401


def test_index_is_not_cached_by_browser(client):
    """index.html 本身不能被缓存。

    它内部带着静态资源的指纹；它自己被缓存住，指纹也就跟着一起过期，
    整套自动失效就白做了。
    """
    r = client.get("/")
    assert "no-cache" in r.headers.get("Cache-Control", ""), \
        f"Cache-Control: {r.headers.get('Cache-Control')}"


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


# ---- 证书：根 CA 与签发端点 ----

def test_certs_reports_absent_root_ca(client):
    """测试树里没有根 CA，接口要返回 null 而不是报错 —— 界面据此显示待补。"""
    d = client.get("/api/certs").get_json()
    assert "root_ca" in d
    assert d["root_ca"] is None


def test_certs_reports_root_ca_expiry(client, tmp_path):
    """根 CA 必须出现在界面上。

    它过期会让**所有**域名同时失效且所有客户端都要重装，
    而此前列表只列 ca/certs/*.crt —— 最要命的那张反而看不见。
    """
    ca = tmp_path / "proxy" / "ca"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(ca / "tproxy-ca.key"),
         "-out", str(ca / "tproxy-ca.crt"),
         "-days", "1000", "-subj", "/CN=TProxy Root CA"],
        check=True, capture_output=True)

    d = client.get("/api/certs").get_json()
    assert d["root_ca"] is not None
    assert 998 <= d["root_ca"]["days_left"] <= 1000
    assert d["root_ca"]["expiring_soon"] is False


def test_certs_reports_default_days(client):
    """界面用它预填有效期，故必须由后端给出而不是前端写死。"""
    d = client.get("/api/certs").get_json()
    assert isinstance(d["default_days"], int)
    assert d["default_days"] > 0


def test_cert_preview_requires_login(client):
    """签发端点写生产文件，绝不能匿名可用。"""
    with client.session_transaction() as sess:
        sess.clear()
    r = client.post("/api/certs/preview",
                    json={"domain": "a.example.com", "days": 30})
    assert r.status_code == 401


def test_cert_preview_rejects_injection(client):
    """域名会拼进配置文件与 openssl 参数，校验必须在服务端做。"""
    r = client.post("/api/certs/preview",
                    json={"domain": "a.example.com\naddress=/evil/1.1.1.1",
                          "days": 30})
    assert r.status_code == 200
    assert r.get_json()["ok"] is False


def test_cert_apply_rejects_bad_days(client):
    r = client.post("/api/certs/apply",
                    json={"domain": "a.example.com", "days": "abc"})
    assert r.get_json()["ok"] is False


# ---- 更换根 CA ----

def test_rootca_apply_requires_confirm_word(client):
    """换根是全系统破坏性最强的操作，光有登录态不够。

    确认词必须在**服务端**校验 —— 前端那个输入框只是提示，任何人都能绕过。
    """
    r = client.post("/api/rootca/apply", json={"days": 10950, "confirm": ""})
    assert r.get_json()["ok"] is False
    assert "REPLACE" in r.get_json()["msg"]

    r = client.post("/api/rootca/apply", json={"days": 10950, "confirm": "yes"})
    assert r.get_json()["ok"] is False


def test_rootca_apply_requires_login(client):
    with client.session_transaction() as sess:
        sess.clear()
    r = client.post("/api/rootca/apply", json={"days": 10950, "confirm": "REPLACE"})
    assert r.status_code == 401


def test_rootca_preview_rejects_empty_cert_dir(client):
    """没有域名证书却换根，只会换来一个谁也用不上的新根。"""
    r = client.post("/api/rootca/preview", json={"days": 10950})
    assert r.get_json()["ok"] is False


def test_certs_reports_root_default_days(client):
    d = client.get("/api/certs").get_json()
    assert d["root_default_days"] > d["default_days"], \
        "根 CA 的默认有效期必须远长于叶子证书"


def test_hitrate_lists_six_types(client):
    """六类都要出现 —— registry/git 由后端自缓存，需明确标注而非缺席。"""
    r = client.get("/api/hitrate")
    assert r.status_code == 200
    rows = r.get_json()["hitrate"]
    types = [x["type"] for x in rows]
    assert len(rows) == 6
    for t in ("os", "python", "nodejs", "java", "registry", "git"):
        assert t in types


def test_hitrate_reads_real_log_format(client, tmp_path):
    """用与 nginx.conf `log_format main` 一致的行验证端到端解析。"""
    line = ('127.0.0.1 - [23/Sep/2026:05:09:28 +0000] "GET / HTTP/1.1" 200 696 '
            '"-" "curl/8.4.0" cache={}\n')
    (tmp_path / "logs" / "python.log").write_text(line.format("HIT") * 3 + line.format("MISS"))
    r = client.get("/api/hitrate")
    rows = {x["type"]: x for x in r.get_json()["hitrate"]}
    assert rows["python"]["hit"] == 3
    assert rows["python"]["miss"] == 1
    assert rows["python"]["rate"] == 75.0
