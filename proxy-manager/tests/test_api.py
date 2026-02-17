#!/usr/bin/env python3
"""
Proxy Manager API 测试
"""
import sys
import os

# 添加项目路径
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import unittest
from main import app


class TestAPI(unittest.TestCase):
    """API 接口测试"""

    def setUp(self):
        self.app = app.test_client()
        self.app.testing = True

    def test_health_check(self):
        """测试健康检查"""
        response = self.app.get('/api/health')
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data.get('status'), 'ok')

    def test_index(self):
        """测试首页"""
        response = self.app.get('/')
        self.assertEqual(response.status_code, 200)

    def test_api_status(self):
        """测试状态接口"""
        response = self.app.get('/api/status')
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertIn('containers', data)
        self.assertIn('nginx', data)

    def test_api_config_get(self):
        """测试获取配置"""
        response = self.app.get('/api/config')
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertIsInstance(data, dict)

    def test_api_logs(self):
        """测试日志接口"""
        response = self.app.get('/api/logs/tengine')
        # 日志文件可能不存在，返回 404 或 200
        self.assertIn(response.status_code, [200, 404])

    def test_unauthorized_post(self):
        """测试未认证的 POST 请求"""
        response = self.app.post('/api/config', json={})
        self.assertEqual(response.status_code, 401)


if __name__ == '__main__':
    unittest.main()
