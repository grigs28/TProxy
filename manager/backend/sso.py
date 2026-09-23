"""yz-login SSO 对接。

流程（对应 `yz-login/docs/integration-guide.md`）：
    浏览器 → 管理端 /login → 302 到 {YZ_LOGIN}/login?from=id:55
           → 用户登录 → 302 回 /callback?ticket=xxx
           → 本模块调 {YZ_LOGIN}/api/ticket/verify 换取用户信息
    ticket 一次性、有效期 5 分钟（由 yz-login 保证）。
"""
import requests


class SSOError(Exception):
    """向 yz-login 验证 ticket 时发生的错误。"""


def verify_ticket(yz_login_url, ticket, timeout=10):
    """用 ticket 换取用户信息。

    返回 yz-login 的响应字典（含 `is_admin`），失败返回 None。
    网络异常与非法响应都按「验证失败」处理 —— 认证路径上任何异常
    都不应成为放行的理由。
    """
    if not ticket:
        return None

    url = f"{yz_login_url.rstrip('/')}/api/ticket/verify"
    try:
        resp = requests.get(url, params={"ticket": ticket}, timeout=timeout)
    except requests.RequestException:
        return None

    if resp.status_code != 200:
        return None

    try:
        body = resp.json()
    except ValueError:
        return None

    if not isinstance(body, dict) or not body.get("ok"):
        return None
    return body


def is_admin(user):
    """严格判定管理员 —— fail-closed。

    `is_admin` 经 JSON 传输后可能是 0 / "0" / false / true / 1 / "1"
    等多种形态，**不能用真值判断**：Python 里 `"0"` 是真值，会直接放行
    一个普通用户。缺失该字段同样按非管理员处理。
    """
    if not isinstance(user, dict):
        return False

    v = user.get("is_admin")
    if isinstance(v, bool):
        return v is True
    if isinstance(v, int):
        return v == 1
    if isinstance(v, str):
        return v.strip() == "1"
    return False
