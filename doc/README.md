# Proxy Manager

Proxy Manager 是一个基于 **Tengine + Dnsmasq + Docker** 的代理服务器管理系统，提供 Web 控制台来管理加速节点。

## 功能特性

- **状态监控**: 实时显示 Dnsmasq/Tengine 运行状态、Nginx 连接数、缓存大小
- **参数管理**: Web 修改 `.env` 配置（端口、网络模式、IP等）
- **DNS 管理**: 可视化编辑自定义 DNS 解析，支持热重载
- **日志查看**: 实时查看 Tengine 和 Dnsmasq 日志
- **热重载**: 一键重载 Nginx 配置（先测试后重载）
- **缓存清理**: 按类型清理缓存（Docker/YUM/GitHub）
- **容器管理**: 重启指定容器

## 项目结构

```
/opt/proxy-manager/
├── main.py              # 主入口文件
├── backend/             # 后端模块
│   ├── __init__.py
│   ├── docker_ctl.py    # Docker 容器控制
│   ├── config_ctl.py    # 配置文件读写
│   └── monitor.py       # 监控数据采集
├── static/              # 前端文件
│   ├── index.html       # 单页应用
│   ├── css/             # 样式文件
│   ├── js/              # 脚本文件
│   └── assets/          # 静态资源
├── docs/                # 文档
├── tests/               # 测试
├── systemd/             # 系统服务
├── config/              # 配置模板
├── templates/           # 配置模板
└── scripts/             # 脚本
```

## 快速开始

### 安装依赖

```bash
pip3 install -r requirements.txt
```

### 启动服务

```bash
# 直接启动
python3 main.py

# 或使用 systemd
cp systemd/proxy-manager.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now proxy-manager
```

### 访问

打开浏览器访问: `http://<your-ip>:5557`

默认认证: `admin` / `admin`

## 配置说明

### 环境变量 (.env)

| 变量 | 说明 | 默认值 |
|------|------|--------|
| NETWORK_MODE | 网络模式 | host |
| HOST_IP | 本机 IP | 192.168.91.100 |
| PROXY_HOST_PORT | 代理端口 | 3128 |
| DNSMASQ_HOST_PORT | DNS 端口 | 53 |
| STATUS_HOST_PORT | 状态页端口 | 8080 |
| CACHE_BASE | 缓存目录 | /mnt/HDD/TProxy/cache |

## API 接口

| 路由 | 方法 | 功能 |
|------|------|------|
| `/api/status` | GET | 获取系统状态 |
| `/api/config` | GET/POST | 管理 .env 配置 |
| `/api/dns/hosts` | GET/POST | 管理 DNS 解析 |
| `/api/nginx/reload` | POST | 重载 Nginx |
| `/api/logs/<service>` | GET | 查看日志 |
| `/api/cache/clear` | POST | 清理缓存 |
| `/api/container/<name>/restart` | POST | 重启容器 |

## 开发规范

- 文档放 `docs/` 目录
- 测试放 `tests/` 目录
- Python 模块按功能分类到 `backend/`
- CSS 放 `static/css/`
- JS 放 `static/js/`

## License

MIT
