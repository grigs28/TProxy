"""
Proxy Manager 配置文件
"""

# 服务配置
PORT = 5557
DEBUG = False

# Proxy 目录
PROXY_DIR = '/opt/proxy'

# 认证配置
DEFAULT_USERNAME = 'admin'
DEFAULT_PASSWORD = 'admin'

# 缓存配置
CACHE_PATH = '/mnt/HDD/cache/Tengine'

# 状态页配置
STATUS_URL = 'http://127.0.0.1:8080/status'

# 日志配置
LOG_LEVEL = 'INFO'
LOG_FORMAT = '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
