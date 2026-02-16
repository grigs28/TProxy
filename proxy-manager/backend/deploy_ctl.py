#!/usr/bin/env python3
"""
Docker 部署控制模块
"""
import os
import subprocess
import threading
import time
from typing import Dict, Callable, Optional
from datetime import datetime


class DeploymentController:
    """Docker Compose 部署控制器"""

    def __init__(self, proxy_dir: str = '/opt/TProxy/proxy'):
        self.proxy_dir = proxy_dir
        self.compose_file = os.path.join(proxy_dir, 'docker-compose.yml')
        self.deploying = False
        self.status = {
            'step': '',
            'progress': 0,
            'message': '',
            'error': None
        }
        self.status_callbacks = []
        # 部署日志缓冲区
        self.deploy_logs = []
        self.log_file = os.path.join(proxy_dir, '../proxy-manager/deploy.log')

    def add_status_callback(self, callback: Callable):
        """添加状态更新回调函数"""
        self.status_callbacks.append(callback)

    def _notify_status(self, step: str, progress: int, message: str, error: Optional[str] = None):
        """通知状态更新"""
        self.status = {
            'step': step,
            'progress': progress,
            'message': message,
            'error': error
        }
        for callback in self.status_callbacks:
            try:
                callback(self.status)
            except Exception:
                pass

    def _log(self, message: str):
        """记录部署日志"""
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        log_entry = f"[{timestamp}] {message}"
        self.deploy_logs.append(log_entry)

        # 限制日志缓冲区大小
        if len(self.deploy_logs) > 500:
            self.deploy_logs = self.deploy_logs[-500:]

    def get_status(self) -> Dict:
        """获取当前部署状态"""
        return self.status.copy()

    def is_deploying(self) -> bool:
        """检查是否正在部署"""
        return self.deploying

    def deploy(self) -> Dict:
        """开始部署（同步启动，后台执行）"""
        if self.deploying:
            return {
                'success': False,
                'error': '部署任务正在进行中'
            }

        # 清空之前的日志
        self.deploy_logs = []

        # 启动后台部署线程
        thread = threading.Thread(target=self._deploy_async, daemon=True)
        thread.start()

        return {
            'success': True,
            'message': '部署任务已启动'
        }

    def _deploy_async(self):
        """后台异步执行部署"""
        self.deploying = True

        try:
            # 步骤 1: 停止现有服务
            self._log('=== 开始部署 ===')
            self._notify_status('stop', 5, '停止现有服务...')
            self._log('步骤 1/6: 停止现有容器')
            result = self._run_command(['docker-compose', 'down'], self.proxy_dir)
            if not result['success']:
                self._log(f'错误: {result["error"]}')
                self._notify_status('error', 0, '', result['error'])
                return
            self._log(result.get('output', '容器已停止'))

            # 步骤 2: 构建镜像
            self._notify_status('build', 10, '构建 Tengine 镜像（预计 5-10 分钟）...')
            self._log('步骤 2/6: 构建 Tengine 镜像（这需要一些时间...）')
            result = self._run_command(['docker-compose', 'build', 'tengine'], self.proxy_dir, timeout=900)
            if not result['success']:
                self._log(f'错误: {result["error"]}')
                self._notify_status('error', 0, '', result['error'])
                return
            self._log(result.get('output', '镜像构建完成'))

            # 步骤 3: 启动服务
            self._notify_status('start', 70, '启动服务...')
            self._log('步骤 3/6: 启动服务')
            result = self._run_command(['docker-compose', 'up', '-d'], self.proxy_dir)
            if not result['success']:
                self._log(f'错误: {result["error"]}')
                self._notify_status('error', 0, '', result['error'])
                return
            self._log(result.get('output', '服务已启动'))

            # 步骤 4: 等待服务就绪
            self._notify_status('wait', 85, '等待服务就绪...')
            self._log('步骤 4/6: 等待服务就绪')
            time.sleep(5)
            self._log('服务等待完成')

            # 步骤 5: 验证状态
            self._notify_status('verify', 90, '验证服务状态...')
            self._log('步骤 5/6: 验证服务状态')
            result = self._run_command(['docker-compose', 'ps'], self.proxy_dir)
            self._log(result.get('output', '服务状态检查完成'))

            # 步骤 6: 测试 DNS
            self._notify_status('test_dns', 95, '测试 DNS 解析...')
            self._log('步骤 6/6: 测试 DNS 解析')
            result = self._run_command(['dig', '@127.0.0.1', 'www.baidu.com'], timeout=10)
            if result['success']:
                self._log('DNS 测试成功')

            # 完成
            self._notify_status('complete', 100, '部署完成！')
            self._log('=== 部署完成 ===')
            time.sleep(2)

        except Exception as e:
            self._log(f'部署异常: {str(e)}')
            self._notify_status('error', 0, '', str(e))
        finally:
            self.deploying = False

    def _run_command(self, cmd: list, cwd: Optional[str] = None, timeout: int = 600) -> Dict:
        """运行命令"""
        try:
            result = subprocess.run(
                cmd,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False
            )

            if result.returncode != 0:
                return {
                    'success': False,
                    'error': f"命令执行失败: {result.stderr}"
                }

            return {
                'success': True,
                'output': result.stdout
            }
        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'error': f'命令执行超时 (超过 {timeout} 秒)'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    def get_containers_status(self) -> Dict:
        """获取容器状态"""
        result = self._run_command(['docker-compose', 'ps'], self.proxy_dir)
        if result['success']:
            return {
                'success': True,
                'output': result['output']
            }
        return result

    def get_deployment_logs(self, service: Optional[str] = None) -> Dict:
        """获取部署日志"""
        # 如果有缓存的部署日志，返回部署日志
        if self.deploy_logs:
            return {
                'success': True,
                'output': '\n'.join(self.deploy_logs)
            }

        # 否则返回 docker-compose 日志
        cmd = ['docker-compose', 'logs', '--tail', '50']
        if service:
            cmd.append(service)

        result = self._run_command(cmd, self.proxy_dir)
        if result['success']:
            return {
                'success': True,
                'output': result['output']
            }
        return result
