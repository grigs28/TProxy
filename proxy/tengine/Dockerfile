FROM alpine:3.18 AS builder

RUN apk add --no-cache gcc g++ make pcre-dev zlib-dev openssl-dev linux-headers git

WORKDIR /usr/local/src

# 使用宿主机已下载的源码（不再网络下载）
COPY 3.1.0.tar.gz /usr/local/src/
RUN tar -zxvf 3.1.0.tar.gz && \
    cd tengine-3.1.0 && \
    ./configure \
        --prefix=/usr/local/tengine \
        --user=nginx \
        --group=nginx \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_stub_status_module \
        --with-http_realip_module \
        --add-module=modules/ngx_http_proxy_connect_module \
        --with-stream && \
    make -j$(nproc) && \
    make install

FROM alpine:3.18

RUN apk add --no-cache pcre zlib openssl && \
    addgroup -S nginx -g 101 && \
    adduser -S nginx -u 101 -G nginx

COPY --from=builder /usr/local/tengine /usr/local/tengine

RUN mkdir -p /data/cache /usr/local/tengine/logs && \
    chown -R nginx:nginx /data/cache /usr/local/tengine/logs

EXPOSE 3128 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/status || exit 1

CMD ["/usr/local/tengine/sbin/nginx", "-g", "daemon off;"]
