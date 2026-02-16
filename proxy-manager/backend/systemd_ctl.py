#!/usr/bin/env python3
"""
systemd 服务管理模块
"""
import os
import subprocess
from typing import Dict, List


class SystemdController:
    """systemd 服务控制器"""

    SERVICE_NAME = "proxy-manager"
    SERVICE_FILE = "/etc/systemd/system/proxy-manager.service"
    PROJECT_SERVICE_FILE = "/opt/TProxy/proxy-manager/systemd/proxy-manager.service"

    def get_service_status(self) -> Dict:
        """获取服务状态"""
        try:
            result = subprocess.run(
                ['systemctl', 'is-enabled', self.SERVICE_NAME],
                capture_output=True, text=True, timeout=5
            )
            enabled = result.returncode == 0
            enabled_text = result.stdout.strip()

            result = subprocess.run(
                ['systemctl', 'is-active', self.SERVICE_NAME],
                capture_output=True, text=True, timeout=5
            )
            active = result.stdout.strip()

            return {
                'enabled': enabled,
                'enabled_text': enabled_text,
                'active': active
            }
        except Exception as e:
            return {
                'enabled': False,
                'enabled_text': 'unknown',
                'active': 'unknown',
                'error': str(e)
            }

    def install_service(self, port: int = 5557) -> Dict:
        """安装/更新 systemd 服务文件"""
        try:
            # 确保源服务文件存在
            if not os.path.exists(self.PROJECT_SERVICE_FILE):
                return {
                    'success': False,
                    'error': f'服务模板文件不存在: {self.PROJECT_SERVICE_FILE}'
                }

            # 读取服务模板并更新端口
            with open(self.PROJECT_SERVICE_FILE, 'r') as f:
                content = f.read()

            # 更新端口环境变量
            lines = []
            for line in content.split('\n'):
                if line.strip().startswith('Environment="PORT='):
                    line = f'Environment="PORT={port}"'
                lines.append(line)

            # 写入系统服务文件
            with open(self.SERVICE_FILE, 'w') as f:
                f.write('\n'.join(lines))

            # 重载 systemd
            subprocess.run(['systemctl', 'daemon-reload'], check=True, timeout=10)

            return {
                'success': True,
                'message': '服务文件已安装'
            }
        except subprocess.CalledProcessError as e:
            return {
                'success': False,
                'error': f'命令执行失败: {e}'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    def enable_service(self) -> Dict:
        """启用服务（开机自启）"""
        try:
            subprocess.run(
                ['systemctl', 'enable', self.SERVICE_NAME],
                check=True, capture_output=True, timeout=10
            )
            return {
                'success': True,
                'message': '服务已设置为开机自启'
            }
        except subprocess.CalledProcessError as e:
            return {
                'success': False,
                'error': f'启用失败: {e.stderr.decode() if e.stderr else str(e)}'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    def disable_service(self) -> Dict:
        """禁用服务（取消开机自启）"""
        try:
            subprocess.run(
                ['systemctl', 'disable', self.SERVICE_NAME],
                check=True, capture_output=True, timeout=10
            )
            return {
                'success': True,
                'message': '服务已取消开机自启'
            }
        except subprocess.CalledProcessError as e:
            return {
                'success': False,
                'error': f'禁用失败: {e.stderr.decode() if e.stderr else str(e)}'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    def restart_service(self) -> Dict:
        """重启 Proxy Manager 服务"""
        try:
            subprocess.run(
                ['systemctl', 'restart', self.SERVICE_NAME],
                check=True, capture_output=True, timeout=30
            )
            return {
                'success': True,
                'message': 'Proxy Manager 服务已重启'
            }
        except subprocess.CalledProcessError as e:
            return {
                'success': False,
                'error': f'重启失败: {e.stderr.decode() if e.stderr else str(e)}'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    def start_service(self) -> Dict:
        """启动服务"""
        try:
            subprocess.run(
                ['systemctl', 'start', self.SERVICE_NAME],
                check=True, capture_output=True, timeout=30
            )
            return {
                'success': True,
                'message': 'Proxy Manager 服务已启动'
            }
        except subprocess.CalledProcessError as e:
            return {
                'success': False,
                'error': f'启动失败: {e.stderr.decode() if e.stderr else str(e)}'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    def stop_service(self) -> Dict:
        """停止服务"""
        try:
            subprocess.run(
                ['systemctl', 'stop', self.SERVICE_NAME],
                check=True, capture_output=True, timeout=30
            )
            return {
                'success': True,
                'message': 'Proxy Manager 服务已停止'
            }
        except subprocess.CalledProcessError as e:
            return {
                'success': False,
                'error': f'停止失败: {e.stderr.decode() if e.stderr else str(e)}'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    def set_auto_start(self, enable: bool, port: int = 5557) -> Dict:
        """设置开机自启并控制服务状态"""
        if enable:
            # 启用：安装服务文件，启用并启动服务
            install_result = self.install_service(port)
            if not install_result.get('success'):
                return install_result

            # 启用开机自启
            enable_result = self.enable_service()
            if not enable_result.get('success'):
                return enable_result

            # 启动服务
            return self.start_service()
        else:
            # 禁用：停止服务并禁用开机自启
            stop_result = self.stop_service()
            # 即使停止失败也继续禁用
            disable_result = self.disable_service()

            if not stop_result.get('success') and not disable_result.get('success'):
                return stop_result

            return {
                'success': True,
                'message': '服务已停止并取消开机自启'
            }
