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
EXPOSE 4999

# 健康检查：只探端口是否在监听。
# 不能用 HTTP 请求 —— gitcache 是 git 协议代理而非网页服务器，
# 对 / 的请求会返回错误（upstream prematurely closed connection），恒判失败。
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD nc -z 127.0.0.1 4999 || exit 1

# 默认命令
ENTRYPOINT ["/usr/local/bin/gitcache"]
CMD ["-b", "/var/gitcache"]
