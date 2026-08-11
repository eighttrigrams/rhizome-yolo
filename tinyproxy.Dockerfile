# Minimal tinyproxy image. We build our own instead of using monokal/tinyproxy
# because that image's entrypoint rewrites /etc/tinyproxy/tinyproxy.conf at
# startup, which fails when the config is bind-mounted (sed can't atomically
# replace a bind-mounted file). Baking the config into the image avoids that.
FROM alpine:3.20

RUN apk add --no-cache tinyproxy

COPY tinyproxy.conf   /etc/tinyproxy/tinyproxy.conf
COPY tinyproxy.filter /etc/tinyproxy/filter

EXPOSE 8888

# -d: don't daemonize (PID 1 must stay foreground for Docker).
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
