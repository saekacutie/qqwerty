FROM envoyproxy/envoy:v1.32-latest
ENV UPSTREAM_PRIMARY=https://example.com \
	UPSTREAM_FALLBACK=https://example.net \
	TCP_UPSTREAM_HOST=tcp.example.com:9000 \
	TLS_UPSTREAM_HOST=tls.example.com:9443
USER root
# Avoid interactive package prompts during Cloud Build/container image creation.
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates gettext-base \
	&& rm -rf /var/lib/apt/lists/*
COPY proxies/envoy/envoy.yaml.template /etc/envoy/envoy.yaml.template
COPY proxies/envoy/docker-entrypoint.sh /usr/local/bin/xgcpx-entrypoint
RUN chmod 0555 /usr/local/bin/xgcpx-entrypoint
USER envoy
EXPOSE 8080 9000 9443
ENTRYPOINT ["/usr/local/bin/xgcpx-entrypoint"]