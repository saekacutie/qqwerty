
FROM traefik:v3.2

RUN apk add --no-cache ca-certificates gettext

ENV UPSTREAM_PRIMARY="" \
    UPSTREAM_FALLBACK="" \
    PROTOCOL_UPSTREAM=""

COPY proxies/traefik/traefik.yml /etc/traefik/traefik.yml
COPY proxies/traefik/dynamic.yml.template /etc/traefik/dynamic.yml.template
COPY proxies/traefik/docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod 0555 /docker-entrypoint.sh

EXPOSE 8080

STOPSIGNAL SIGTERM

ENTRYPOINT ["/docker-entrypoint.sh"]
