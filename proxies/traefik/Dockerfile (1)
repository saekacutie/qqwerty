FROM traefik:v3.6

RUN apk add --no-cache ca-certificates gettext
ENV UPSTREAM_PRIMARY=http://127.0.0.1:8081 \
    UPSTREAM_FALLBACK=http://127.0.0.1:8081 \
    PROTOCOL_UPSTREAM=http://127.0.0.1:8081
COPY proxies/traefik/traefik.yml /etc/traefik/traefik.yml
COPY proxies/traefik/dynamic.yml.template /etc/traefik/dynamic.yml.template
COPY proxies/traefik/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod 0555 /docker-entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/docker-entrypoint.sh"]
