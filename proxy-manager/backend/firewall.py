#!/usr/bin/env python3
"""
防火墙管理模块
"""
import subprocess
from typing import Dict, List


class Firewall:
    """防火墙管理器"""

    # TProxy 需要的端口列表
    REQUIRED_PORTS = {
        '53': 'DNS 服务',
        '3128': 'HTTP 代理',
        '5557': 'Web 管理界面',
        '8080': '状态监控页'
    }

    def __init__(self):
        self.firewalld_cmd = 'firewall-cmd'
        self.systemctl_cmd = 'systemctl'

    def _run_command(self, command: str) -> Dict:
        """执行 shell 命令"""
        try:
            result = subprocess.getoutput(command)
            return {'success': True, 'output': result}
        except Exception as e:
            return {'success': False, 'error': str(e)}

    def get_status(self) -> Dict:
        """获取防火墙状态"""
        # 检查 firewalld 服务状态
        status_result = subprocess.getoutput(
            f"{self.systemctl_cmd} is-active firewalld 2>/dev/null"
        ).strip()

        is_active = status_result == 'active'

        # 检查 firewalld 是否安装
        is_installed = subprocess.getoutput(
            "which firewall-cmd 2>/dev/null"
        ).strip() != ''

        if not is_installed:
            return {
                'installed': False,
                'active': False,
                'message': 'firewalld 未安装'
            }

        # 获取已开放的端口
        open_ports = []
        if is_active:
            ports_result = subprocess.getoutput(
                f"{self.firewalld_cmd} --permanent --list-ports 2>/dev/null"
            ).strip()
            open_ports = [p.strip() for p in ports_result.split() if p.strip()]

        return {
            'installed': is_installed,
            'active': is_active,
            'open_ports': open_ports,
            'required_ports': self.REQUIRED_PORTS,
            'message': '运行中' if is_active else '已停止'
        }

    def start(self) -> Dict:
        """启动防火墙"""
        return self._run_command(f"{self.systemctl_cmd} start firewalld")

    def stop(self) -> Dict:
        """停止防火墙"""
        return self._run_command(f"{self.systemctl_cmd} stop firewalld")

    def restart(self) -> Dict:
        """重启防火墙"""
        return self._run_command(f"{self.systemctl_cmd} restart firewalld")

    def enable(self) -> Dict:
        """设置防火墙开机自启"""
        return self._run_command(f"{self.systemctl_cmd} enable firewalld")

    def disable(self) -> Dict:
        """禁用防火墙开机自启"""
        return self._run_command(f"{self.systemctl_cmd} disable firewalld")

    def open_port(self, port: str, protocol: str = 'tcp') -> Dict:
        """开放端口"""
        # 检查端口是否已开放
        check_result = self._run_command(
            f"{self.firewalld_cmd} --permanent --list-ports 2>/dev/null | grep -w '{port}/{protocol}'"
        )

        if check_result['success'] and check_result['output']:
            return {'success': True, 'message': f'端口 {port}/{protocol} 已开放'}

        # 开放端口
        add_result = self._run_command(
            f"{self.firewalld_cmd} --permanent --add-port={port}/{protocol}"
        )

        if not add_result['success']:
            return add_result

        # 重新加载防火墙配置
        reload_result = self._run_command(f"{self.firewalld_cmd} --reload")

        return {
            'success': reload_result['success'],
            'message': f'端口 {port}/{protocol} 已开放' if reload_result['success'] else add_result.get('output', '')
        }

    def close_port(self, port: str, protocol: str = 'tcp') -> Dict:
        """关闭端口"""
        # 移除端口
        remove_result = self._run_command(
            f"{self.firewalld_cmd} --permanent --remove-port={port}/{protocol}"
        )

        # 重新加载防火墙配置
        reload_result = self._run_command(f"{self.firewalld_cmd} --reload")

        return {
            'success': reload_result['success'],
            'message': f'端口 {port}/{protocol} 已关闭' if reload_result['success'] else remove_result.get('output', '')
        }

    def open_all_required_ports(self) -> Dict:
        """开放所有 TProxy 需要的端口"""
        results = []
        for port in self.REQUIRED_PORTS.keys():
            result = self.open_port(port, 'tcp')
            results.append({
                'port': port,
                'description': self.REQUIRED_PORTS[port],
                'success': result['success'],
                'message': result.get('message', '')
            })

        success_count = sum(1 for r in results if r['success'])
        return {
            'success': success_count == len(results),
            'results': results,
            'message': f'已开放 {success_count}/{len(results)} 个端口'
        }

    def get_port_status(self) -> List[Dict]:
        """获取所有端口的状态"""
        status = self.get_status()
        open_ports_set = set(status.get('open_ports', []))

        port_list = []
        for port, desc in self.REQUIRED_PORTS.items():
            port_key = f'{port}/tcp'
            is_open = port_key in open_ports_set
            port_list.append({
                'port': port,
                'protocol': 'tcp',
                'description': desc,
                'is_open': is_open,
                'status': '已开放' if is_open else '未开放'
            })

        return port_list
