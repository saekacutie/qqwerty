# Pin this to a specific patch release (for example, v1.32.x) for reproducible builds.
ARG ENVOY_IMAGE=envoyproxy/envoy:v1.32-latest
FROM ${ENVOY_IMAGE}

ENV UPSTREAM_PRIMARY=http://127.0.0.1:8081 \
    UPSTREAM_FALLBACK=http://127.0.0.1:8081 \
    PROTOCOL_UPSTREAM=http://127.0.0.1:8081 \
    TCP_UPSTREAM_HOST=tcp.example.com:9000 \
    TLS_UPSTREAM_HOST=tls.example.com:9443

USER root

# Avoid interactive package prompts during image builds.
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY proxies/envoy/envoy.yaml.template /etc/envoy/envoy.yaml.template
COPY proxies/envoy/docker-entrypoint.sh /usr/local/bin/xgcpx-entrypoint
RUN chmod 0555 /usr/local/bin/xgcpx-entrypoint \
    && chmod 0444 /etc/envoy/envoy.yaml.template

USER envoy

EXPOSE 8080 9000 9443

ENTRYPOINT ["/usr/local/bin/xgcpx-entrypoint"]
