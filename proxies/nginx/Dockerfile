FROM nginx:1.27-alpine
ENV UPSTREAM_PRIMARY=example.com:443 UPSTREAM_FALLBACK=example.net:443
COPY proxies/nginx/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY proxies/nginx/docker-entrypoint.sh /docker-entrypoint.d/40-xgcpx-config.sh
RUN chmod 0555 /docker-entrypoint.d/40-xgcpx-config.sh
EXPOSE 8080