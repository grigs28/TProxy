"""签发 / 重新签发域名证书的测试。

这个功能会**写正在使用的生产证书**，所以测试盯住四件事：

  1. 域名与有效期校验 —— 会拼进 openssl 的 -subj 与 -extfile，校验不严等于参数注入
  2. 原子性 —— 重新签发覆盖的是【正在用的】证书，中途失败绝不能留下残缺
  3. 根 CA 边界 —— 有效期超过根 CA 是静默陷阱：界面显示「还有 2000 天」，
     实际从根 CA 过期那刻起就不再被信任
  4. 可重建 —— 界面签的证书要登记进 domains.txt，否则根 CA 重建后它会凭空消失
"""
import os
import shutil
import subprocess

import pytest

from backend.certmgr import (
    parse_sans,
    preview_sign,
    sign_cert,
    validate_cert_request,
)

_REPO = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CA_SRC = os.path.join(_REPO, "proxy", "ca")


def _make_ca(d, ca_days=3650):
    """在 d 里造一个一次性根 CA。

    不用 proxy/ca/gen-ca.sh：它生成 4096 位密钥，每用例一次太慢。
    但 gen-cert.sh **必须**是仓库里那个真脚本 —— 原子性正由它保证，
    替身会让本文件最重要的那条用例失去意义。
    """
    d = str(d)
    subprocess.run(["openssl", "genrsa", "-out", "tproxy-ca.key", "2048"],
                   cwd=d, check=True, capture_output=True)
    subprocess.run(
        ["openssl", "req", "-x509", "-new", "-nodes", "-key", "tproxy-ca.key",
         "-sha256", "-days", str(ca_days), "-subj", "/CN=TProxy Test CA",
         "-out", "tproxy-ca.crt"], cwd=d, check=True, capture_output=True)

    shutil.copy(os.path.join(CA_SRC, "gen-cert.sh"),
                os.path.join(d, "gen-cert.sh"))
    os.chmod(os.path.join(d, "gen-cert.sh"), 0o755)
    os.makedirs(os.path.join(d, "certs"), exist_ok=True)
    with open(os.path.join(d, "domains.txt"), "w", encoding="utf-8") as f:
        f.write("# 域名清单\n")
    return d


@pytest.fixture
def ca(tmp_path):
    """正常根 CA（剩余约 3650 天）。"""
    return _make_ca(tmp_path)


@pytest.fixture
def short_ca(tmp_path):
    """根 CA 只剩 10 天 —— 用来验证证书有效期不会被静默放大。"""
    return _make_ca(tmp_path, ca_days=10)


# ---------- 参数解析与校验 ----------

def test_parse_sans_splits_and_dedupes():
    assert parse_sans("a.example.com, b.example.com c.example.com") == \
        ["a.example.com", "b.example.com", "c.example.com"]
    assert parse_sans("a.example.com,a.example.com") == ["a.example.com"]
    assert parse_sans("") == []
    assert parse_sans(None) == []


def test_valid_request_cleaned():
    ok, err, clean = validate_cert_request(
        "cn.example.com", "a.example.com, cn.example.com", "3650")
    assert ok, err
    assert clean["cn"] == "cn.example.com"
    # 与 CN 重复的 SAN 要去掉，否则证书里会重复出现
    assert clean["sans"] == ["a.example.com"]
    assert clean["days"] == 3650


@pytest.mark.parametrize("days", [0, -1, 40000, "abc", None, "", 1.5, "1.5", True])
def test_invalid_days_rejected(days):
    """静默把用户填的有效期截断成整数比报错更糟。"""
    ok, err, _ = validate_cert_request("a.example.com", "", days)
    assert not ok, f"{days!r} 不应被接受"
    assert err


def test_wildcard_rejected_for_certificate(ca):
    """通配证书在本架构里永远不会被选中。

    tengine 用 `ssl_certificate .../certs/$ssl_server_name.crt` 按 SNI 取文件，
    而 SNI 永远是具体主机名，不可能等于 `*.example.com` ——
    放行只会得到一张「签了但没用上」的证书。
    """
    ok, err, _ = validate_cert_request("*.example.com", "", 3650)
    assert not ok
    assert "通配" in err

    ok, err, _ = validate_cert_request("a.example.com", "*.example.com", 3650)
    assert not ok, "附加域名里的通配同样不会被选中"
    assert "通配" in err


@pytest.mark.parametrize("san", [
    "$(id).example.com",
    "a.example.com;rm -rf /",
    "a.example.com`id`",
    "not-a-domain",
])
def test_invalid_san_rejected(san):
    ok, err, _ = validate_cert_request("a.example.com", san, 3650)
    assert not ok, f"非法附加域名被接受: {san!r}"
    assert err


# ---------- 预览 ----------

def test_preview_lists_cert_and_domains_txt(ca):
    r = preview_sign("new.example.com", "", 3650, ca)
    assert r["ok"], r.get("msg")
    files = [c["file"] for c in r["changes"]]
    assert any("new.example.com.crt" in f for f in files), files
    assert any("domains.txt" in f for f in files), \
        f"未登记 domains.txt，根 CA 重建后该证书会消失: {files}"


def test_preview_marks_resign_when_cert_exists(ca):
    assert sign_cert("dup.example.com", "", 3650, ca)["ok"]
    r = preview_sign("dup.example.com", "", 3650, ca)
    actions = " ".join(c["action"] for c in r["changes"])
    assert "重新签发" in actions, f"已有证书时应提示是覆盖: {r['changes']}"


def test_preview_rejects_bad_domain(ca):
    r = preview_sign("bad domain.com", "", 3650, ca)
    assert not r["ok"]
    assert r["msg"]


def test_preview_writes_nothing(ca):
    """预览必须只读 —— 否则「预览」就成了没确认就生效的提交。"""
    before = sorted(os.listdir(os.path.join(ca, "certs")))
    preview_sign("ghost.example.com", "", 3650, ca)
    assert sorted(os.listdir(os.path.join(ca, "certs"))) == before


# ---------- 签发 ----------

def test_sign_creates_cert_and_key(ca):
    r = sign_cert("one.example.com", "", 3650, ca)
    assert r["ok"], r.get("msg")
    assert os.path.exists(os.path.join(ca, "certs", "one.example.com.crt"))
    assert os.path.exists(os.path.join(ca, "certs", "one.example.com.key"))


def test_sign_includes_extra_sans(ca):
    """附加域名必须真的进 SAN —— 这正是「编辑证书」的主要用途。"""
    from backend.certs import cert_info
    r = sign_cert("cn.example.com", "a.example.com b.example.com", 3650, ca)
    assert r["ok"], r.get("msg")
    info = cert_info(os.path.join(ca, "certs", "cn.example.com.crt"))
    assert info is not None
    for d in ("cn.example.com", "a.example.com", "b.example.com"):
        assert d in info["sans"], f"{d} 未进 SAN: {info['sans']}"


def test_sign_honours_days(ca):
    from backend.certs import cert_info
    r = sign_cert("days.example.com", "", 30, ca)
    assert r["ok"], r.get("msg")
    info = cert_info(os.path.join(ca, "certs", "days.example.com.crt"))
    assert 28 <= info["days_left"] <= 30, f"有效期未生效: {info['days_left']}"


def test_sign_records_domain_in_domains_txt(ca):
    """domains.txt 是根 CA 重建时的重签清单 —— 界面签的也要进去。"""
    assert sign_cert("listed.example.com", "", 3650, ca)["ok"]
    with open(os.path.join(ca, "domains.txt"), encoding="utf-8") as f:
        txt = f.read()
    assert "listed.example.com" in txt


def test_sign_records_sans_on_the_same_line(ca):
    """重建时 deploy.sh 按行重签，故 SAN 必须与本行一起存下来。"""
    assert sign_cert("multi.example.com", "x.example.com", 3650, ca)["ok"]
    with open(os.path.join(ca, "domains.txt"), encoding="utf-8") as f:
        txt = f.read()
    assert "multi.example.com x.example.com" in txt


def test_sign_does_not_duplicate_domains_txt(ca):
    sign_cert("once.example.com", "", 3650, ca)
    sign_cert("once.example.com", "", 3650, ca)
    with open(os.path.join(ca, "domains.txt"), encoding="utf-8") as f:
        assert f.read().count("once.example.com") == 1


def test_sign_rejects_bad_request_without_touching_files(ca):
    before = sorted(os.listdir(os.path.join(ca, "certs")))
    r = sign_cert("bad domain.com", "", 3650, ca)
    assert not r["ok"]
    assert sorted(os.listdir(os.path.join(ca, "certs"))) == before


# ---------- 原子性：本文件最重要的一条 ----------

def test_resign_failure_keeps_old_cert_usable(ca):
    """重新签发失败时，正在用的证书必须原封不动。

    旧的 gen-cert.sh 会写坏【两个】文件：
      `openssl genrsa -out certs/X.key`    立刻截断旧私钥
      `openssl x509 -req -out certs/X.crt` 在报错之前就把旧证书清成 0 字节
    也就是说一次失败的重新签发会让该域名 HTTPS 彻底失效，
    而现场完全看不出原因。

    这条用例已对着旧脚本验证过会失败（旧脚本下 .crt 变成空文件）——
    否则它可能只是在测脚本开头那个「缺少根 CA」的守卫。
    """
    assert sign_cert("keep.example.com", "", 3650, ca)["ok"]
    crt = os.path.join(ca, "certs", "keep.example.com.crt")
    key = os.path.join(ca, "certs", "keep.example.com.key")
    with open(crt, "rb") as f:
        before_crt = f.read()
    with open(key, "rb") as f:
        before_key = f.read()

    # 把根 CA 私钥换成垃圾内容，而**不是删掉它**。
    # 删掉只会触发脚本开头的 `[[ -f tproxy-ca.key ]]` 守卫，一步 openssl
    # 都不会执行 —— 那样连非原子的旧脚本也能通过本用例，等于什么都没验证。
    # 换成垃圾内容才能让失败发生在【新私钥已经生成之后】的
    # `openssl x509 -req -CAkey` 那一步，也就是唯一会毁掉旧证书的时刻。
    with open(os.path.join(ca, "tproxy-ca.key"), "w") as f:
        f.write("-----BEGIN PRIVATE KEY-----\ngarbage\n-----END PRIVATE KEY-----\n")

    r = sign_cert("keep.example.com", "", 3650, ca)
    assert not r["ok"], "根 CA 私钥不可用时不应报成功"

    with open(crt, "rb") as f:
        assert f.read() == before_crt, "签发失败却改动了旧证书"
    with open(key, "rb") as f:
        assert f.read() == before_key, \
            "签发失败却改动了旧私钥 —— 原证书已无法使用"

    # 报错信息要指向真正的原因，否则运维只能靠猜
    assert "签发失败" in r["msg"]


def test_resign_success_replaces_both_files(ca):
    """成功路径也要确认真的换新了 —— 否则「重新签发」可能只是原样重写。"""
    assert sign_cert("rotate.example.com", "", 30, ca)["ok"]
    crt = os.path.join(ca, "certs", "rotate.example.com.crt")
    with open(crt, "rb") as f:
        first = f.read()

    assert sign_cert("rotate.example.com", "", 3650, ca)["ok"]
    with open(crt, "rb") as f:
        assert f.read() != first, "重新签发后证书内容未变化"

    from backend.certs import cert_info
    assert cert_info(crt)["days_left"] > 3600


# ---------- 根 CA 边界 ----------

def test_days_clamped_to_root_ca_validity(short_ca):
    """证书有效期不能超过根 CA。

    超过了并不报错，只是从根 CA 过期那刻起整条链就不再被信任，
    而界面还在显示「还有 2000 天」—— 一个 UI 专门用来回答的问题被答错。
    """
    from backend.certs import cert_info
    r = sign_cert("long.example.com", "", 3650, short_ca)
    assert r["ok"], r.get("msg")
    info = cert_info(os.path.join(short_ca, "certs", "long.example.com.crt"))
    assert info["days_left"] <= 10, f"证书有效期超出根 CA: {info['days_left']}"
    assert "根 CA" in r["msg"], f"发生裁剪时必须说明原因: {r['msg']}"


def test_preview_warns_when_days_exceed_ca(short_ca):
    r = preview_sign("long.example.com", "", 3650, short_ca)
    assert r["ok"], r.get("msg")
    assert "根 CA" in r.get("note", ""), f"预览未提示裁剪: {r.get('note')}"


def test_normal_days_not_clamped(ca):
    r = sign_cert("normal.example.com", "", 3650, ca)
    assert r["ok"], r.get("msg")
    assert "裁剪" not in r["msg"], f"不该裁剪的却裁剪了: {r['msg']}"
