FROM caddy:2-alpine

ARG XRAY_VERSION=26.10.31
ARG XRAY_SHA256=e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214

RUN apk add --no-cache ca-certificates curl openssh-server python3 su-exec unzip \
    && curl --fail --silent --show-error --location \
      "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip" \
      --output /tmp/xray.zip \
    && echo "${XRAY_SHA256}  /tmp/xray.zip" | sha256sum -c - \
    && unzip -p /tmp/xray.zip xray > /usr/local/bin/xray \
    && chmod 0555 /usr/local/bin/xray \
    && rm -f /tmp/xray.zip

COPY proxies/xray/Caddyfile /etc/caddy/Caddyfile
COPY proxies/xray/entrypoint.sh /usr/local/bin/xgcpx-xray-entrypoint
RUN chmod 0555 /usr/local/bin/xgcpx-xray-entrypoint

COPY proxies/xray/sshd_config /etc/ssh/sshd_config
USER 0:0
EXPOSE 8080/tcp 8443/tcp 8081/tcp 50052/tcp 8388/tcp 8388/udp 10007/tcp 10008/tcp 10009/tcp
ENTRYPOINT ["/usr/local/bin/xgcpx-xray-entrypoint"]
