#!/usr/bin/env python3
"""
配置管理模块
"""
import os
import re
from typing import Dict, List, Optional, Tuple


class ConfigController:
    """配置文件控制器"""

    # 配置分组定义
    CONFIG_GROUPS = {
        'network': {
            'name': '网络配置',
            'icon': '🌐',
            'keys': ['NETWORK_MODE', 'HOST_IP']
        },
        'ports': {
            'name': '端口配置',
            'icon': '🔌',
            'keys': ['PROXY_MANAGER_PORT', 'DNSMASQ_HOST_PORT', 'PROXY_HOST_PORT', 'STATUS_HOST_PORT']
        },
        'cache': {
            'name': '缓存配置',
            'icon': '💾',
            'keys': ['CACHE_BASE', 'CACHE_MAX_SIZE', 'CACHE_KEYS_ZONE',
                    'CACHE_INACTIVE', 'CACHE_MIN_FREE', 'CACHE_LEVELS',
                    'CACHE_TYPES']
        },
        'nginx': {
            'name': 'Nginx 性能',
            'icon': '⚡',
            'keys': ['NGINX_WORKER_PROCESSES', 'NGINX_WORKER_CONNECTIONS',
                    'NGINX_RLIMIT_NOFILE', 'NGINX_LOG_LEVEL']
        },
        'proxy': {
            'name': '代理配置',
            'icon': '🔀',
            'keys': ['PROXY_CONNECT_TIMEOUT', 'PROXY_READ_TIMEOUT',
                    'PROXY_SEND_TIMEOUT', 'PROXY_CONNECT_PORTS']
        },
        'dns': {
            'name': 'DNS 配置',
            'icon': '🔍',
            'keys': ['DNS_SERVERS', 'DNS_CACHE_SIZE', 'DNS_MIN_CACHE_TTL']
        },
        'security': {
            'name': '安全配置',
            'icon': '🔒',
            'keys': ['STATUS_ALLOW_NETS']
        },
        'system': {
            'name': '系统配置',
            'icon': '⚙️',
            'keys': ['AUTO_START']
        }
    }

    def __init__(self, proxy_dir: str = '/opt/proxy'):
        self.proxy_dir = proxy_dir
        self.env_file = os.path.join(proxy_dir, '.env')
        self.dnsmasq_hosts_file = os.path.join(proxy_dir, 'dnsmasq/hosts.d/custom.conf')
        self.nginx_conf_file = os.path.join(proxy_dir, 'tengine/nginx.conf')
        self.dnsmasq_conf_file = os.path.join(proxy_dir, 'dnsmasq/dnsmasq.conf')

    def get_env_config(self) -> Dict[str, str]:
        """读取 .env 配置（仅键值对，跳过注释）"""
        config = {}
        if os.path.exists(self.env_file):
            with open(self.env_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        config[key.strip()] = value.strip()
        return config

    def get_env_config_with_comments(self) -> List[Tuple[str, str, str]]:
        """读取 .env 配置（包含注释和分组）

        返回: [(group, key, value), ...]
        """
        result = []
        current_group = 'network'

        if os.path.exists(self.env_file):
            with open(self.env_file, 'r') as f:
                for line in f:
                    line = line.rstrip()

                    # 检测分组标题
                    if line.startswith('# ---') and '---' in line[6:]:
                        title_match = re.search(r'# -{10,}\s*(.+?)\s*-{10,}', line)
                        if title_match:
                            title = title_match.group(1).lower()
                            for group_key, group_info in self.CONFIG_GROUPS.items():
                                if group_info['name'].lower() in title or group_key in title:
                                    current_group = group_key
                                    break
                            continue

                    # 跳过纯注释行和空行
                    if not line or line.startswith('#') and '=' not in line:
                        continue

                    # 解析配置行
                    if '=' in line:
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip()
                        result.append((current_group, key, value))

        return result

    def get_grouped_config(self) -> Dict[str, Dict]:
        """获取分组后的配置"""
        config = self.get_env_config()
        grouped = {}

        for group_key, group_info in self.CONFIG_GROUPS.items():
            group_configs = {}
            for key in group_info['keys']:
                if key in config:
                    group_configs[key] = config[key]

            grouped[group_key] = {
                'name': group_info['name'],
                'icon': group_info['icon'],
                'configs': group_configs
            }

        return grouped

    def save_env_config(self, config: Dict[str, str], preserve_comments: bool = True) -> Dict:
        """保存 .env 配置"""
        try:
            if preserve_comments and os.path.exists(self.env_file):
                # 保留注释和格式，只更新值
                new_lines = []
                with open(self.env_file, 'r') as f:
                    for line in f:
                        stripped = line.strip()
                        # 保留注释和空行
                        if not stripped or stripped.startswith('#'):
                            new_lines.append(line.rstrip())
                        elif '=' in stripped:
                            key = stripped.split('=', 1)[0].strip()
                            if key in config:
                                new_lines.append(f"{key}={config[key]}")
                                del config[key]
                            else:
                                new_lines.append(line.rstrip())

                # 添加新的配置项
                for key, value in config.items():
                    new_lines.append(f"{key}={value}")

                with open(self.env_file, 'w') as f:
                    f.write('\n'.join(new_lines))
            else:
                # 直接写入（不保留注释）
                lines = []
                for key, value in config.items():
                    lines.append(f"{key}={value}")
                with open(self.env_file, 'w') as f:
                    f.write('\n'.join(lines))

            return {'success': True, 'message': '配置已保存'}
        except Exception as e:
            return {'success': False, 'error': str(e)}

    def get_dns_hosts(self) -> str:
        """读取 DNS 自定义解析配置"""
        if os.path.exists(self.dnsmasq_hosts_file):
            with open(self.dnsmasq_hosts_file, 'r') as f:
                return f.read()
        return ""

    def save_dns_hosts(self, content: str) -> Dict:
        """保存 DNS 自定义解析配置"""
        try:
            os.makedirs(os.path.dirname(self.dnsmasq_hosts_file), exist_ok=True)
            with open(self.dnsmasq_hosts_file, 'w') as f:
                f.write(content)
            return {'success': True, 'message': 'DNS 解析已保存'}
        except Exception as e:
            return {'success': False, 'error': str(e)}

    def get_nginx_config(self) -> str:
        """读取 Nginx 配置"""
        if os.path.exists(self.nginx_conf_file):
            with open(self.nginx_conf_file, 'r') as f:
                return f.read()
        return ""

    def get_dnsmasq_config(self) -> str:
        """读取 Dnsmasq 配置"""
        if os.path.exists(self.dnsmasq_conf_file):
            with open(self.dnsmasq_conf_file, 'r') as f:
                return f.read()
        return ""

    def generate_nginx_config(self, config: Dict[str, str]) -> str:
        """生成 Tengine/Nginx 配置文件内容"""
        # 获取配置值，设置默认值
        proxy_port = config.get('PROXY_HOST_PORT', '3128')
        status_port = config.get('STATUS_HOST_PORT', '8080')
        dns_port = config.get('DNSMASQ_HOST_PORT', '53')
        host_ip = config.get('HOST_IP', '127.0.0.1')

        cache_base = config.get('CACHE_BASE', '/mnt/HDD/cache/Tengine')
        cache_max_size = config.get('CACHE_MAX_SIZE', '1800g')
        cache_keys_zone = config.get('CACHE_KEYS_ZONE', '512m')
        cache_inactive = config.get('CACHE_INACTIVE', '30d')
        cache_min_free = config.get('CACHE_MIN_FREE', '50g')
        cache_levels = config.get('CACHE_LEVELS', '1:2')

        worker_processes = config.get('NGINX_WORKER_PROCESSES', 'auto')
        worker_connections = config.get('NGINX_WORKER_CONNECTIONS', '4096')
        rlimit_nofile = config.get('NGINX_RLIMIT_NOFILE', '65535')
        log_level = config.get('NGINX_LOG_LEVEL', 'warn')

        connect_timeout = config.get('PROXY_CONNECT_TIMEOUT', '20')
        read_timeout = config.get('PROXY_READ_TIMEOUT', '60')
        send_timeout = config.get('PROXY_SEND_TIMEOUT', '60')
        connect_ports = config.get('PROXY_CONNECT_PORTS', '443 80 8080 8443')

        status_allow_nets = config.get('STATUS_ALLOW_NETS', '192.168.91.0/24 192.168.92.0/24')
        allow_net_list = status_allow_nets.split()

        # 生成配置
        conf = f"""user  nginx;
worker_processes  {worker_processes};
worker_rlimit_nofile {rlimit_nofile};

error_log  /usr/local/tengine/logs/error.log {log_level};

events {{
    worker_connections  {worker_connections};
    use epoll;
}}

http {{
    include       mime.types;
    default_type  application/octet-stream;

    # DNS 指向宿主机的 Dnsmasq
    resolver 127.0.0.1:{dns_port} valid=300s ipv6=off;
    resolver_timeout 5s;

    # 日志格式
    log_format cache '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_host" $upstream_cache_status '
                    'rt=$request_time uct="$upstream_connect_time"';

    access_log /usr/local/tengine/logs/access.log cache;

    # HDD 缓存配置
    proxy_cache_path {cache_base} \\
                     levels={cache_levels} \\
                     keys_zone=cache_zone:{cache_keys_zone} \\
                     max_size={cache_max_size} \\
                     inactive={cache_inactive} \\
                     use_temp_path=off \\
                     min_free={cache_min_free};

    # 代理超时设置
    proxy_connect_timeout  {connect_timeout}s;
    proxy_read_timeout     {read_timeout}s;
    proxy_send_timeout     {send_timeout}s;

    # HTTP/HTTPS 代理服务器
    server {{
        listen {proxy_port};

        # 启用 CONNECT 方法
        proxy_connect;
        proxy_connect_allow {connect_ports};

        # 缓存配置
        proxy_cache cache_zone;
        proxy_cache_valid 200 206 301 302 30d;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503;

        proxy_cache_lock on;
        proxy_cache_lock_timeout 5s;

        proxy_cache_key $scheme$proxy_host$uri$is_args$args;

        # 安全头部处理
        proxy_hide_header X-Frame-Options;
        proxy_hide_header X-Content-Type-Options;

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        location / {{
            proxy_pass http://$http_host$request_uri;
            proxy_set_header Host $http_host;
            proxy_ignore_headers X-Accel-Expires Expires Cache-Control Set-Cookie;
        }}
    }}

    # 状态监控页
    server {{
        listen {status_port};
        location /status {{
            stub_status on;
            access_log off;
"""
        # 添加访问控制
        for net in allow_net_list:
            net = net.strip()
            if net:
                conf += f"            allow {net};\n"

        conf += """            deny all;
        }
    }
}
"""
        return conf

    def generate_dnsmasq_config(self, config: Dict[str, str]) -> str:
        """生成 Dnsmasq 配置文件内容"""
        host_ip = config.get('HOST_IP', '127.0.0.1')
        dns_servers = config.get('DNS_SERVERS', '223.5.5.5 223.6.6.6 119.29.29.29')
        dns_cache_size = config.get('DNS_CACHE_SIZE', '10000')
        dns_min_cache_ttl = config.get('DNS_MIN_CACHE_TTL', '300')

        # 监听地址
        if host_ip and host_ip != '127.0.0.1':
            listen_addr = f"127.0.0.1,{host_ip}"
        else:
            listen_addr = "127.0.0.1"

        # DNS 服务器列表
        dns_list = dns_servers.split()

        conf = f"""# 监听配置
listen-address={listen_addr}
bind-interfaces

# 上游 DNS
"""
        for dns in dns_list:
            dns = dns.strip()
            if dns:
                conf += f"server={dns}\n"

        conf += f"""
# 缓存优化
cache-size={dns_cache_size}
dns-forward-max=1000
min-cache-ttl={dns_min_cache_ttl}
neg-ttl=3600

# 不读取 resolv.conf
no-resolv
no-poll

# 日志
log-facility=-
log-queries
"""
        return conf

    def generate_configs(self, config: Optional[Dict[str, str]] = None) -> Dict:
        """生成 tengine 和 dnsmasq 配置文件

        Args:
            config: 配置字典，如果为 None 则从 .env 读取

        Returns:
            {'success': bool, 'message': str, 'files': [生成的文件列表]}
        """
        try:
            # 如果没有提供配置，从 .env 读取
            if config is None:
                config = self.get_env_config()

            # 确保目录存在
            os.makedirs(os.path.dirname(self.nginx_conf_file), exist_ok=True)
            os.makedirs(os.path.dirname(self.dnsmasq_conf_file), exist_ok=True)

            # 生成 Nginx 配置
            nginx_conf = self.generate_nginx_config(config)
            with open(self.nginx_conf_file, 'w') as f:
                f.write(nginx_conf)

            # 生成 Dnsmasq 配置
            dnsmasq_conf = self.generate_dnsmasq_config(config)
            with open(self.dnsmasq_conf_file, 'w') as f:
                f.write(dnsmasq_conf)

            return {
                'success': True,
                'message': '配置文件已生成',
                'files': [self.nginx_conf_file, self.dnsmasq_conf_file]
            }

        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    def get_config_template(self) -> Dict:
        """获取配置模板（包含所有可配置项及说明）"""
        return {
            'network': {
                'name': '网络配置',
                'icon': '🌐',
                'fields': [
                    {'key': 'NETWORK_MODE', 'label': '网络模式', 'type': 'select',
                     'options': ['host', 'bridge'], 'default': 'host',
                     'description': 'host模式性能最佳，bridge模式更灵活'},
                    {'key': 'HOST_IP', 'label': '本机 IP', 'type': 'text',
                     'default': '192.168.91.100', 'description': '用于DNS监听和状态页访问控制'}
                ]
            },
            'ports': {
                'name': '端口配置',
                'icon': '🔌',
                'fields': [
                    {'key': 'PROXY_MANAGER_PORT', 'label': '管理程序端口', 'type': 'number',
                     'default': 5557, 'description': 'Proxy Manager Web 控制台端口（修改后需重启服务）'},
                    {'key': 'DNSMASQ_HOST_PORT', 'label': 'DNS 端口', 'type': 'number',
                     'default': 53, 'description': 'Dnsmasq DNS 服务端口'},
                    {'key': 'PROXY_HOST_PORT', 'label': '代理端口', 'type': 'number',
                     'default': 3128, 'description': 'HTTP/HTTPS 代理端口'},
                    {'key': 'STATUS_HOST_PORT', 'label': '状态页端口', 'type': 'number',
                     'default': 8088, 'description': 'Tengine 状态监控页端口'}
                ]
            },
            'cache': {
                'name': '缓存配置',
                'icon': '💾',
                'fields': [
                    {'key': 'CACHE_BASE', 'label': '缓存目录', 'type': 'text',
                     'default': '/mnt/HDD/cache/Tengine', 'description': '缓存根目录'},
                    {'key': 'CACHE_MAX_SIZE', 'label': '最大缓存', 'type': 'text',
                     'default': '1800g', 'description': '例如: 1800g, 500g'},
                    {'key': 'CACHE_KEYS_ZONE', 'label': '缓存内存', 'type': 'text',
                     'default': '512m', 'description': '缓存键区域内存大小'},
                    {'key': 'CACHE_INACTIVE', 'label': '过期时间', 'type': 'text',
                     'default': '30d', 'description': '缓存未命中后的过期时间'},
                    {'key': 'CACHE_MIN_FREE', 'label': '最小保留空间', 'type': 'text',
                     'default': '50g', 'description': '最小保留磁盘空间'}
                ]
            },
            'nginx': {
                'name': 'Nginx 性能',
                'icon': '⚡',
                'fields': [
                    {'key': 'NGINX_WORKER_PROCESSES', 'label': 'Worker 进程数', 'type': 'text',
                     'default': 'auto', 'description': 'auto = 自动检测CPU核心数'},
                    {'key': 'NGINX_WORKER_CONNECTIONS', 'label': 'Worker 连接数', 'type': 'number',
                     'default': 4096, 'description': '每个 Worker 的最大连接数'},
                    {'key': 'NGINX_RLIMIT_NOFILE', 'label': '文件描述符限制', 'type': 'number',
                     'default': 65535, 'description': '最大文件描述符数量'}
                ]
            },
            'proxy': {
                'name': '代理配置',
                'icon': '🔀',
                'fields': [
                    {'key': 'PROXY_CONNECT_TIMEOUT', 'label': '连接超时(秒)', 'type': 'number',
                     'default': 20, 'description': '代理连接超时时间'},
                    {'key': 'PROXY_READ_TIMEOUT', 'label': '读取超时(秒)', 'type': 'number',
                     'default': 60, 'description': '代理读取超时时间'},
                    {'key': 'PROXY_SEND_TIMEOUT', 'label': '发送超时(秒)', 'type': 'number',
                     'default': 60, 'description': '代理发送超时时间'},
                    {'key': 'PROXY_CONNECT_PORTS', 'label': '允许端口', 'type': 'text',
                     'default': '443 80 8080 8443', 'description': 'CONNECT方法允许的HTTPS端口'}
                ]
            },
            'dns': {
                'name': 'DNS 配置',
                'icon': '🔍',
                'fields': [
                    {'key': 'DNS_SERVERS', 'label': '上游DNS', 'type': 'text',
                     'default': '223.5.5.5 223.6.6.6 119.29.29.29',
                     'description': '上游DNS服务器，空格分隔'},
                    {'key': 'DNS_CACHE_SIZE', 'label': 'DNS缓存条目', 'type': 'number',
                     'default': 10000, 'description': 'DNS缓存最大条目数'},
                    {'key': 'DNS_MIN_CACHE_TTL', 'label': '最小缓存TTL(秒)', 'type': 'number',
                     'default': 300, 'description': 'DNS最小缓存存活时间'}
                ]
            },
            'security': {
                'name': '安全配置',
                'icon': '🔒',
                'fields': [
                    {'key': 'STATUS_ALLOW_NETS', 'label': '允许访问状态页的网段', 'type': 'text',
                     'default': '192.168.91.0/24 192.168.92.0/24',
                     'description': 'CIDR格式，空格分隔'}
                ]
            },
            'system': {
                'name': '系统配置',
                'icon': '⚙️',
                'fields': [
                    {'key': 'AUTO_START', 'label': '随系统启动', 'type': 'select',
                     'options': ['true', 'false'], 'default': 'true',
                     'description': '启用后将在系统启动时自动运行 Proxy Manager'}
                ]
            }
        }
