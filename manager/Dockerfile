# TProxy 管理界面
#
# 用 slim 基础镜像；flask 是唯一运行时依赖。
# 镜像内不包含 openssl 之外的工具 —— 本服务只读配置与统计缓存。
FROM python:3.12-slim

# openssl 用于读取证书到期时间（backend/certs.py）
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# requests 用于向 yz-login 验证 ticket
RUN pip install --no-cache-dir flask requests

COPY . /app

# 监听地址由 MANAGER_BIND 控制（默认 0.0.0.0）。
# 安全边界不靠绑定地址，而靠 yz-login SSO 认证 + 仅管理员可入。
EXPOSE 5557

CMD ["python3", "app.py"]
