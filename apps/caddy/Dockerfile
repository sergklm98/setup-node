FROM docker.io/library/caddy:builder-alpine AS builder

ARG XCADDY_ARGS=""
RUN xcaddy build $XCADDY_ARGS

FROM docker.io/library/alpine:latest AS runner

ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data

RUN apk add --no-cache \
    ca-certificates \
    libcap \
    mailcap \
    curl \
    tzdata \
    && mkdir -p /etc/caddy /config/caddy /data/caddy

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

RUN chmod 755 /usr/bin/caddy \
    && setcap cap_net_bind_service=+ep /usr/bin/caddy

EXPOSE 80 443 443/udp 2019
WORKDIR /etc/caddy

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
