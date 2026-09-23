"""根 CA 的生成与轮换。

这是全系统破坏性最强的操作，没有之一：

* 换根 = 换信任锚 → **所有**域名证书立即失效（旧叶子链在新根上是废的）
* 每台客户端都必须重新安装根 CA
* 必须同时做，没有灰度窗口

所以每一步都对着「出错会怎样」设计：

  1. **代价先摆出来**。预览列出会被重签的每一个域名。
     不能让人点下去才知道影响面。
  2. **执行前整份备份**（tproxy-ca.crt/key + certs/ 下全部证书与私钥）。
     旧根私钥若丢了，连退回原状都做不到。
  3. **失败回滚**，回滚不成功就把备份留在原地 —— 那是最后的救命稻草。
  4. **成功后必须发布**到分发目录。换了根却没发布，客户端拿不到新根，
     症状同样是全网失联，而换根本身是「成功」的 ——
     这种「一半成功」最容易被当成全成功，故发布结果单独报出来。

重签清单以 `ca/certs/*.crt` 为准，而不是 `ca/domains.txt`：前者才是 tengine
实际在用的那批，后者只是一份记录，可能有陈旧条目或漏记。每张证书的 SAN
从证书本身读回，保证重签后与原来完全一致。
"""
import os
import shutil
import subprocess
import time

from backend.certmgr import DEFAULT_DAYS as DEFAULT_LEAF_DAYS
from backend.certmgr import parse_days, sign_cert
from backend.certs import cert_info

#: 根 CA 默认有效期。刻意远长于叶子证书：叶子到期重签即可（客户端无感），
#: 根 CA 换一次要动每一台客户端。根长叶短，客户端才只需要在最后动一次。
DEFAULT_ROOT_DAYS = 10950          # 约 30 年
MIN_ROOT_DAYS = 365
MAX_ROOT_DAYS = 36500              # 100 年

#: 执行换根时要求输入的确认词。服务端也要校验 —— 前端那个输入框不是安全边界。
CONFIRM_WORD = "REPLACE"

_BACKUP_PREFIX = ".rotate-"


def validate_root_days(days):
    n = parse_days(days)
    if n is None:
        return False, "有效期必须是整数天数", None
    if not MIN_ROOT_DAYS <= n <= MAX_ROOT_DAYS:
        return False, f"有效期需在 {MIN_ROOT_DAYS} - {MAX_ROOT_DAYS} 天之间", None
    return True, "", n


def _collect_targets(certs_dir):
    """要重签的域名：`(CN, [附加域名])`，按文件名排序。

    CN 取**文件名**而不是证书里的 subject —— tengine 是按
    `$ssl_server_name.crt` 找文件的，文件名才是决定用不用得上的那个键。
    """
    out = []
    if not os.path.isdir(certs_dir):
        return out
    for name in sorted(os.listdir(certs_dir)):
        if not name.endswith(".crt"):
            continue
        cn = name[:-4]
        info = cert_info(os.path.join(certs_dir, name))
        sans = [s for s in (info["sans"] if info else [cn]) if s != cn]
        out.append((cn, sans))
    return out


def _copy_preserve(src, dst):
    """连属主一起复制。

    属主必须保留：容器里以 root 运行，若把 root 属主的新文件写回
    `ca/certs`，目标机上 `rsync --inplace` 就再也写不进去，
    **整个同步会失败**（同 gen-cert.sh 里的说明）。
    """
    shutil.copy2(src, dst)
    try:
        st = os.stat(src)
        os.chown(dst, st.st_uid, st.st_gid)
    except OSError:
        pass


def _backup(ca_dir):
    """整份备份根 CA 与全部域名证书（含私钥）。失败返回 None。"""
    dst = os.path.join(
        ca_dir, _BACKUP_PREFIX + time.strftime("%Y%m%d-%H%M%S"))
    try:
        os.makedirs(os.path.join(dst, "certs"), exist_ok=True)
        for name in ("tproxy-ca.crt", "tproxy-ca.key", "tproxy-ca.srl"):
            src = os.path.join(ca_dir, name)
            if os.path.exists(src):
                _copy_preserve(src, os.path.join(dst, name))
        certs_src = os.path.join(ca_dir, "certs")
        if os.path.isdir(certs_src):
            for name in os.listdir(certs_src):
                if name.endswith((".crt", ".key")):
                    _copy_preserve(os.path.join(certs_src, name),
                                   os.path.join(dst, "certs", name))
    except OSError:
        return None
    return dst


def _restore(backup, ca_dir):
    """从备份还原。抛异常表示还原失败 —— 调用方要据此保留备份。"""
    for name in ("tproxy-ca.crt", "tproxy-ca.key", "tproxy-ca.srl"):
        src = os.path.join(backup, name)
        if os.path.exists(src):
            _copy_preserve(src, os.path.join(ca_dir, name))
    certs_bak = os.path.join(backup, "certs")
    if os.path.isdir(certs_bak):
        for name in os.listdir(certs_bak):
            _copy_preserve(os.path.join(certs_bak, name),
                           os.path.join(ca_dir, "certs", name))


def _run_gen_ca(days, ca_dir):
    """调用 gen-ca.sh。DAYS 与 FORCE 经环境变量传入。"""
    script = os.path.join(ca_dir, "gen-ca.sh")
    if not os.path.exists(script):
        return 1, "", f"缺少脚本：{script}"
    env = dict(os.environ)
    env["DAYS"] = str(days)
    env["FORCE"] = "1"
    r = subprocess.run([script], cwd=ca_dir, env=env,
                       capture_output=True, text=True, timeout=600)
    return r.returncode, r.stdout, r.stderr


def publish_root_ca(ca_dir, dist_dir):
    """把根 CA 发布到分发目录（客户端脚本从这里下载）。返回 (ok, msg)。

    先写临时文件再原子改名：客户端可能正好在读取，
    半截的 CA 文件会让它把一张废证书装进信任库，
    之后所有 HTTPS 报错，却查不到是分发环节的问题。
    """
    src = os.path.join(ca_dir, "tproxy-ca.crt")
    if not os.path.exists(src):
        return False, f"找不到 {src}"
    if not dist_dir or not os.path.isdir(dist_dir):
        return False, f"分发目录不存在或未挂载：{dist_dir}"

    dst = os.path.join(dist_dir, "tproxy-ca.crt")
    tmp = os.path.join(dist_dir, ".tproxy-ca.crt.tmp")
    try:
        shutil.copyfile(src, tmp)
        os.replace(tmp, dst)
    except OSError as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False, f"{e}"
    return True, f"已发布到 {dst}"


def preview_rotate(ca_dir, days, dist_dir=None):
    """换根将要做的事。只读，不碰任何文件。"""
    ok, err, n = validate_root_days(days)
    if not ok:
        return {"ok": False, "msg": err}

    certs_dir = os.path.join(ca_dir, "certs")
    targets = _collect_targets(certs_dir)
    if not targets:
        return {"ok": False,
                "msg": "ca/certs 下没有可重签的域名证书 —— 换根会让它们全部失效，"
                       "故拒绝执行。请先确认证书目录是否正确。"}

    info = cert_info(os.path.join(ca_dir, "tproxy-ca.crt"))
    cur = (f"当前根 CA 到期 {info['not_after']}（剩余 {info['days_left']} 天）"
           if info else "当前没有根 CA")
    names = [cn for cn, _ in targets]

    changes = [
        {
            "file": "ca/tproxy-ca.crt · tproxy-ca.key",
            "action": "生成新根 CA（换掉信任锚）",
            "diff": f"+ 新 4096 位密钥 · 有效期 {n} 天（约 {n // 365} 年）",
            "desc": cur,
        },
        {
            "file": "ca/certs/*",
            "action": f"重签全部 {len(names)} 张域名证书",
            "diff": "  " + "  ".join(names[:6]) + ("  …" if len(names) > 6 else ""),
            "desc": "旧叶子证书链在旧根上，换根后全部作废，必须一起重签。"
                    "附加域名会从原证书读回，不会丢。",
        },
    ]
    if dist_dir:
        changes.append({
            "file": dist_dir,
            "action": "发布新根 CA",
            "diff": "+ tproxy-ca.crt",
            "desc": "客户端接入脚本从这里下载根 CA。漏发布 = 客户端拿不到新根，"
                    "症状与「服务挂了」一模一样。",
        })

    return {
        "ok": True,
        "msg": "",
        "days": n,
        "targets": names,
        "leaf_days": DEFAULT_LEAF_DAYS,
        "needs_restart": False,
        "changes": changes,
        # 界面用它显示确认框的提示词，避免两边各写一份字面量而分叉
        "confirm_word": CONFIRM_WORD,
        "note": "换根会立即中断所有客户端：它们信任的还是旧根。"
                "执行后每台客户端都要重新运行接入脚本"
                "（脚本会比对指纹，自动换成新根）。",
    }


def rotate_root_ca(ca_dir, days, leaf_days=None, dist_dir=None,
                   root_runner=None, signer=None):
    """生成新根 CA 并重签全部域名证书。失败整份回滚。

    返回 `{ok, msg, resigned, days, published}`。
    """
    ok, err, n = validate_root_days(days)
    if not ok:
        return {"ok": False, "msg": err}
    leaf_days = leaf_days or DEFAULT_LEAF_DAYS

    certs_dir = os.path.join(ca_dir, "certs")
    targets = _collect_targets(certs_dir)
    if not targets:
        return {"ok": False, "msg": "ca/certs 下没有可重签的域名证书，已中止"}

    backup = _backup(ca_dir)
    if backup is None:
        return {"ok": False,
                "msg": "备份失败。没有备份的换根无法回滚，故已中止"}

    try:
        rc, out, errout = (root_runner or _run_gen_ca)(n, ca_dir)
        if rc != 0:
            raise RuntimeError(
                "生成新根 CA 失败：" + (errout or out or "").strip()[:200])

        failed = []
        for cn, sans in targets:
            if signer is None:
                r = sign_cert(cn, sans, leaf_days, ca_dir)
            else:
                r = signer(cn, sans, leaf_days, ca_dir)
            if not r.get("ok"):
                failed.append(f"{cn}（{r.get('msg')}）")
        if failed:
            raise RuntimeError(
                f"{len(failed)} 个域名重签失败：" + "；".join(failed[:3]))

        published, pub_msg = None, ""
        if dist_dir:
            published, pub_msg = publish_root_ca(ca_dir, dist_dir)
    except Exception as e:                       # noqa: BLE001 —— 统一转成可展示的失败
        try:
            _restore(backup, ca_dir)
            shutil.rmtree(backup, ignore_errors=True)
            tail = "已回滚到原根 CA"
        except Exception:                        # noqa: BLE001
            # 回滚都失败了，备份是唯一的救命稻草，绝不能删
            tail = f"⚠️ 回滚也失败，原根 CA 的备份保留在 {backup}"
        return {"ok": False, "msg": f"换根失败：{e}。{tail}"}

    shutil.rmtree(backup, ignore_errors=True)

    msg = f"已更换根 CA（{n} 天），并重签 {len(targets)} 张域名证书"
    if dist_dir and not published:
        msg += (f"。⚠️ 发布到分发目录失败：{pub_msg} —— "
                f"客户端会拿不到新根，请手工发布")
    return {
        "ok": True,
        "msg": msg,
        "days": n,
        "resigned": len(targets),
        "published": published,
        "needs_restart": False,
    }
