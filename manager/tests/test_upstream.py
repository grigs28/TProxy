"""新增上游（劫持规则 + 证书）的测试。

这个功能会**写生产配置**，所以测试要盯住三类最容易出事的地方：

  1. 域名校验 —— 域名会被拼进 dnsmasq 与 nginx 配置，校验不严等于配置注入
  2. 三处联动 —— 劫持、证书、tengine server_name 必须一起改，漏一处是静默失效
  3. 原子性 —— 中途失败必须回滚，不能留下半改状态
"""
import os
import tempfile

import pytest

from backend.upstream import (
    CATEGORIES,
    apply_upstream,
    preview_upstream,
    validate_domain,
)


# ---------- 域名校验 ----------

@pytest.mark.parametrize("domain", [
    "example.com",
    "repo.openeuler.org",
    "registry-1.docker.io",
    "sub.domain.example.co.uk",
])
def test_valid_domains_accepted(domain):
    ok, err = validate_domain(domain)
    assert ok, f"{domain} 应被接受，却报: {err}"


@pytest.mark.parametrize("domain,why", [
    ("", "空"),
    ("   ", "空白"),
    ("no-dot", "无点号"),
    ("exa mple.com", "含空格"),
    ("example.com\naddress=/evil.com/1.2.3.4", "换行注入"),
    ("example.com;", "分号注入"),
    ("example.com/../../etc/passwd", "路径穿越"),
    ("$(whoami).com", "命令替换"),
    ("example.com`id`", "反引号"),
    ("a" * 260 + ".com", "超长"),
    ("-leading.com", "以连字符开头"),
    (".leading.dot.com", "以点开头"),
])
def test_invalid_domains_rejected(domain, why):
    """域名会被直接拼进配置文件，任何异常字符都必须拒绝。

    尤其要挡住换行 —— `example.com\\naddress=/evil.com/...` 能往 dnsmasq
    配置里注入任意规则。
    """
    ok, _ = validate_domain(domain)
    assert not ok, f"非法域名被接受（{why}）: {domain!r}"


def test_wildcard_domain_accepted():
    """通配符子域是 dnsmasq 的合法写法，应当放行。"""
    ok, _ = validate_domain("*.example.com")
    assert ok


# ---------- 预览 ----------

@pytest.fixture
def tree(tmp_path):
    """搭一个最小的配置树，结构与生产一致。"""
    d = tmp_path
    (d / "dnsmasq").mkdir()
    (d / "tengine" / "conf.d").mkdir(parents=True)
    (d / "ca" / "certs").mkdir(parents=True)
    (d / "ca" / "domains.txt").write_text("# 域名清单\n")

    (d / "dnsmasq" / "dnsmasq.conf").write_text(
        "# 配置\n"
        "listen-address=0.0.0.0\n"
        "address=/example.com/192.168.0.18\n"
        "# ---- Docker 镜像仓库劫持 ----\n"
        "address=/registry-1.docker.io/192.168.0.18\n"
    )
    (d / "tengine" / "conf.d" / "registry.conf").write_text(
        "server {\n"
        "    listen 443 ssl;\n"
        "    server_name registry-1.docker.io quay.io;\n"
        "}\n"
    )
    return d


def test_preview_lists_three_changes(tree):
    """预览要给出三处改动：dnsmasq、tengine、证书。"""
    r = preview_upstream("newrepo.example.org", "docker", str(tree))
    assert r["ok"], r.get("msg")
    files = [c["file"] for c in r["changes"]]
    assert any("dnsmasq.conf" in f for f in files), f"缺少 dnsmasq 改动: {files}"
    assert any("registry.conf" in f for f in files), f"缺少 tengine 改动: {files}"
    assert any("gen-cert" in c.get("action", "") or "证书" in c.get("desc", "")
               for c in r["changes"]), f"缺少证书步骤: {r['changes']}"


def test_preview_rejects_bad_domain(tree):
    r = preview_upstream("bad domain.com", "docker", str(tree))
    assert not r["ok"]
    assert r["msg"]


def test_preview_unknown_category(tree):
    r = preview_upstream("a.example.com", "not-a-category", str(tree))
    assert not r["ok"]
    assert "类型" in r["msg"]


# ---------- 应用 ----------

def test_apply_writes_all_three_places(tree, monkeypatch):
    """三处必须一起改。漏掉任何一处都是「设了却不生效」。"""
    # 证书签发用可预测的替身，避免依赖 openssl 与真 CA
    def fake_sign(domain, ca_dir):
        crt = os.path.join(ca_dir, "certs", f"{domain}.crt")
        key = os.path.join(ca_dir, "certs", f"{domain}.key")
        os.makedirs(os.path.dirname(crt), exist_ok=True)
        open(crt, "w").write("CERT")
        open(key, "w").write("KEY")
        return True, f"已签发 {domain}"

    r = apply_upstream("newrepo.example.org", "docker", str(tree), signer=fake_sign)
    assert r["ok"], r.get("msg")

    dnsmasq = open(os.path.join(tree, "dnsmasq", "dnsmasq.conf")).read()
    assert "address=/newrepo.example.org/192.168.0.18" in dnsmasq

    nginx = open(os.path.join(tree, "tengine", "conf.d", "registry.conf")).read()
    assert "newrepo.example.org" in nginx

    assert os.path.exists(os.path.join(tree, "ca", "certs", "newrepo.example.org.crt"))


def test_apply_is_idempotent(tree):
    """重复添加同一域名不应产生重复条目。"""
    def fake_sign(domain, ca_dir):
        os.makedirs(os.path.join(ca_dir, "certs"), exist_ok=True)
        open(os.path.join(ca_dir, "certs", f"{domain}.crt"), "w").write("CERT")
        open(os.path.join(ca_dir, "certs", f"{domain}.key"), "w").write("KEY")
        return True, "ok"

    for _ in range(2):
        r = apply_upstream("dup.example.org", "docker", str(tree), signer=fake_sign)
        assert r["ok"], r.get("msg")

    dnsmasq = open(os.path.join(tree, "dnsmasq", "dnsmasq.conf")).read()
    assert dnsmasq.count("address=/dup.example.org/192.168.0.18") == 1

    nginx = open(os.path.join(tree, "tengine", "conf.d", "registry.conf")).read()
    assert nginx.count("dup.example.org") == 1


def test_apply_rolls_back_on_signer_failure(tree):
    """证书签发失败时，配置文件必须回滚 —— 否则会留下「改了配置但没证书」的半残状态。"""
    before_dnsmasq = open(os.path.join(tree, "dnsmasq", "dnsmasq.conf")).read()
    before_nginx = open(os.path.join(tree, "tengine", "conf.d", "registry.conf")).read()

    def failing_sign(domain, ca_dir):
        return False, "签发失败（模拟）"

    r = apply_upstream("fail.example.org", "docker", str(tree), signer=failing_sign)
    assert not r["ok"]

    after_dnsmasq = open(os.path.join(tree, "dnsmasq", "dnsmasq.conf")).read()
    after_nginx = open(os.path.join(tree, "tengine", "conf.d", "registry.conf")).read()
    assert after_dnsmasq == before_dnsmasq, "dnsmasq 配置未回滚"
    assert after_nginx == before_nginx, "tengine 配置未回滚"


def test_categories_map_to_conf_files():
    """类型 → conf 文件的映射必须与实际 conf.d 里的文件对得上。"""
    assert CATEGORIES["docker"] == "registry.conf"
    assert CATEGORIES["python"] == "python.conf"
    assert CATEGORIES["java"] == "java.conf"
    assert CATEGORIES["nodejs"] == "nodejs.conf"
