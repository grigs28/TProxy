"""TProxy 管理界面后端。

认证：接入 yz-login 统一登录（SSO），且**只允许管理员进入**。
     此前管理端没有任何认证，只能靠绑回环地址保护；接入 SSO 后才可以
     安全地对内网其他客户端开放。

所有路径通过环境变量注入，便于测试与部署分离。
"""
import os
import secrets

from flask import (Flask, jsonify, redirect, request, send_from_directory,
                   session, url_for)

from backend import sso
from backend.cache_stats import all_cache_usage
from backend.certs import list_certs
from backend.config_read import parse_dnsmasq_rules, parse_nginx_servers
from backend.hitrate import all_hitrate

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

DEFAULTS = {
    "TPROXY_CACHE_BASE": "/mnt/HDD/tproxy-cache",
    "TPROXY_DNSMASQ_CONF": "/opt/TProxy/proxy/dnsmasq/dnsmasq.conf",
    "TPROXY_CONF_D": "/opt/TProxy/proxy/tengine/conf.d",
    "TPROXY_CERTS_DIR": "/opt/TProxy/proxy/ca/certs",
    "TPROXY_LOG_DIR": "/var/log/nginx",
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
    @app.route("/")
    def index():
        return send_from_directory(STATIC_DIR, "index.html")

    @app.route("/api/status")
    def status():
        return jsonify({"status": "ok", "user": session.get("user")})

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
        return jsonify({"certs": list_certs(cfg("TPROXY_CERTS_DIR"))})

    @app.route("/api/hitrate")
    def hitrate():
        return jsonify({"hitrate": all_hitrate(cfg("TPROXY_LOG_DIR"))})

    return app


if __name__ == "__main__":
    host = os.environ.get("MANAGER_BIND", "0.0.0.0")
    port = int(os.environ.get("MANAGER_PORT", "5557"))
    create_app().run(host=host, port=port)
