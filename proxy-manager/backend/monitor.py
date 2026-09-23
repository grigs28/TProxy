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

            # 解析缓存状态 - 使用新的日志格式 cache_status="HIT/MISS/-"
            cache_result = subprocess.getoutput(
                f'grep -oP \'cache_status="\\K[A-Z-]+\' {log_file} 2>/dev/null | sort | uniq -c'
            )

            hits = misses = bypass = expired = updating = none = total = 0
            for line in cache_result.split('\n'):
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        count = int(parts[0])
                        status = parts[1]
                        if status == '-':
                            none += count
                        elif status == 'HIT':
                            hits += count
                            total += count
                        elif status == 'MISS':
                            misses += count
                            total += count
                        elif status == 'BYPASS':
                            bypass += count
                            total += count
                        elif status == 'EXPIRED':
                            expired += count
                            total += count
                        elif status == 'UPDATING':
                            updating += count
                            total += count
                    except ValueError:
                        continue

            # 统计 CONNECT 请求数（HTTPS 隧道模式）
            connect_result = subprocess.getoutput(
                f'grep -c "CONNECT " {log_file} 2>/dev/null || echo 0'
            )
            connect_requests = int(connect_result.strip()) if connect_result.strip().isdigit() else 0

            if total == 0:
                return {
                    'hit_rate': 'N/A',
                    'hits': 0,
                    'misses': 0,
                    'total': 0,
                    'requests_today': today_requests,
                    'connect_requests': connect_requests,
                    'note': 'HTTPS CONNECT requests bypass cache (tunnel mode)'
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
                'requests_today': today_requests,
                'connect_requests': connect_requests,
                'note': 'HTTPS CONNECT uses tunnel mode, cannot be cached'
            }
        except Exception as e:
            return {'error': str(e), 'hit_rate': 'N/A'}

    def get_cache_stats_by_type(self) -> Dict:
        """获取按类型分组的缓存统计"""
        log_file = '/mnt/HDD/TProxy/logs/tengine/access.log'

        try:
            # 统计每个缓存类型的状态分布
            cache_type_result = subprocess.getoutput(
                f'''grep -oP 'cache_type="\\K[^"]+"[^ ]*cache_status="\\K[HMISX-]+' {log_file} 2>/dev/null | \\
                awk '{{split($0, a, "\""); type=a[1]; status=a[3]; count[type":"status]++}} END {{for (i in count) print i, count[i]}}' '''
            )

            # 统计每个缓存类型的请求数
            type_counts = subprocess.getoutput(
                f'grep -oP \'cache_type="\\K[^\"]+\' {log_file} 2>/dev/null | sort | uniq -c'
            )

            stats_by_type = {}
            for line in type_counts.split('\n'):
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        count = int(parts[0])
                        cache_type = parts[1]
                        stats_by_type[cache_type] = {
                            'total': count,
                            'hits': 0,
                            'misses': 0
                        }
                    except ValueError:
                        continue

            return {
                'by_type': stats_by_type,
                'cache_types': list(stats_by_type.keys())
            }
        except Exception as e:
            return {'error': str(e)}

    def get_recent_requests(self, limit: int = 50) -> Dict:
        """获取最近的请求记录"""
        log_file = '/mnt/HDD/TProxy/logs/tengine/access.log'

        try:
            # 获取最近的请求记录，格式化为 JSON
            result = subprocess.getoutput(
                f'tail -{limit} {log_file} 2>/dev/null'
            )

            requests = []
            for line in result.split('\n'):
                if not line.strip():
                    continue

                # 解析日志行
                import re
                match = re.search(
                    r'(?P<ip>[\d.]+).*?\[(?P<time>[^\]]+)\].*?"(?P<method>\w+) (?P<uri>[^\s]+).*?" '
                    r'(?P<status>\d+) (?P<size>\d+).*?cache_status="(?P<cache_status>[^"]*)".*?'
                    r'cache_type="(?P<cache_type>[^"]*)".*?rt=(?P<request_time>[\d.]+).*?'
                    r'scheme="(?P<scheme>[^"]*)"'
                , line)

                if match:
                    requests.append({
                        'ip': match.group('ip'),
                        'time': match.group('time'),
                        'method': match.group('method'),
                        'uri': match.group('uri')[:100],  # 限制长度
                        'status': match.group('status'),
                        'size': match.group('size'),
                        'cache_status': match.group('cache_status') or '-',
                        'cache_type': match.group('cache_type'),
                        'request_time': match.group('request_time'),
                        'scheme': match.group('scheme')
                    })

            return {'requests': requests, 'count': len(requests)}
        except Exception as e:
            return {'error': str(e), 'requests': []}

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
