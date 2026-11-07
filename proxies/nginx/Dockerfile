FROM nginx:1.27-alpine
ENV UPSTREAM_PRIMARY=http://127.0.0.1:8081 UPSTREAM_FALLBACK=http://127.0.0.1:8081 PROTOCOL_UPSTREAM=http://127.0.0.1:8081
COPY proxies/nginx/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY proxies/nginx/docker-entrypoint.sh /docker-entrypoint.d/40-xgcpx-config.sh
RUN chmod 0555 /docker-entrypoint.d/40-xgcpx-config.sh
EXPOSE 8080