# Proxy Manager API 文档

## 认证

所有写操作（POST）需要 Basic Auth：

```
Authorization: Basic admin:admin
```

---

## 状态接口

### GET /api/status

获取系统整体状态

**响应示例**:
```json
{
  "containers": {
    "dnsmasq": {
      "name": "dnsmasq",
      "status": "running",
      "health": "healthy",
      "started": "2026-02-17T00:00:00.000Z"
    },
    "tengine": {
      "name": "tengine",
      "status": "running",
      "health": "unhealthy",
      "started": "2026-02-17T00:00:00.000Z"
    }
  },
  "nginx": {
    "active_connections": "10",
    "accepts": "1000",
    "handled": "1000",
    "requests": "5000"
  },
  "cache_size": "150G",
  "disk": {
    "total": "2T",
    "used": "500G",
    "available": "1.5T",
    "percent": "25%"
  },
  "system": {
    "hostname": "proxy-server",
    "timestamp": "2026-02-17T10:30:00",
    "uptime": "up 1 day"
  }
}
```

---

## 配置接口

### GET /api/config

获取 .env 配置

**响应示例**:
```json
{
  "NETWORK_MODE": "host",
  "HOST_IP": "192.168.91.100",
  "PROXY_HOST_PORT": "3128",
  "DNSMASQ_HOST_PORT": "53",
  "STATUS_HOST_PORT": "8080",
  "CACHE_BASE": "/mnt/HDD/TProxy/cache"
}
```

### POST /api/config

更新 .env 配置（需要认证）

**请求体**:
```json
{
  "NETWORK_MODE": "host",
  "HOST_IP": "192.168.91.100",
  "PROXY_HOST_PORT": "3128"
}
```

**响应**:
```json
{
  "success": true,
  "message": "配置已保存"
}
```

---

## DNS 接口

### GET /api/dns/hosts

获取 DNS 自定义解析配置

**响应示例**:
```json
{
  "content": "address=/quay.io/192.168.91.100\naddress=/gcr.io/192.168.91.100"
}
```

### POST /api/dns/hosts

更新 DNS 解析并热重载（需要认证）

**请求体**:
```json
{
  "content": "address=/quay.io/192.168.91.100"
}
```

---

## Nginx 接口

### POST /api/nginx/reload

重载 Nginx 配置（需要认证）

**响应**:
```json
{
  "success": true,
  "message": "Nginx 配置已重载"
}
```

### GET /api/nginx/config

获取 Nginx 配置内容

---

## 日志接口

### GET /api/logs/<service>

获取服务日志

**参数**:
- `service`: `tengine` | `dnsmasq`

**响应**:
```json
{
  "success": true,
  "logs": "日志内容..."
}
```

---

## 容器接口

### POST /api/container/<name>/restart

重启容器（需要认证）

**参数**:
- `name`: `dnsmasq` | `tengine`

---

## 缓存接口

### POST /api/cache/clear

清理缓存（需要认证）

**请求体**:
```json
{
  "type": "all"
}
```

**参数**:
- `type`: `all` | `docker` | `yum` | `github`

---

## 健康检查

### GET /api/health

服务健康检查

**响应**:
```json
{
  "status": "ok"
}
```
