# Proxy Manager 部署指南

## 系统要求

- 操作系统: openEuler/CentOS/RHEL 8+
- Python: 3.8+
- Docker: 20.10+
- Docker Compose: 2.0+

---

## 安装步骤

### 1. 安装系统依赖

```bash
dnf install -y python3 python3-pip docker docker-compose git
```

### 2. 创建目录

```bash
mkdir -p /opt/proxy-manager
mkdir -p /opt/proxy/{dnsmasq,tengine,scripts}
```

### 3. 安装 Python 依赖

```bash
cd /opt/proxy-manager
pip3 install -r requirements.txt
```

### 4. 配置 systemd 服务

```bash
cp systemd/proxy-manager.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable proxy-manager
systemctl start proxy-manager
```

### 5. 验证

```bash
# 检查服务状态
systemctl status proxy-manager

# 检查端口
netstat -tlnp | grep 5557
```

---

## 配置 Proxy

Proxy Manager 通过修改 `/opt/proxy/.env` 来控制 Proxy 参数。

### 示例 .env

```bash
NETWORK_MODE=host
HOST_IP=192.168.91.100
PROXY_HOST_PORT=3128
DNSMASQ_HOST_PORT=53
STATUS_HOST_PORT=8080
CACHE_BASE=/mnt/HDD/TProxy/cache
```

---

## 防火墙配置

```bash
# Web 控制台
firewall-cmd --permanent --add-port=5557/tcp
# Proxy 服务
firewall-cmd --permanent --add-port=3128/tcp
# DNS 服务
firewall-cmd --permanent --add-port=53/tcp
firewall-cmd --permanent --add-port=53/udp
firewall-cmd --reload
```

---

## 访问

浏览器打开: `http://<your-ip>:5557`

默认认证: `admin` / `admin`

---

## 故障排查

### 服务无法启动

```bash
# 查看日志
journalctl -u proxy-manager -f

# 检查 Python 环境
python3 --version
pip3 list | grep flask
```

### 无法连接到 Docker

```bash
# 检查 Docker 服务
systemctl status docker

# 测试 Docker 连接
docker ps
```

### 容器状态异常

```bash
# 查看容器日志
docker logs dnsmasq
docker logs tengine

# 重启容器
docker restart dnsmasq
docker restart tengine
```
