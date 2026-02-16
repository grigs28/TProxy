#!/usr/bin/env python3
"""
Proxy Manager - 代理服务器管理控制台
主入口文件
"""
import os
import sys

# 添加项目路径到 Python 搜索路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS

from backend.docker_ctl import DockerController
from backend.config_ctl import ConfigController
from backend.monitor import Monitor
from backend.systemd_ctl import SystemdController
from backend.deploy_ctl import DeploymentController

# 初始化 Flask 应用
app = Flask(__name__)
CORS(app)

# 配置
PROXY_DIR = os.environ.get('PROXY_DIR', '/opt/TProxy/proxy')
AUTH_TOKEN = "admin:admin"

# 初始化控制器
docker_ctl = DockerController()
config_ctl = ConfigController(PROXY_DIR)
monitor = Monitor(cache_path=os.path.join(PROXY_DIR, '../cache/Tengine'))
systemd_ctl = SystemdController()
deploy_ctl = DeploymentController(PROXY_DIR, config_ctl)


def check_auth():
    """检查认证"""
    auth = request.headers.get('Authorization', '')
    return auth == f"Basic {AUTH_TOKEN}"


def json_response(data, status=200):
    """统一 JSON 响应格式"""
    response = jsonify(data)
    response.status_code = status
    return response


# ==================== 页面路由 ====================

@app.route('/')
def index():
    """主页"""
    return send_from_directory('static', 'index.html')


@app.route('/js/<path:filename>')
def serve_js(filename):
    """提供 JS 文件"""
    return send_from_directory('static/js', filename)


@app.route('/css/<path:filename>')
def serve_css(filename):
    """提供 CSS 文件"""
    return send_from_directory('static/css', filename)


@app.route('/assets/<path:filename>')
def serve_assets(filename):
    """提供静态资源文件"""
    return send_from_directory('static/assets', filename)


# ==================== API 路由 ====================

@app.route('/api/status')
def get_status():
    """获取整体系统状态"""
    try:
        return json_response({
            'containers': docker_ctl.get_all_status(),
            'nginx': monitor.get_nginx_stats(),
            'cache_size': monitor.get_cache_size(),
            'disk': monitor.get_disk_usage(),
            'system': monitor.get_system_info()
        })
    except Exception as e:
        return json_response({'error': str(e)}, 500)


@app.route('/api/config', methods=['GET', 'POST'])
def manage_config():
    """管理环境配置"""
    if request.method == 'GET':
        return json_response(config_ctl.get_env_config())

    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    # 保存 .env 文件
    result = config_ctl.save_env_config(request.json, preserve_comments=True)

    if result.get('success'):
        # 自动生成 tengine 和 dnsmasq 配置文件
        gen_result = config_ctl.generate_configs()
        if gen_result.get('success'):
            result['message'] = '配置已保存，配置文件已生成，请重启容器使配置生效'
            result['configs_generated'] = True
        else:
            result['message'] = f'配置已保存，但生成配置文件失败: {gen_result.get("error")}'
            result['configs_generated'] = False

    return json_response(result)


@app.route('/api/config/grouped')
def get_grouped_config():
    """获取分组后的配置"""
    return json_response(config_ctl.get_grouped_config())


@app.route('/api/config/template')
def get_config_template():
    """获取配置模板（包含所有可配置项及说明）"""
    return json_response(config_ctl.get_config_template())


@app.route('/api/dns/hosts', methods=['GET', 'POST'])
def manage_dns_hosts():
    """管理 DNS 自定义解析"""
    if request.method == 'GET':
        return json_response({'content': config_ctl.get_dns_hosts()})

    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    result = config_ctl.save_dns_hosts(request.json.get('content', ''))
    if result.get('success'):
        docker_ctl.reload_dnsmasq()
        result['message'] = 'DNS 解析已更新并热重载'

    return json_response(result)


@app.route('/api/nginx/reload', methods=['POST'])
def reload_nginx():
    """重载 Nginx 配置"""
    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    result = docker_ctl.reload_nginx()
    status = 200 if result.get('success') else 400
    return json_response(result, status)


@app.route('/api/nginx/config', methods=['GET'])
def get_nginx_config():
    """获取 Nginx 配置"""
    return json_response({'content': config_ctl.get_nginx_config()})


@app.route('/api/dnsmasq/config', methods=['GET'])
def get_dnsmasq_config():
    """获取 Dnsmasq 配置"""
    return json_response({'content': config_ctl.get_dnsmasq_config()})


@app.route('/api/logs/<service>')
def get_logs(service):
    """获取服务日志"""
    # 特殊日志类型
    if service == 'proxy-manager':
        # 获取 Proxy Manager 自身日志（从 journalctl）
        import subprocess
        try:
            result = subprocess.run(
                ['journalctl', '-u', 'proxy-manager', '-n', '100', '--no-pager'],
                capture_output=True, text=True, timeout=10
            )
            return json_response({'logs': result.stdout})
        except Exception as e:
            return json_response({'logs': f'获取日志失败: {str(e)}'}, 500)

    elif service == 'deploy':
        # 获取部署日志
        result = deploy_ctl.get_deployment_logs()
        if 'error' in result:
            return json_response({'logs': result.get('error', '获取部署日志失败')}, 500)
        return json_response({'logs': result.get('output', '暂无部署日志')})

    # Docker 容器日志
    result = docker_ctl.get_logs(service)
    if 'error' in result:
        return json_response(result, 404)
    return json_response(result)


@app.route('/api/container/<name>/restart', methods=['POST'])
def restart_container(name):
    """重启容器"""
    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    result = docker_ctl.restart_container(name)
    status = 200 if result.get('success') else 400
    return json_response(result, status)


@app.route('/api/cache/clear', methods=['POST'])
def clear_cache():
    """清理缓存"""
    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    import subprocess
    cache_type = request.json.get('type', 'all')
    cache_path = '/mnt/HDD/TProxy/cache'

    if cache_type == 'all':
        subprocess.run(['rm', '-rf', f'{cache_path}/*/*'])
    else:
        subprocess.run(['rm', '-rf', f'{cache_path}/{cache_type}/*'])

    return json_response({'message': f'{cache_type} 缓存已清理'})


@app.route('/api/health')
def health_check():
    """健康检查"""
    return json_response({'status': 'ok'})


@app.route('/api/ports/check', methods=['POST'])
def check_ports():
    """检查端口是否被占用

    请求体: {'ports': [{'port': 53, 'proto': 'tcp'}, ...]}
    """
    data = request.json
    ports_to_check = data.get('ports', [])

    if not ports_to_check:
        return json_response({'error': 'No ports specified'}, 400)

    # 转换格式
    port_list = [(p['port'], p.get('proto', 'tcp')) for p in ports_to_check]

    # 获取当前容器使用的端口（允许当前容器使用的端口）
    current_config = config_ctl.get_env_config()
    allowed_ports = set()

    # 添加当前配置的端口到白名单
    try:
        if 'DNSMASQ_HOST_PORT' in current_config:
            allowed_ports.add((int(current_config['DNSMASQ_HOST_PORT']), 'tcp'))
            allowed_ports.add((int(current_config['DNSMASQ_HOST_PORT']), 'udp'))
        if 'PROXY_HOST_PORT' in current_config:
            allowed_ports.add((int(current_config['PROXY_HOST_PORT']), 'tcp'))
        if 'STATUS_HOST_PORT' in current_config:
            allowed_ports.add((int(current_config['STATUS_HOST_PORT']), 'tcp'))
    except (ValueError, KeyError):
        pass

    # 检查端口
    result = docker_ctl.check_ports(port_list)

    # 过滤掉当前容器使用的端口
    filtered_conflicts = []
    for conflict in result['conflicts']:
        port_proto = (conflict['port'], conflict['proto'])
        if port_proto not in allowed_ports:
            filtered_conflicts.append(conflict)

    result['conflicts'] = filtered_conflicts
    result['all_clear'] = len(filtered_conflicts) == 0

    return json_response(result)


@app.route('/api/config/validate', methods=['POST'])
def validate_config():
    """验证配置（包括端口检查）"""
    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    config = request.json

    # 获取当前配置和当前运行的端口
    current_config = config_ctl.get_env_config()
    current_manager_port = int(os.environ.get('PORT', 5557))
    allowed_ports = {(current_manager_port, 'tcp')}  # 当前管理程序端口

    # 添加当前配置的端口到白名单
    try:
        if 'DNSMASQ_HOST_PORT' in current_config:
            allowed_ports.add((int(current_config['DNSMASQ_HOST_PORT']), 'tcp'))
            allowed_ports.add((int(current_config['DNSMASQ_HOST_PORT']), 'udp'))
        if 'PROXY_HOST_PORT' in current_config:
            allowed_ports.add((int(current_config['PROXY_HOST_PORT']), 'tcp'))
        if 'STATUS_HOST_PORT' in current_config:
            allowed_ports.add((int(current_config['STATUS_HOST_PORT']), 'tcp'))
    except (ValueError, KeyError):
        pass

    # 收集需要检查的端口
    ports_to_check = []

    try:
        # 管理程序端口
        if 'PROXY_MANAGER_PORT' in config:
            ports_to_check.append({'port': int(config['PROXY_MANAGER_PORT']), 'proto': 'tcp'})

        # DNS 端口
        if 'DNSMASQ_HOST_PORT' in config:
            ports_to_check.append({'port': int(config['DNSMASQ_HOST_PORT']), 'proto': 'tcp'})
            ports_to_check.append({'port': int(config['DNSMASQ_HOST_PORT']), 'proto': 'udp'})

        # 代理端口
        if 'PROXY_HOST_PORT' in config:
            ports_to_check.append({'port': int(config['PROXY_HOST_PORT']), 'proto': 'tcp'})

        # 状态页端口
        if 'STATUS_HOST_PORT' in config:
            ports_to_check.append({'port': int(config['STATUS_HOST_PORT']), 'proto': 'tcp'})
    except ValueError as e:
        return json_response({'valid': False, 'errors': [f'端口号格式错误: {e}']}, 400)

    # 检查端口
    port_list = [(p['port'], p.get('proto', 'tcp')) for p in ports_to_check]
    check_result = docker_ctl.check_ports(port_list)

    errors = []
    warnings = []

    # 过滤掉当前使用的端口
    for conflict in check_result['conflicts']:
        port_proto = (conflict['port'], conflict['proto'])
        if port_proto not in allowed_ports:
            errors.append(
                f"端口 {conflict['port']}/{conflict['proto']} 已被 "
                f"{conflict['process']} (PID: {conflict['pid']}) 占用"
            )

    # 验证其他配置
    if config.get('CACHE_MAX_SIZE'):
        cache_size = config['CACHE_MAX_SIZE'].lower()
        if not cache_size.endswith(('g', 'm', 'k')):
            errors.append(f"缓存大小格式错误: {cache_size} (应为如: 1800g, 512m)")

    if config.get('NGINX_WORKER_PROCESSES'):
        worker = config['NGINX_WORKER_PROCESSES']
        if worker != 'auto':
            try:
                if int(worker) < 1:
                    errors.append(f"Worker 进程数必须大于 0")
            except ValueError:
                errors.append(f"Worker 进程数必须为数字或 'auto'")

    # 管理程序端口变更警告
    if 'PROXY_MANAGER_PORT' in config:
        new_port = int(config['PROXY_MANAGER_PORT'])
        if new_port != current_manager_port:
            warnings.append(f"管理程序端口将从 {current_manager_port} 改为 {new_port}，需要重启 Proxy Manager 服务")

    return json_response({
        'valid': len(errors) == 0,
        'errors': errors,
        'warnings': warnings,
        'port_conflicts': [c for c in check_result['conflicts']
                          if (c['port'], c['proto']) not in allowed_ports]
    })


@app.route('/api/system/status', methods=['GET'])
def get_system_status():
    """获取系统服务状态"""
    return json_response(systemd_ctl.get_service_status())


@app.route('/api/system/autostart', methods=['POST'])
def set_autostart():
    """设置开机自启"""
    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    data = request.json
    enable = data.get('enable', True)

    # 获取配置的管理端口
    config = config_ctl.get_env_config()
    port = int(config.get('PROXY_MANAGER_PORT', 5557))

    if enable:
        # 启用：安装服务、启用并启动（可以同步执行）
        result = systemd_ctl.set_auto_start(enable, port)
        status = 200 if result.get('success') else 400
        return json_response(result, status)
    else:
        # 禁用：禁用开机自启（同步），然后停止服务（异步）
        # 注意：禁用时不需要更新服务文件，直接停止和禁用即可
        # 1. 禁用开机自启
        disable_result = systemd_ctl.disable_service()
        if not disable_result.get('success'):
            status = 400
            return json_response(disable_result, status)

        # 2. 返回成功响应，然后异步停止服务
        response_data = {
            'success': True,
            'message': '服务已禁用，将在几秒后停止...'
        }

        # 使用后台线程停止服务，确保响应先返回
        import threading
        def stop_after_response():
            import time
            time.sleep(1)  # 等待响应发送
            systemd_ctl.stop_service()

        thread = threading.Thread(target=stop_after_response, daemon=True)
        thread.start()

        return json_response(response_data)


@app.route('/api/system/restart', methods=['POST'])
def restart_proxy_manager():
    """重启 Proxy Manager 服务"""
    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    result = systemd_ctl.restart_service()
    status = 200 if result.get('success') else 400
    return json_response(result, status)


@app.route('/api/deploy', methods=['POST'])
def start_deployment():
    """启动一键部署"""
    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    result = deploy_ctl.deploy()
    status = 200 if result.get('success') else 400
    return json_response(result, status)


@app.route('/api/deploy/status', methods=['GET'])
def get_deployment_status():
    """获取部署状态"""
    return json_response({
        'deploying': deploy_ctl.is_deploying(),
        'status': deploy_ctl.get_status()
    })


@app.route('/api/deploy/logs', methods=['GET'])
def get_deployment_logs():
    """获取部署日志"""
    service = request.args.get('service')
    result = deploy_ctl.get_deployment_logs(service)
    if 'error' in result:
        return json_response(result, 400)
    return json_response(result)


@app.route('/api/test', methods=['POST'])
def run_tests():
    """运行系统测试"""
    if not check_auth():
        return json_response({'error': 'Unauthorized'}, 401)

    results = {
        'ports': {},
        'dns': {},
        'proxy': {}
    }

    # 获取配置
    config = config_ctl.get_env_config()
    dns_port = config.get('DNSMASQ_HOST_PORT', '53')
    proxy_port = config.get('PROXY_HOST_PORT', '3128')
    status_port = config.get('STATUS_HOST_PORT', '8080')

    try:
        # 1. 测试端口监听
        import subprocess
        ss_result = subprocess.run(['ss', '-tunlp'], capture_output=True, text=True, timeout=5)
        ss_output = ss_result.stdout

        results['ports']['dns'] = f':{dns_port}' in ss_output
        results['ports']['proxy'] = f':{proxy_port}' in ss_output
        results['ports']['status'] = f':{status_port}' in ss_output

        # 2. 测试 DNS 解析
        dig_result = subprocess.run(['dig', '@127.0.0.1', '+short', 'www.baidu.com'],
                                      capture_output=True, text=True, timeout=10)
        results['dns']['baidu'] = dig_result.returncode == 0 and dig_result.stdout.strip() != ''
        results['dns']['output'] = dig_result.stdout.strip() if dig_result.returncode == 0 else dig_result.stderr

        # 3. 测试代理功能
        proxy_result = subprocess.run(
            ['curl', '-x', f'http://127.0.0.1:{proxy_port}', '-I', '-m', '5', 'http://www.baidu.com'],
            capture_output=True, text=True, timeout=10
        )
        results['proxy']['success'] = proxy_result.returncode == 0
        results['proxy']['output'] = proxy_result.stdout if proxy_result.returncode == 0 else proxy_result.stderr

        return json_response({
            'success': True,
            'results': results
        })
    except Exception as e:
        return json_response({'success': False, 'error': str(e)}, 500)


# ==================== 错误处理 ====================

@app.errorhandler(404)
def not_found(e):
    """404 错误处理"""
    return json_response({'error': 'Not found'}, 404)


@app.errorhandler(500)
def server_error(e):
    """500 错误处理"""
    return json_response({'error': 'Internal server error'}, 500)


# ==================== 主程序入口 ====================

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5557))
    debug = os.environ.get('DEBUG', 'False').lower() == 'true'

    print("=" * 50)
    print("  Proxy Manager Web Console")
    print("=" * 50)
    print(f"  监听地址: http://0.0.0.0:{port}")
    print(f"  Proxy 目录: {PROXY_DIR}")
    print("=" * 50)

    app.run(host='0.0.0.0', port=port, debug=debug)
