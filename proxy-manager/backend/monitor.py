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

    def get_cache_stats(self) -> Dict:
        """获取缓存命中率统计"""
        import re
        log_file = '/mnt/HDD/TProxy/logs/tengine/access.log'

        try:
            # 获取日志文件行数
            result = subprocess.getoutput(f"wc -l {log_file} 2>/dev/null")
            line_count = int(result.split()[0]) if result and result.split()[0].isdigit() else 0

            if line_count == 0:
                return {'hit_rate': 'N/A', 'hits': 0, 'misses': 0, 'total': 0, 'requests_today': 0}

            # 获取今日请求数 (匹配日志日期格式如 17/Feb/2026)
            today_requests = 0
            try:
                today = subprocess.getoutput("date +%d/%b/%Y").strip()
                today_result = subprocess.getoutput(f"grep -c '{today}' {log_file} 2>/dev/null")
                today_requests = int(today_result.strip()) if today_result.strip().isdigit() else line_count
            except:
                today_requests = line_count

            # 解析缓存状态 (仅 HTTP 请求有缓存状态)
            cache_result = subprocess.getoutput(
                f"grep -oP 'UPST.*: \\K[HMISX]+' {log_file} 2>/dev/null | sort | uniq -c"
            )

            hits = misses = bypass = expired = updating = total = 0
            for line in cache_result.split('\n'):
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        count = int(parts[0])
                        status = parts[1]
                        total += count
                        if status == 'HIT':
                            hits += count
                        elif status == 'MISS':
                            misses += count
                        elif status == 'BYPASS':
                            bypass += count
                        elif status == 'EXPIRED':
                            expired += count
                        elif status == 'UPDATING':
                            updating += count
                    except ValueError:
                        continue

            if total == 0:
                return {
                    'hit_rate': 'N/A',
                    'hits': 0,
                    'misses': 0,
                    'total': 0,
                    'requests_today': today_requests,
                    'note': 'HTTPS CONNECT requests bypass cache'
                }

            hit_rate = (hits / total) * 100
            return {
                'hit_rate': f'{hit_rate:.1f}%',
                'hits': hits,
                'misses': misses,
                'bypass': bypass,
                'expired': expired,
                'updating': updating,
                'total': total,
                'requests_today': today_requests
            }
        except Exception as e:
            return {'error': str(e), 'hit_rate': 'N/A'}

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
