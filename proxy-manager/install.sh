#!/bin/bash
# Proxy Manager 一键安装脚本
# 适用于 openEuler/CentOS/RHEL 8+

#set -e

INSTALL_DIR="/opt/proxy-manager"
PROXY_DIR="/opt/proxy"

echo "=== Proxy Manager 安装向导 ==="

# 1. 检查环境
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行"
    exit 1
fi

# 2. 安装依赖
echo "安装系统依赖..."
dnf install -y python3 python3-pip docker docker-compose git

echo " 3. 创建目录"
mkdir -p ${INSTALL_DIR} ${PROXY_DIR}
cd ${INSTALL_DIR}

# 4. 部署 Proxy 基础环境（之前的 docker-compose 方案）
echo "部署 Tengine + Dnsmasq 基础环境..."

# 创建基础目录结构
mkdir -p ${PROXY_DIR}/{dnsmasq/{hosts.d,conf.d,logs},tengine/{conf.d,logs,temp},scripts}
mkdir -p /mnt/HDD/cache/Tengine/{docker,yum,github,other}
chown -R 101:101 ${PROXY_DIR}/tengine/logs ${PROXY_DIR}/tengine/temp /mnt/HDD/cache/Tengine

# 写入默认 .env
cat > ${PROXY_DIR}/.env << 'EOF'
NETWORK_MODE=host
DNSMASQ_HOST_PORT=53
DNSMASQ_CONTAINER_PORT=53
PROXY_HOST_PORT=3128
PROXY_CONTAINER_PORT=3128
STATUS_HOST_PORT=8080
STATUS_CONTAINER_PORT=8080
HOST_IP=192.168.91.100
CACHE_BASE=/mnt/HDD/cache/Tengine
EOF

# 5. 安装 Python Web 控制台
echo "安装 Web 控制台..."

pip3 install flask flask-cors docker requests pyyaml -i https://pypi.tuna.tsinghua.edu.cn/simple

# 6. 生成应用代码（这里简化为下载，实际应包含完整代码）
cat > ${INSTALL_DIR}/app.py << 'PYTHON_EOF'
[见下方 Python 代码]
PYTHON_EOF

# 7. 创建 systemd 服务
cat > /etc/systemd/system/proxy-manager.service << EOF
[Unit]
Description=Proxy Manager Web Console
After=docker.service network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/app.py
Restart=always
RestartSec=5
User=root
Environment="PROXY_DIR=${PROXY_DIR}"

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务
systemctl daemon-reload
systemctl enable proxy-manager
systemctl start proxy-manager

echo "=== 安装完成 ==="
echo "访问地址: http://$(hostname -I | awk '{print $1}'):5000"
echo "默认密码: admin / admin"
