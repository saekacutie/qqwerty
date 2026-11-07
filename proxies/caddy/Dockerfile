# Track Caddy's v2 major line on Alpine; this is a major-version tag, not an immutable patch pin.
FROM caddy:2-alpine
ENV UPSTREAM_PRIMARY=http://127.0.0.1:8081 UPSTREAM_FALLBACK=http://127.0.0.1:8081 PROTOCOL_UPSTREAM=http://127.0.0.1:8081 PROTOCOL_UPSTREAM_HOST=127.0.0.1
COPY proxies/caddy/Caddyfile /etc/caddy/Caddyfile
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1