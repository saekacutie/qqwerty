# Tracks Caddy's v2 major line on Alpine. For reproducible builds, pin a full version tag such as caddy:2.x.y-alpine.
FROM caddy:2-alpine

ENV UPSTREAM_PRIMARY=http://127.0.0.1:8081 \
    UPSTREAM_FALLBACK=http://127.0.0.1:8081 \
    PROTOCOL_UPSTREAM=http://127.0.0.1:8081

COPY proxies/caddy/Caddyfile /etc/caddy/Caddyfile

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
