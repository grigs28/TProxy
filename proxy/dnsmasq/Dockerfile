# TProxy dnsmasq 镜像
# 预装 dnsmasq，避免容器每次启动都 apk add（依赖外网、启动慢）
FROM alpine:3.19

# 官方源 dl-cdn.alpinelinux.org 在国内不可达（实测超时），换阿里云镜像
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories \
 && apk add --no-cache dnsmasq \
 && rm -rf /var/cache/apk/*

EXPOSE 53/tcp 53/udp

ENTRYPOINT ["dnsmasq"]
CMD ["-k", "-C", "/etc/dnsmasq.conf"]
