"""TProxy 管理界面后端。

认证：接入 yz-login 统一登录（SSO），且**只允许管理员进入**。
     此前管理端没有任何认证，只能靠绑回环地址保护；接入 SSO 后才可以
     安全地对内网其他客户端开放。

所有路径通过环境变量注入，便于测试与部署分离。
"""
import os
import secrets

from flask import (Flask, jsonify, make_response, redirect, request,
                   send_from_directory, session, url_for)

from backend import sso
from backend.cache_stats import all_cache_usage
from backend.certmgr import DEFAULT_DAYS, preview_sign, sign_cert
from backend.certs import list_certs, root_ca_info
from backend.config_read import parse_dnsmasq_rules, parse_nginx_servers
from backend.hitrate import all_hitrate
from backend.confd import add_conf, list_confs, read_conf, write_conf
from backend.rootca import (CONFIRM_WORD, DEFAULT_ROOT_DAYS, preview_rotate,
                            rotate_root_ca)
from backend.upstream import CATEGORIES, apply_upstream, preview_upstream
from version import (DEFAULT_CHANGELOG, asset_version, get_version,
                     read_changelog, version_from_changelog)

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

DEFAULTS = {
    "TPROXY_CACHE_BASE": "/mnt/HDD/tproxy-cache",
    "TPROXY_DNSMASQ_CONF": "/opt/TProxy/proxy/dnsmasq/dnsmasq.conf",
    "TPROXY_CONF_D": "/opt/TProxy/proxy/tengine/conf.d",
    "TPROXY_CERTS_DIR": "/opt/TProxy/proxy/ca/certs",
    "TPROXY_LOG_DIR": "/var/log/nginx",
    # 配置根目录 —— 新增上游时要改这里面的 dnsmasq/conf.d/ca
    "TPROXY_PROXY_DIR": "/opt/TProxy/proxy",
    # 版本号的唯一来源。容器内由 compose 挂载（:ro）；
    # 本机直跑时该路径就是仓库根的同名文件。
    "TPROXY_CHANGELOG": DEFAULT_CHANGELOG,
    # 客户端接入脚本的下载目录（NAS 上的软件发布目录）。
    # 容器内是 compose 挂进来的挂载点，宿主路径由 .env 的 DIST_DIR 决定。
    # 换根后新根 CA 要发布到这里，否则客户端拿不到它。
    "TPROXY_DIST_DIR": "/opt/TProxy/dist",
    "YZ_LOGIN_URL": "http://192.168.0.8",
    # 用应用引用而非硬编码回调 URL：在 yz-login 后台改回调地址时自动跟随
    "YZ_APP_REF": "id:55",
}

# 无需登录即可访问的路径
PUBLIC_PATHS = {"/login", "/callback", "/logout", "/healthz"}


def _load_secret_key():
    """取得 session 签名密钥。

    优先级：环境变量 → 数据目录中的已存密钥 → 新生成并持久化。

    持久化这一步是必须的：若每次启动随机生成，容器一重启所有人都会掉登录态；
    多副本部署时各副本的 session 也互不认。而写进数据目录既能持久、
    又不会随代码入库。
    """
    env = os.environ.get("MANAGER_SECRET_KEY", "").strip()
    if env:
        return env

    # 独立的状态目录（可写）——缓存目录是只读挂载的，不能往那里写
    state_dir = os.environ.get("MANAGER_STATE_DIR", "/var/lib/tproxy-manager")
    path = os.path.join(state_dir, "secret_key")

    try:
        with open(path, encoding="utf-8") as f:
            saved = f.read().strip()
            if saved:
                return saved
    except OSError:
        pass

    generated = secrets.token_hex(32)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(generated)
        os.chmod(path, 0o600)
    except OSError:
        # 无法落盘（如只读挂载）时仍可用，但重启后登录态会失效
        pass
    return generated


def create_app():
    app = Flask(__name__, static_folder=STATIC_DIR)
    app.secret_key = _load_secret_key()

    def cfg(key):
        return os.environ.get(key, DEFAULTS[key])

    def ca_dir():
        return os.path.join(cfg("TPROXY_PROXY_DIR"), "ca")

    def dist_dir():
        """分发目录。显式配成空串表示「本环境不发布」，而不是回退到默认路径 ——
        否则测试或本地跑会把生产用的分发目录当成目标。"""
        return os.environ.get("TPROXY_DIST_DIR", DEFAULTS["TPROXY_DIST_DIR"]).strip()

    def sso_redirect():
        """直接跳 yz-login，不再经本地 /login 中转一次。"""
        target = f"{cfg('YZ_LOGIN_URL').rstrip('/')}/login?from={cfg('YZ_APP_REF')}"
        return redirect(target)

    # ---- 认证：所有非公开路径都要求已登录 ----
    @app.before_request
    def require_login():
        path = request.path
        if path in PUBLIC_PATHS or path.startswith("/static/"):
            return None
        if session.get("user"):
            return None
        # 带 ticket 的请求必须放行到视图函数 —— 它就是登录回调本身。
        # 若在这里拦掉，/  会直接跳回 SSO，ticket 永远处理不到（死循环）。
        if request.args.get("ticket"):
            return None
        # API 返回 401 而非重定向：让调用方能明确区分「未登录」与「无权限」
        if path.startswith("/api/"):
            return jsonify({"ok": False, "msg": "未登录"}), 401
        return sso_redirect()

    # ---- SSO ----
    @app.route("/login")
    def login():
        return sso_redirect()

    @app.route("/callback")
    def callback():
        ticket = request.args.get("ticket", "").strip()
        if not ticket:
            return "缺少 ticket 参数", 400

        user = sso.verify_ticket(cfg("YZ_LOGIN_URL"), ticket)
        if not user:
            # ticket 无效/过期/网络异常 —— 回登录页重来
            return redirect(url_for("login"))

        if not sso.is_admin(user):
            # 明确告知原因，而不是假装登录失败：
            # 否则用户会反复重试，也不知道该找谁开通权限
            return (
                "<!DOCTYPE html><html lang='zh-CN'><head><meta charset='utf-8'>"
                "<title>无权访问</title></head><body style='font-family:system-ui;"
                "max-width:32em;margin:15vh auto;line-height:1.7;color:#333'>"
                "<h1 style='font-size:18px'>无权访问 TProxy 管理端</h1>"
                "<p>你的账号已登录成功，但不是管理员，因此无法进入管理界面。</p>"
                "<p style='color:#666;font-size:14px'>如需访问，请联系管理员在 "
                "yz-login 中为你的账号开通管理员权限。</p>"
                "<p><a href='/logout'>退出</a></p></body></html>",
                403,
            )

        # 只保留必要字段；不回存 is_admin —— 授权每次登录时判定，
        # 不依赖 session 中的旧值
        session["user"] = {
            "id": user.get("id"),
            "username": user.get("username"),
            "display_name": user.get("display_name"),
        }
        return redirect(url_for("index"))

    @app.route("/logout")
    def logout():
        session.clear()
        return redirect(url_for("login"))

    @app.route("/healthz")
    def healthz():
        # 供容器健康检查使用，不需要登录
        return jsonify({"status": "ok"})

    # ---- 页面与 API ----
    def render_index():
        """把静态资源指纹注入 index.html。

        做成替换而非让人手改 `?v=`：忘改的后果是浏览器一直跑旧 app.js，
        而现象是「新功能没生效」—— 几乎没人会往缓存上想。
        每次请求都读盘：文件很小，且容器重建后就该拿到最新内容。
        """
        with open(os.path.join(STATIC_DIR, "index.html"), encoding="utf-8") as f:
            html = f.read()
        return html.replace("__ASSET_V__", asset_version())

    @app.route("/")
    def index():
        # 兼容两种回调配置：若 yz-login 中该应用的 URL 配成首页而非 /callback，
        # 登录后会跳回 /?ticket=xxx。此处一并处理，否则会陷入
        # 「未登录 → 跳 SSO → 跳回带 ticket 的首页 → 又不处理 ticket → 再跳 SSO」的死循环。
        ticket = request.args.get("ticket")
        if ticket and not session.get("user"):
            return callback()
        resp = make_response(render_index())
        # index.html 自己不能被浏览器缓存：它内部带着静态资源的指纹，
        # 它被缓存住指纹就跟着一起过期，整套自动失效也就白做了。
        resp.headers["Cache-Control"] = "no-cache, must-revalidate"
        return resp

    @app.route("/api/status")
    def status():
        return jsonify({
            "status": "ok",
            "version": get_version(),
            # 构建指纹：不升版本号也能分辨「部署的是不是新版」
            "build": asset_version(),
            "user": session.get("user"),
        })

    @app.route("/api/changelog")
    def changelog():
        """整份更新日志，供界面点版本号时展示。

        版本号也一并返回（取自同一文件），使得「显示 0.2.7 但日志里最新是 0.2.8」
        这种不一致在界面上直接可见，而不是靠人去比对。
        """
        path = cfg("TPROXY_CHANGELOG")
        return jsonify({
            "markdown": read_changelog(path),
            "version": version_from_changelog(path) or get_version(),
        })

    @app.route("/api/cache")
    def cache():
        return jsonify({"types": all_cache_usage(cfg("TPROXY_CACHE_BASE"))})

    @app.route("/api/rules")
    def rules():
        return jsonify({
            "rules": parse_dnsmasq_rules(cfg("TPROXY_DNSMASQ_CONF")),
            "servers": parse_nginx_servers(cfg("TPROXY_CONF_D")),
        })

    @app.route("/api/certs")
    def certs():
        return jsonify({
            "certs": list_certs(cfg("TPROXY_CERTS_DIR")),
            # 根 CA 单独返回：它的失效方式与域名证书完全不同 ——
            # 域名证书过期只影响一个域名，根 CA 到期会让所有域名同时失效，
            # 且每台客户端都必须重新安装。dnsmasq 与 tengine 的界面都要能一眼看到它。
            "root_ca": root_ca_info(ca_dir()),
            "default_days": DEFAULT_DAYS,
            "root_default_days": DEFAULT_ROOT_DAYS,
        })

    # ---- 更换根 CA ----
    # 全系统破坏性最强的操作：所有域名证书立即失效、每台客户端都要重装。
    # 故除了登录校验，还要求显式确认词 —— 且确认词在服务端校验，
    # 前端那个输入框只是提示，不是安全边界。
    @app.route("/api/rootca/preview", methods=["POST"])
    def rootca_preview():
        d = request.get_json(silent=True) or {}
        return jsonify(preview_rotate(ca_dir(),
                                      d.get("days", DEFAULT_ROOT_DAYS),
                                      dist_dir()))

    @app.route("/api/rootca/apply", methods=["POST"])
    def rootca_apply():
        d = request.get_json(silent=True) or {}
        if (d.get("confirm") or "").strip() != CONFIRM_WORD:
            return jsonify({
                "ok": False,
                "msg": f"未确认。此操作会替换根 CA 并重签全部域名证书，"
                       f"需在确认框输入 {CONFIRM_WORD}",
            })
        return jsonify(rotate_root_ca(ca_dir(),
                                      d.get("days", DEFAULT_ROOT_DAYS),
                                      dist_dir=dist_dir()))

    # ---- 签发 / 重新签发域名证书 ----
    # 会【写正在使用的证书文件】，故只走 POST，且依赖 before_request 的登录校验。
    @app.route("/api/certs/preview", methods=["POST"])
    def certs_preview():
        d = request.get_json(silent=True) or {}
        return jsonify(preview_sign(d.get("domain", ""), d.get("sans", ""),
                                    d.get("days", DEFAULT_DAYS), ca_dir()))

    @app.route("/api/certs/apply", methods=["POST"])
    def certs_apply():
        d = request.get_json(silent=True) or {}
        return jsonify(sign_cert(d.get("domain", ""), d.get("sans", ""),
                                 d.get("days", DEFAULT_DAYS), ca_dir()))

    @app.route("/api/hitrate")
    def hitrate():
        return jsonify({"hitrate": all_hitrate(cfg("TPROXY_LOG_DIR"))})

    # ---- 新增上游 ----
    # 这两个端点会【写生产配置】，故只走 POST，且依赖 before_request 的登录校验。
    @app.route("/api/upstream/preview", methods=["POST"])
    def upstream_preview():
        d = request.get_json(silent=True) or {}
        return jsonify(preview_upstream(
            d.get("domain", ""), d.get("category", ""), cfg("TPROXY_PROXY_DIR")))

    @app.route("/api/upstream/apply", methods=["POST"])
    def upstream_apply():
        d = request.get_json(silent=True) or {}
        r = apply_upstream(
            d.get("domain", ""), d.get("category", ""), cfg("TPROXY_PROXY_DIR"))
        # 配置改动要重启容器才生效（:ro 挂载 + bind mount 的 inode 特性，
        # 仅 nginx -s reload 不会重新挂载），故把命令一并返回给界面显示
        if r.get("needs_restart"):
            r["restart_hint"] = "cd /opt/TProxy/proxy && docker compose restart dnsmasq tengine"
        return jsonify(r)

    @app.route("/api/upstream/categories")
    def upstream_categories():
        return jsonify({"categories": sorted(CATEGORIES.keys())})

    # ---- 分流配置（conf.d）读写 ----
    def confd_dir():
        return os.path.join(cfg("TPROXY_PROXY_DIR"), "tengine", "conf.d")

    @app.route("/api/confd")
    def confd_list():
        return jsonify({"files": list_confs(confd_dir())})

    @app.route("/api/confd", methods=["POST"])
    def confd_create():
        """新建分流配置（带模板）。"""
        d = request.get_json(silent=True) or {}
        ok, msg = add_conf(confd_dir(), d.get("name", ""))
        return jsonify({"ok": ok, "msg": msg,
                        "restart_hint": "cd /opt/TProxy/proxy && docker compose restart tengine"})

    @app.route("/api/confd/<name>", methods=["GET", "POST"])
    def confd_item(name):
        """读或保存单个分流配置。

        ⚠️ 容器内没有 nginx，无法做真正的语法校验，只做结构性检查 ——
        保存前请留意界面上的这条提示。
        """
        if request.method == "GET":
            content = read_conf(confd_dir(), name)
            if content is None:
                return jsonify({"ok": False, "msg": "文件不存在或名字非法"}), 404
            return jsonify({"ok": True, "name": name, "content": content})

        d = request.get_json(silent=True) or {}
        ok, msg = write_conf(confd_dir(), name, d.get("content", ""))
        return jsonify({"ok": ok, "msg": msg,
                        "restart_hint": "cd /opt/TProxy/proxy && docker compose restart tengine"})

    return app


if __name__ == "__main__":
    host = os.environ.get("MANAGER_BIND", "0.0.0.0")
    port = int(os.environ.get("MANAGER_PORT", "5557"))
    create_app().run(host=host, port=port)
