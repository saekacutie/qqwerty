FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# iproute2 provides the `ip` command used by openvpn-up.sh.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl iproute2 iptables openvpn python3 \
    && rm -rf /var/lib/apt/lists/*

COPY proxies/openvpn/server.conf /etc/openvpn/server.conf
COPY proxies/openvpn/entrypoint.sh /usr/local/bin/xgcpx-openvpn-entrypoint
COPY proxies/openvpn/openvpn-up.sh /usr/local/bin/xgcpx-openvpn-up
RUN chmod 0555 /usr/local/bin/xgcpx-openvpn-entrypoint /usr/local/bin/xgcpx-openvpn-up

EXPOSE 1194/udp
ENTRYPOINT ["/usr/local/bin/xgcpx-openvpn-entrypoint"]
