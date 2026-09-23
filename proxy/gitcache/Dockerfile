# Git Cache Docker 镜像 - 用于缓存 Git 仓库
# 基于 Alpine Linux

# 构建阶段
FROM alpine:3.19 AS builder

# 安装编译工具和 Go
RUN apk add --no-cache go git make musl-dev gcc

# Go 环境变量
ENV GO111MODULE=on \
    GOPROXY=https://goproxy.cn,direct \
    CGO_ENABLED=0

# 创建用户
RUN addgroup -g 1000 gitcache && \
    adduser -D -u 1000 -G gitcache -h /home/gitcache gitcache

# 下载并编译 gitcache
WORKDIR /go/src/github.com/git-cloner/gitcache
RUN git clone https://github.com/git-cloner/gitcache . && \
    go mod tidy && \
    go build -o /usr/local/bin/gitcache .

# 运行阶段
FROM alpine:3.19

# 安装运行时依赖
RUN apk add --no-cache git openssh-client findutils curl

# 复制编译好的程序
COPY --from=builder /usr/local/bin/gitcache /usr/local/bin/gitcache

# 创建运行用户和目录
RUN addgroup -g 1000 gitcache && \
    adduser -D -u 1000 -G gitcache -h /home/gitcache gitcache && \
    mkdir -p /var/gitcache && \
    chown gitcache:gitcache /var/gitcache

# 切换用户
USER gitcache
WORKDIR /home/gitcache

# 暴露端口
EXPOSE 5000

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O- http://localhost:5000/ || exit 1

# 默认命令
ENTRYPOINT ["/usr/local/bin/gitcache"]
CMD ["-b", "/var/gitcache"]
