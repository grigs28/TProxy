#!/usr/bin/env python3
"""
监控数据采集模块
"""
import subprocess
import requests
from typing import Dict, Optional


class Monitor:
    """系统监控数据采集器"""

    def __init__(self, cache_path: str = '/mnt/HDD/TProxy/cache',
                 status_url: str = 'http://127.0.0.1:8080/status'):
        self.cache_path = cache_path
        self.status_url = status_url

    def get_cache_size(self) -> str:
        """获取缓存目录大小"""
        result = subprocess.getoutput(f"du -sh {self.cache_path} 2>/dev/null | cut -f1")
        return result or "0B"

    def get_nginx_stats(self) -> Dict:
        """获取 Nginx 状态页数据"""
        try:
            r = requests.get(self.status_url, timeout=2)
            lines = r.text.strip().split('\n')

            return {
                'active_connections': lines[0].split(':')[1].strip() if len(lines) > 0 else 'N/A',
                'accepts': lines[2].split()[0] if len(lines) > 2 else '0',
                'handled': lines[2].split()[1] if len(lines) > 2 else '0',
                'requests': lines[2].split()[2] if len(lines) > 2 else '0'
            }
        except Exception as e:
            return {'error': str(e)}

    def get_disk_usage(self) -> Dict:
        """获取磁盘使用情况"""
        result = subprocess.getoutput(f"df -h {self.cache_path} 2>/dev/null | tail -1")
        if result:
            parts = result.split()
            if len(parts) >= 6:
                return {
                    'total': parts[1],
                    'used': parts[2],
                    'available': parts[3],
                    'percent': parts[4],
                    'mount': parts[5]
                }
        return {}

    def get_system_info(self) -> Dict:
        """获取系统信息"""
        import datetime
        import socket

        return {
            'hostname': socket.gethostname(),
            'timestamp': datetime.datetime.now().isoformat(),
            'uptime': subprocess.getoutput('uptime -p 2>/dev/null || uptime')
        }
