# TProxy

> 基于 Tengine + Dnsmasq + Docker 的智能代理服务器管理系统

TProxy 是一个功能完整的代理缓存服务器解决方案，专为国内网络环境优化，提供 Web 控制台进行可视化管理。

![License](https://img.shields.io/badge/license-MIT-blue)
![Python](https://img.shields.io/badge/python-3.8+-green)
![Docker](https://img.shields.io/badge/docker-20.10+-blue)

## 功能特性

### 核心功能
- **智能缓存代理**: 基于 Tengine 的 HTTP/HTTPS 代理，支持 Docker/YUM/GitHub 等多种缓存
- **DNS 劫持解析**: Dnsmasq 实现 DNS 劫持，透明代理常见镜像源
- **Web 管理界面**: Vue3 + Flask 构建的现代化控制台
- **一键部署**: 支持一键部署和重建，自动基于保存的参数配置

### 管理功能
- **状态监控**: 实时显示容器状态、Nginx 连接数、缓存大小、系统资源
- **参数管理**: Web 界面修改端口、网络模式、IP 等配置
- **DNS 管理**: 可视化编辑自定义 DNS 解析规则，支持热重载
- **日志查看**: 实时查看 Tengine、Dnsmasq、Proxy Manager、部署日志
- **容器管理**: 一键重启指定容器
- **缓存清理**: 按类型清理缓存（全部/Docker/YUM/GitHub）
- **热重载**: Nginx 配置测试后重载，安全可靠
- **系统服务**: 支持开机自启，可配置系统服务
- **系统测试**: 一键测试端口监听、DNS 解析、代理功能

## TPoxy - 单文件配置方案（推荐）

除了传统的 Web 控制台方式，TProxy 还提供了 **TPoxy** 方案：
- 基于 `hosts-master.txt` 单文件配置
- 修改后 5 秒自动生效
- 支持智能分类缓存
- 支持真实 IP 直连
- 适合生产环境快速部署

详见 [TPoxy 文档](/mnt/HDD/TPoxy/README.md)

快速启动：
```bash
cd /mnt/HDD/TPoxy
./deploy.sh 192.168.0.36  # 使用你的代理服务器 IP
```

## 项目结构

```
/opt/TProxy/
├── docs/                     # 项目文档
│   ├── README.md            # 文档索引
│   ├── architecture.md      # 生产环境架构
│   ├── known-issues.md      # 已知问题
│   ├── proxy-cache-research.md  # 代理缓存方案调研
│   └── proxy-manager/       # 管理端文档
│       ├── API.md           # API 接口文档
│       ├── DEPLOY.md        # 部署指南
│       └── README.md        # 详细说明
├── proxy-manager/           # Proxy Manager 管理控制台
│   ├── main.py              # 主入口文件
│   ├── backend/             # 后端模块
│   │   ├── docker_ctl.py    # Docker 容器控制
│   │   ├── config_ctl.py    # 配置文件管理
│   │   ├── monitor.py       # 监控数据采集
│   │   ├── systemd_ctl.py   # systemd 服务管理
│   │   └── deploy_ctl.py    # 部署控制
│   ├── static/              # 前端资源
│   │   ├── index.html       # 单页应用入口
│   │   ├── css/             # 样式文件
│   │   ├── js/              # JavaScript 代码
│   │   └── assets/          # 静态资源
│   ├── systemd/             # systemd 服务文件
│   ├── config/              # 配置模块
│   ├── install.sh           # 安装脚本
│   └── requirements.txt     # Python 依赖
└── proxy/                   # 代理服务配置
    ├── docker-compose.yml   # Docker Compose 配置
    ├── .env                 # 环境变量配置
    ├── tengine/             # Tengine 配置目录
    │   └── Dockerfile
    └── scripts/             # 辅助脚本

# 数据目录（自动创建）
/mnt/HDD/TProxy/
├── cache/                   # 缓存目录
│   ├── docker/              # Docker 镜像缓存
│   ├── yum/                 # YUM 软件包缓存
│   ├── github/              # GitHub 资源缓存
│   └── other/               # 其他缓存
├── dnsmasq/                 # Dnsmasq 配置输出
│   └── dnsmasq.conf         # 自动生成的配置文件
└── tengine/                 # Tengine 配置输出
    └── nginx.conf           # 自动生成的配置文件
```

## 快速开始

### 系统要求

- 操作系统: openEuler/CentOS/RHEL 8+
- Python: 3.8+
- Docker: 20.10+
- Docker Compose: 2.0+

### 安装

```bash
# 1. 克隆项目
git clone https://github.com/grigs28/TProxy.git /opt/TProxy

# 2. 安装 Python 依赖
cd /opt/TProxy/proxy-manager
pip3 install -r requirements.txt

# 3. 配置 systemd 服务（可选，用于开机自启）
./install.sh

# 或手动配置
cp systemd/proxy-manager.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable proxy-manager
systemctl start proxy-manager
```

### 访问控制台

打开浏览器访问: `http://<your-ip>:5557`

默认认证: `admin` / `admin`

### 配置代理参数

在 Web 控制台中配置以下参数：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| NETWORK_MODE | 网络模式 | host |
| HOST_IP | 本机 IP | 192.168.0.36 |
| PROXY_HOST_PORT | 代理端口 | 3128 |
| DNSMASQ_HOST_PORT | DNS 端口 | 53 |
| STATUS_HOST_PORT | 状态页端口 | 8088 |
| CACHE_BASE | 缓存目录 | /mnt/HDD/TProxy/cache |
| PROXY_MANAGER_PORT | 管理界面端口 | 5557 |
| AUTO_START | 随系统启动 | false |

配置完成后，点击「一键部署」即可启动代理服务。

### 新增功能

- **一键部署**: 自动应用配置、创建目录、构建镜像、启动服务
- **系统测试**: 测试端口监听、DNS 解析、代理功能
- **配置验证**: 保存前验证端口冲突、配置格式
- **自动重启**: 管理程序端口变更时自动重启服务

## 文档

详细文档请查看 [docs/](docs/) 目录：

**管理端**

- [API 文档](docs/proxy-manager/API.md) - RESTful API 接口说明
- [部署指南](docs/proxy-manager/DEPLOY.md) - 详细的部署和配置说明
- [详细说明](docs/proxy-manager/README.md) - 项目详细介绍

**运行环境**

- [架构总览](docs/architecture.md) - 生产环境架构与容器清单
- [已知问题](docs/known-issues.md) - 已知问题与排查结论
- [方案调研](docs/proxy-cache-research.md) - 代理缓存替代方案调研

## 配置示例

### Docker HTTP 代理

```bash
# 配置 Docker 使用本机代理
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null <<EOF
[Service]
Environment="HTTP_PROXY=http://<HOST_IP>:<PROXY_HOST_PORT>"
Environment="HTTPS_PROXY=http://<HOST_IP>:<PROXY_HOST_PORT>"
Environment="NO_PROXY=localhost,127.0.0.1"
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker
```

### YUM/DNF 代理

```bash
# 编辑 /etc/dnf/dnf.conf
proxy=http://<HOST_IP>:<PROXY_HOST_PORT>
```

### DNS 劫持

在 Web 控制台 DNS 配置中添加：

```
address=/docker.io/<HOST_IP>
address=/gcr.io/<HOST_IP>
address=/quay.io/<HOST_IP>
address=/github.com/<HOST_IP>
```

## 开发

```bash
# 开发模式启动
cd /opt/TProxy/proxy-manager
python3 main.py

# 运行测试
python3 -m pytest tests/
```

## API 示例

```bash
# 获取状态
curl http://localhost:5557/api/status

# 获取配置
curl http://localhost:5557/api/config

# 更新配置（需要认证）
curl -X POST http://localhost:5557/api/config \
  -H "Authorization: Basic admin:admin" \
  -H "Content-Type: application/json" \
  -d '{"PROXY_HOST_PORT": "3128"}'

# 重载 Nginx
curl -X POST http://localhost:5557/api/nginx/reload \
  -H "Authorization: Basic admin:admin"
```

## 防火墙配置

```bash
# Web 控制台
firewall-cmd --permanent --add-port=5557/tcp

# Proxy 服务
firewall-cmd --permanent --add-port=3128/tcp

# DNS 服务
firewall-cmd --permanent --add-port=53/tcp
firewall-cmd --permanent --add-port=53/udp

# 状态页
firewall-cmd --permanent --add-port=8080/tcp

firewall-cmd --reload
```

## 故障排查

### 服务无法启动

```bash
# 查看日志
journalctl -u proxy-manager -f

# 检查 Python 环境
python3 --version
pip3 list | grep flask
```

### 容器状态异常

```bash
# 查看容器日志
cd /opt/TProxy/proxy
docker-compose logs dnsmasq
docker-compose logs tengine

# 重启容器
docker-compose restart dnsmasq
docker-compose restart tengine
```

### 一键部署失败

在 Web 控制台查看部署日志，或执行：

```bash
cd /opt/TProxy/proxy
docker-compose down
docker-compose build tengine
docker-compose up -d
```

## License

MIT License - 详见 [LICENSE](LICENSE) 文件

## 贡献

欢迎提交 Issue 和 Pull Request！

## 作者

grigs28

## 鸣谢

- [Tengine](http://tengine.taobao.org/) - 淘宝开源的 Nginx 分支
- [Dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) - 轻量级 DNS/DHCP 服务器
- [Flask](https://flask.palletsprojects.com/) - Python Web 框架
- [Vue.js](https://vuejs.org/) - 渐进式 JavaScript 框架
