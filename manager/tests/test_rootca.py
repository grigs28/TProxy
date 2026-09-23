"""根 CA 生成与轮换的测试。

这是全系统破坏性最强的操作：换根 = 换信任锚，**所有**域名证书立即失效、
每台客户端都要重装。所以测试盯住三件事：

  1. 代价必须先说清 —— 预览要列出会被重签的全部域名，不能让人点下去才知道
  2. 失败必须能回滚 —— 半换状态（新根 + 旧叶子）等于全网失联，
     而且旧根私钥若已丢，连退回去都做不到
  3. 成功必须发布 —— 换了根却不发布到分发目录，客户端拿不到新根，
     症状同样是全网失联，且完全看不出原因
"""
import os
import shutil
import subprocess

import pytest

from backend.rootca import (
    _collect_targets,
    preview_rotate,
    publish_root_ca,
    rotate_root_ca,
    validate_root_days,
)

_REPO = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CA_SRC = os.path.join(_REPO, "proxy", "ca")


def _make_tree(d, n_certs=2, ca_days=365):
    """造一棵最小但真实的 ca 树：真根 CA + 真域名证书。"""
    d = str(d)
    subprocess.run(["openssl", "genrsa", "-out", "tproxy-ca.key", "2048"],
                   cwd=d, check=True, capture_output=True)
    subprocess.run(
        ["openssl", "req", "-x509", "-new", "-nodes", "-key", "tproxy-ca.key",
         "-sha256", "-days", str(ca_days), "-subj", "/CN=TProxy Test Root",
         "-out", "tproxy-ca.crt"], cwd=d, check=True, capture_output=True)
    for name in ("gen-ca.sh", "gen-cert.sh"):
        shutil.copy(os.path.join(CA_SRC, name), os.path.join(d, name))
        os.chmod(os.path.join(d, name), 0o755)
    os.makedirs(os.path.join(d, "certs"), exist_ok=True)
    with open(os.path.join(d, "domains.txt"), "w", encoding="utf-8") as f:
        f.write("# 域名清单\n")

    for i in range(n_certs):
        extra = ["alt.example.com"] if i == 0 else []
        args = [os.path.join(d, "gen-cert.sh"), f"d{i}.example.com"] + extra
        subprocess.run(args, cwd=d, check=True, capture_output=True)
    return d


@pytest.fixture
def tree(tmp_path):
    return _make_tree(tmp_path)


@pytest.fixture
def dist(tmp_path_factory):
    return str(tmp_path_factory.mktemp("dist"))


def _fingerprint(path):
    r = subprocess.run(["openssl", "x509", "-in", path, "-noout",
                        "-fingerprint", "-sha256"],
                       capture_output=True, text=True)
    return r.stdout.strip()


def _snapshot(root):
    """整棵树的文件内容快照，用于验证回滚是否彻底。"""
    out = {}
    for base, _, files in os.walk(root):
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = fh.read()
    return out


# ---------- 参数 ----------

@pytest.mark.parametrize("days", [0, -1, 100, 40000, "abc", None, 1.5, True])
def test_invalid_days_rejected(days):
    ok, err, _ = validate_root_days(days)
    assert not ok, f"{days!r} 不应被接受"
    assert err


def test_long_validity_accepted():
    """长期有效正是这次的目的：根 CA 要能覆盖好几轮叶子轮换。"""
    ok, _, n = validate_root_days(10950)      # 30 年
    assert ok and n == 10950


# ---------- 目标收集 ----------

def test_collect_targets_uses_disk_certs_not_domains_txt(tree):
    """重签清单以 ca/certs 下的 .crt 为准 —— 那才是 tengine 实际在用的。

    domains.txt 只是一份记录，可能有陈旧条目（或漏记），
    拿它当清单会漏签或签出没人用的证书。
    """
    targets = _collect_targets(os.path.join(tree, "certs"))
    assert [c for c, _ in targets] == ["d0.example.com", "d1.example.com"]


def test_collect_targets_reads_back_existing_sans(tree):
    """SAN 从原证书读回，保证重签后与原来一致 —— 不能重签一次就丢附加域名。"""
    targets = dict(_collect_targets(os.path.join(tree, "certs")))
    assert targets["d0.example.com"] == ["alt.example.com"]
    assert targets["d1.example.com"] == []


# ---------- 预览 ----------

def test_preview_lists_root_and_every_leaf(tree, dist):
    r = preview_rotate(tree, 10950, dist)
    assert r["ok"], r.get("msg")
    assert r["targets"] == ["d0.example.com", "d1.example.com"]
    joined = " ".join(c["diff"] + c["desc"] for c in r["changes"])
    assert "d0.example.com" in joined, "预览未列出将被重签的域名"
    assert "客户端" in r["note"], "预览未说明客户端要做什么"


def test_preview_rejects_bad_days(tree):
    assert not preview_rotate(tree, 10, None)["ok"]


def test_preview_rejects_empty_cert_dir(tmp_path):
    """没有任何域名证书就换根 —— 只会换来一个谁也用不上的新根。"""
    (tmp_path / "certs").mkdir()
    r = preview_rotate(str(tmp_path), 10950, None)
    assert not r["ok"]
    assert "域名证书" in r["msg"]


def test_preview_writes_nothing(tree):
    before = _snapshot(tree)
    preview_rotate(tree, 10950, None)
    assert _snapshot(tree) == before, "预览动了文件"


# ---------- 轮换：编排与回滚（用替身，不跑 openssl）----------

def _fake_root_runner(ok=True):
    def run(days, ca_dir):
        if not ok:
            return 1, "", "模拟生成根 CA 失败"
        with open(os.path.join(ca_dir, "tproxy-ca.crt"), "w") as f:
            f.write("NEW ROOT CRT")
        with open(os.path.join(ca_dir, "tproxy-ca.key"), "w") as f:
            f.write("NEW ROOT KEY")
        return 0, "ok", ""
    return run


def _fake_signer(fail_on=None):
    def sign(cn, sans, days, ca_dir):
        if fail_on and cn == fail_on:
            return {"ok": False, "msg": "模拟重签失败"}
        p = os.path.join(ca_dir, "certs", f"{cn}.crt")
        with open(p, "w") as f:
            f.write(f"RESIGNED {cn}")
        return {"ok": True, "msg": "ok"}
    return sign


def test_rotate_root_failure_restores_old_root(tree):
    """生成新根失败时，旧根必须原样回来。

    旧根私钥若丢了，连「退回原状」都做不到 —— 那才是真正不可挽回的状态。
    """
    before = _snapshot(tree)
    r = rotate_root_ca(tree, 10950, root_runner=_fake_root_runner(ok=False),
                       signer=_fake_signer())
    assert not r["ok"]
    assert _snapshot(tree) == before, "失败后未回滚到原状"


def test_rotate_sign_failure_restores_everything(tree):
    """重签中途失败也要整份回滚 —— 半个新根 + 一半旧叶子是最坏的中间态。"""
    before = _snapshot(tree)
    r = rotate_root_ca(tree, 10950, root_runner=_fake_root_runner(),
                       signer=_fake_signer(fail_on="d1.example.com"))
    assert not r["ok"]
    assert "回滚" in r["msg"], f"失败信息未说明已回滚: {r['msg']}"
    assert _snapshot(tree) == before, "失败后未完全回滚"


def test_rotate_reports_which_domain_failed(tree):
    r = rotate_root_ca(tree, 10950, root_runner=_fake_root_runner(),
                       signer=_fake_signer(fail_on="d1.example.com"))
    assert "d1.example.com" in r["msg"], f"未指明是哪个域名失败: {r['msg']}"


def test_rotate_success_resigns_every_target(tree):
    r = rotate_root_ca(tree, 10950, root_runner=_fake_root_runner(),
                       signer=_fake_signer(), dist_dir=None)
    assert r["ok"], r.get("msg")
    assert r["resigned"] == 2
    for cn in ("d0.example.com", "d1.example.com"):
        with open(os.path.join(tree, "certs", f"{cn}.crt")) as f:
            assert f.read() == f"RESIGNED {cn}"


def test_rotate_leaves_no_backup_dir_behind(tree):
    """成功后备份目录要清掉 —— 它含全部私钥，不该长期躺在 ca/ 下。"""
    rotate_root_ca(tree, 10950, root_runner=_fake_root_runner(),
                   signer=_fake_signer(), dist_dir=None)
    leftovers = [n for n in os.listdir(tree) if n.startswith(".rotate-")]
    assert leftovers == [], f"备份目录未清理: {leftovers}"


def test_rotate_keeps_backup_when_rollback_fails(tree, monkeypatch):
    """回滚都失败时备份必须留着 —— 那是最后的救命稻草。"""
    import backend.rootca as rc

    def boom(*a, **kw):
        raise OSError("模拟恢复失败")

    monkeypatch.setattr(rc, "_restore", boom)
    rotate_root_ca(tree, 10950, root_runner=_fake_root_runner(),
                   signer=_fake_signer(fail_on="d1.example.com"))
    leftovers = [n for n in os.listdir(tree) if n.startswith(".rotate-")]
    assert leftovers, "回滚失败却把备份删了，旧根将永久丢失"


# ---------- 发布 ----------

def test_rotate_publishes_new_root(tree, dist):
    r = rotate_root_ca(tree, 10950, root_runner=_fake_root_runner(),
                       signer=_fake_signer(), dist_dir=dist)
    assert r["ok"], r.get("msg")
    with open(os.path.join(dist, "tproxy-ca.crt")) as f:
        assert f.read() == "NEW ROOT CRT"
    assert not os.path.exists(os.path.join(dist, ".tproxy-ca.crt.tmp")), \
        "临时文件残留"


def test_publish_failure_is_reported_not_swallowed(tree):
    """发布失败必须显式说出来。

    换了根却没发布 = 客户端拿不到新根 = 全网失联，
    而换根本身是成功的 —— 这种「一半成功」最容易被当成全成功。
    """
    r = rotate_root_ca(tree, 10950, root_runner=_fake_root_runner(),
                       signer=_fake_signer(),
                       dist_dir="/nonexistent-dist-dir-xyz")
    assert r["ok"], "发布失败不该让换根本身算失败"
    assert "发布" in r["msg"], f"未提示发布失败: {r['msg']}"
    assert "手工" in r["msg"] or "手动" in r["msg"]


def test_publish_root_ca_missing_source(tmp_path):
    ok, msg = publish_root_ca(str(tmp_path), str(tmp_path))
    assert not ok
    assert msg


# ---------- 真脚本集成：确认走的是真 gen-ca.sh ----------

def test_rotate_with_real_scripts(tmp_path, dist):
    """不注入替身，跑真的 gen-ca.sh 与 gen-cert.sh。

    替身能证明编排对，证明不了「真脚本接受这些参数」——
    比如 DAYS 环境变量没被 gen-ca.sh 认，替身是发现不了的。
    """
    tree = _make_tree(tmp_path, n_certs=1)
    old_root = _fingerprint(os.path.join(tree, "tproxy-ca.crt"))

    r = rotate_root_ca(tree, 10950, dist_dir=dist)
    assert r["ok"], r.get("msg")

    new_root = _fingerprint(os.path.join(tree, "tproxy-ca.crt"))
    assert new_root != old_root, "根 CA 没换"

    # 新根的有效期必须真的变长，而不是沿用旧值
    end = subprocess.run(
        ["openssl", "x509", "-in", os.path.join(tree, "tproxy-ca.crt"),
         "-noout", "-enddate"], capture_output=True, text=True).stdout
    year = int(end.strip().split()[-2])
    assert year >= 2056, f"新根 CA 到期年仍是 {year}，DAYS 未生效"

    # 叶子必须是新根签的
    v = subprocess.run(
        ["openssl", "verify", "-CAfile", os.path.join(tree, "tproxy-ca.crt"),
         os.path.join(tree, "certs", "d0.example.com.crt")],
        capture_output=True, text=True)
    assert v.returncode == 0, f"重签后的叶子链不上新根: {v.stdout}{v.stderr}"

    # 附加域名不能在重签中丢掉
    ext = subprocess.run(
        ["openssl", "x509", "-in", os.path.join(tree, "certs", "d0.example.com.crt"),
         "-noout", "-ext", "subjectAltName"], capture_output=True, text=True).stdout
    assert "alt.example.com" in ext, f"重签后 SAN 丢了: {ext}"
