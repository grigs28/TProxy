#!/usr/bin/env python3
"""
Docker 容器控制模块
"""
import docker
import subprocess
import socket
import psutil
from typing import Dict, List, Optional, Tuple


class DockerController:
    """Docker 容器控制器"""

    def __init__(self):
        self.client = docker.from_env()

    def get_container_status(self, name: str) -> Dict:
        """获取容器状态"""
        try:
            c = self.client.containers.get(name)
            return {
                'name': name,
                'status': c.status,
                'health': c.attrs.get('State', {}).get('Health', {}).get('Status', 'unknown'),
                'started': c.attrs.get('State', {}).get('StartedAt', ''),
                'image': c.attrs.get('Config', {}).get('Image', '')
            }
        except docker.errors.NotFound:
            # 特殊处理 proxy-generator：查找 proxy-generator-run-* 容器
            if name == 'proxy-generator':
                try:
                    # 查找所有匹配的容器
                    containers = self.client.containers.list(all=True, filters={'name': 'proxy-generator-run-'})
                    if containers:
                        c = containers[0]
                        return {
                            'name': name,
                            'status': c.status,
                            'health': c.attrs.get('State', {}).get('Health', {}).get('Status', 'unknown'),
                            'started': c.attrs.get('State', {}).get('StartedAt', ''),
                            'image': c.attrs.get('Config', {}).get('Image', '')
                        }
                except:
                    pass
            return {'name': name, 'status': 'not_found'}
        except Exception as e:
            return {'name': name, 'status': 'error', 'error': str(e)}

    def get_all_status(self) -> Dict[str, Dict]:
        """获取所有相关容器状态"""
        containers = {}
        for name in ['proxy-generator', 'dnsmasq', 'tengine', 'docker-registry', 'gitcache']:
            containers[name] = self.get_container_status(name)
        return containers

    def reload_nginx(self) -> Dict:
        """重载 Nginx 配置"""
        # 测试配置
        test_result = subprocess.run(
            ["docker", "exec", "tengine", "/usr/local/tengine/sbin/nginx", "-t"],
            capture_output=True, text=True
        )

        if test_result.returncode != 0:
            return {
                'success': False,
                'error': '配置语法错误',
                'details': test_result.stderr
            }

        # 重载配置
        reload_result = subprocess.run(
            ["docker", "exec", "tengine", "/usr/local/tengine/sbin/nginx", "-s", "reload"],
            capture_output=True, text=True
        )

        return {
            'success': reload_result.returncode == 0,
            'message': 'Nginx 配置已重载' if reload_result.returncode == 0 else reload_result.stderr
        }

    def reload_dnsmasq(self) -> Dict:
        """重载 Dnsmasq 配置"""
        result = subprocess.run(
            ["docker", "kill", "--signal=HUP", "dnsmasq"],
            capture_output=True, text=True
        )
        return {
            'success': result.returncode == 0,
            'message': 'Dnsmasq 配置已热重载' if result.returncode == 0 else result.stderr
        }

    def get_logs(self, service: str, lines: int = 100) -> Dict:
        """获取服务日志"""
        valid_services = ['tengine', 'dnsmasq', 'docker-registry', 'gitcache', 'proxy-generator']
        if service not in valid_services:
            return {'error': f'Unknown service: {service}'}

        try:
            # 使用 docker logs 获取容器日志
            result = subprocess.run(
                ['docker', 'logs', '--tail', str(lines), service],
                capture_output=True, text=True, timeout=10
            )

            if result.returncode != 0:
                return {'error': f'容器 {service} 不存在或未运行', 'logs': result.stderr}

            return {
                'success': True,
                'logs': result.stdout
            }
        except subprocess.TimeoutExpired:
            return {'error': '获取日志超时'}
        except Exception as e:
            return {'error': str(e)}

    def restart_container(self, name: str) -> Dict:
        """重启容器"""
        try:
            c = self.client.containers.get(name)
            c.restart()
            return {'success': True, 'message': f'{name} 已重启'}
        except Exception as e:
            return {'success': False, 'error': str(e)}

    def check_port(self, port: int, proto: str = 'tcp') -> Dict:
        """检查端口是否被占用

        Args:
            port: 端口号
            proto: 协议类型 (tcp/udp)

        Returns:
            {'occupied': bool, 'process': str or None, 'pid': int or None}
        """
        try:
            # 检查 TCP 端口
            if proto == 'tcp':
                # 尝试连接端口
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                    s.settimeout(0.1)
                    result = s.connect_ex(('127.0.0.1', port))
                    if result == 0:
                        # 端口被占用，查找占用进程
                        for conn in psutil.net_connections():
                            if conn.laddr.port == port and conn.status == 'LISTEN':
                                try:
                                    process = psutil.Process(conn.pid)
                                    return {
                                        'occupied': True,
                                        'port': port,
                                        'proto': proto,
                                        'pid': conn.pid,
                                        'process': process.name(),
                                        'cmdline': ' '.join(process.cmdline()[:2])
                                    }
                                except (psutil.NoSuchProcess, psutil.AccessDenied):
                                    return {
                                        'occupied': True,
                                        'port': port,
                                        'proto': proto,
                                        'pid': conn.pid,
                                        'process': 'unknown',
                                        'cmdline': ''
                                    }
                return {'occupied': False, 'port': port, 'proto': proto}

            # 检查 UDP 端口
            elif proto == 'udp':
                for conn in psutil.net_connections(kind='udp'):
                    if conn.laddr.port == port:
                        try:
                            process = psutil.Process(conn.pid)
                            return {
                                'occupied': True,
                                'port': port,
                                'proto': proto,
                                'pid': conn.pid,
                                'process': process.name(),
                                'cmdline': ' '.join(process.cmdline()[:2])
                            }
                        except (psutil.NoSuchProcess, psutil.AccessDenied):
                            return {
                                'occupied': True,
                                'port': port,
                                'proto': proto,
                                'pid': conn.pid,
                                'process': 'unknown',
                                'cmdline': ''
                            }
                return {'occupied': False, 'port': port, 'proto': proto}

        except Exception as e:
            return {'occupied': False, 'port': port, 'proto': proto, 'error': str(e)}

    def check_ports(self, ports: List[Tuple[int, str]]) -> Dict:
        """批量检查端口

        Args:
            ports: [(port, proto), ...] 例如: [(53, 'tcp'), (3128, 'tcp')]

        Returns:
            {
                'all_clear': bool,
                'ports': {port: {result}, ...},
                'conflicts': [(port, proto, process), ...]
            }
        """
        results = {}
        conflicts = []

        for port, proto in ports:
            result = self.check_port(port, proto)
            results[f"{port}/{proto}"] = result
            if result.get('occupied'):
                conflicts.append({
                    'port': port,
                    'proto': proto,
                    'pid': result.get('pid'),
                    'process': result.get('process'),
                    'cmdline': result.get('cmdline', '')
                })

        return {
            'all_clear': len(conflicts) == 0,
            'ports': results,
            'conflicts': conflicts
        }

    def get_container_ports(self) -> Dict:
        """获取当前 proxy 容器使用的端口"""
        ports = {
            'dnsmasq': [],
            'tengine': []
        }

        try:
            # 获取 dnsmasq 容器端口
            c = self.client.containers.get('dnsmasq')
            # 读取 .env 配置
        except:
            pass

        return ports
