"""只读解析 TProxy 的 nginx / dnsmasq 配置。

刻意不做完整语法解析 —— 只提取界面需要的字段。理由：
配置格式微调不应导致解析器大面积失效；而旧 proxy-manager 的教训是
「解析器与格式不符时静默返回空」比报错更危险。

因此这里的解析规则保持窄而明确，并逐条测试。
"""
import os
import re

# address=/<域名>/<目标>/
_DNSMASQ_ADDRESS = re.compile(r"^\s*address=/([^/]+)/([^/\s]+)/?\s*$")


def parse_dnsmasq_rules(conf_path):
    """提取劫持规则（address= 行）。

    注意区分：`server=` 是上游 DNS，`host-record=` 是内网域名解析，
    二者都不是劫持规则，不应混入。
    """
    rules = []
    if not os.path.exists(conf_path):
        return rules
    with open(conf_path, encoding="utf-8") as f:
        for line in f:
            m = _DNSMASQ_ADDRESS.match(line)
            if m:
                rules.append({
                    "domain": m.group(1),
                    "target": m.group(2),
                    "type": "address",
                })
    return rules


def _strip_comments(text):
    """去掉整行注释。

    必须做：注释里的示例配置若被解析，界面会显示根本不存在的规则。
    """
    return re.sub(r"^\s*#.*$", "", text, flags=re.M)


def parse_nginx_servers(confd_dir):
    """提取每个 conf.d/*.conf 里的 server_name / listen / proxy_cache。"""
    servers = []
    if not os.path.isdir(confd_dir):
        return servers

    for name in sorted(os.listdir(confd_dir)):
        if not name.endswith(".conf"):
            continue
        with open(os.path.join(confd_dir, name), encoding="utf-8") as f:
            text = _strip_comments(f.read())

        # 要求 server_name 前有边界：否则 `proxy_ssl_server_name on;` 里的
        # 子串会被命中，把 "on" 混进域名列表（本项目每个含该指令的 conf 都会触发）
        names = []
        for m in re.finditer(r"(?:^|[\s;{}])server_name\s+([^;]+);", text, re.M):
            names.extend(m.group(1).split())
        if not names:
            continue

        # `proxy_cache off;` 不是缓存区名 —— 它表示该路径不走 nginx 缓存
        # （如 git/registry 由各自后端自行缓存）。原样显示会让人误以为
        # 存在一个叫 "off" 的 zone。
        cache = None
        m = re.search(r"proxy_cache\s+([^;\s]+);", text)
        if m and m.group(1) != "off":
            cache = m.group(1)

        servers.append({
            "file": name,
            "server_name": names,
            "listen": sorted(set(re.findall(r"listen\s+(\d+)", text))),
            "cache_zone": cache,
        })
    return servers
