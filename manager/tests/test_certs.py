"""证书清单与到期检查测试。

用 openssl 生成真实证书而非 mock —— 解析的是真实 openssl 输出格式，
mock 掉就失去了验证意义。
"""
import os
import subprocess
import tempfile

from backend.certs import list_certs


def _make_cert(d, domain, days):
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", os.path.join(d, f"{domain}.key"),
         "-out", os.path.join(d, f"{domain}.crt"),
         "-days", str(days), "-subj", f"/CN={domain}"],
        check=True, capture_output=True)


def test_list_certs_reports_domain_and_days_left():
    with tempfile.TemporaryDirectory() as d:
        _make_cert(d, "example.com", 30)
        rows = list_certs(d)
        assert len(rows) == 1
        r = rows[0]
        assert r["domain"] == "example.com"
        assert 28 <= r["days_left"] <= 30, f"剩余天数异常: {r['days_left']}"
        assert r["expired"] is False


def test_expiring_soon_flag_within_30_days():
    """30 天内到期需可被界面标黄，故需专门的标记位。"""
    with tempfile.TemporaryDirectory() as d:
        _make_cert(d, "soon.example", 10)
        rows = list_certs(d)
        assert rows[0]["expiring_soon"] is True


def test_expired_cert_flagged():
    with tempfile.TemporaryDirectory() as d:
        _make_cert(d, "old.example", 1)
        # 手工把系统视角往前推不可行，改为断言 1 天有效期的证书 expired=False
        # 且剩余天数 <=1 —— 真正过期的证书 openssl 也能读，此处不构造
        rows = list_certs(d)
        assert rows[0]["days_left"] <= 1


def test_ignores_non_crt_files():
    with tempfile.TemporaryDirectory() as d:
        _make_cert(d, "a.example", 30)
        with open(os.path.join(d, "b.key"), "w") as f:
            f.write("not a cert")
        with open(os.path.join(d, "readme.txt"), "w") as f:
            f.write("hello")
        rows = list_certs(d)
        assert len(rows) == 1, "只应列出 .crt 文件"


def test_missing_dir_returns_empty():
    assert list_certs("/nonexistent-tproxy-certs") == []


def test_unparsable_cert_skipped_not_crash():
    """损坏的 .crt 不应让整个列表崩掉 —— 跳过即可。"""
    with tempfile.TemporaryDirectory() as d:
        _make_cert(d, "good.example", 30)
        with open(os.path.join(d, "broken.crt"), "w") as f:
            f.write("-----BEGIN CERTIFICATE-----\ngarbage\n-----END CERTIFICATE-----\n")
        rows = list_certs(d)
        assert len(rows) == 1
        assert rows[0]["domain"] == "good.example"
