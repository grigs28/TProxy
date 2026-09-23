"""TProxy 管理界面后端。

所有路径通过环境变量注入，便于测试与部署分离：
测试可在临时目录上运行，不触碰真实配置与缓存。
"""
import os

from flask import Flask, jsonify, send_from_directory

from backend.cache_stats import all_cache_usage
from backend.certs import list_certs
from backend.config_read import parse_dnsmasq_rules, parse_nginx_servers

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

DEFAULTS = {
    "TPROXY_CACHE_BASE": "/mnt/HDD/tproxy-cache",
    "TPROXY_DNSMASQ_CONF": "/opt/TProxy/proxy/dnsmasq/dnsmasq.conf",
    "TPROXY_CONF_D": "/opt/TProxy/proxy/tengine/conf.d",
    "TPROXY_CERTS_DIR": "/opt/TProxy/proxy/ca/certs",
}


def create_app():
    app = Flask(__name__, static_folder=STATIC_DIR)

    def cfg(key):
        return os.environ.get(key, DEFAULTS[key])

    @app.route("/")
    def index():
        return send_from_directory(STATIC_DIR, "index.html")

    @app.route("/api/status")
    def status():
        return jsonify({"status": "ok"})

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

    return app


if __name__ == "__main__":
    # 仅绑定回环：管理界面通过 SSH 隧道或反向代理访问，
    # 不直接暴露到内网（无认证机制时尤其重要）
    create_app().run(host="127.0.0.1", port=5557)
