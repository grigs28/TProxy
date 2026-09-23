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

RUN pip install --no-cache-dir flask

COPY . /app

# 仅监听回环（见 app.py）。容器用 host 网络，故等价于只对本机暴露。
EXPOSE 5557

CMD ["python3", "app.py"]
