FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server python3 cmake build-essential git wget curl ca-certificates \
    debian-keyring debian-archive-keyring apt-transport-https gnupg \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Caddy (official Cloudsmith apt repo)
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y caddy \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Build BadVPN UDPGW for Gaming UDP Support
RUN git clone https://github.com/ambrop72/badvpn.git /tmp/badvpn \
    && cd /tmp/badvpn && mkdir build && cd build \
    && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
    && make install && rm -rf /tmp/badvpn

# Setup SSH and User
RUN mkdir -p /var/run/sshd
# FIXED: this previously created a user named "saeka" but set a password for
# "master" - chpasswd fails on a nonexistent user, which broke the entire
# Docker build at this step. Now creates the same user the credentials
# actually advertise.
RUN useradd -m -s /bin/bash saeka && echo 'saeka:saeka' | chpasswd
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Stability/perf tuning: skip reverse-DNS on connect (removes real handshake delay),
# keep idle sessions alive instead of dropping them, and raise multiplexing ceilings
# so many parallel channels (typical for gaming/streaming tunnels) don't get throttled.
RUN { \
    echo "UseDNS no"; \
    echo "TCPKeepAlive yes"; \
    echo "ClientAliveInterval 15"; \
    echo "ClientAliveCountMax 3"; \
    echo "MaxSessions 50"; \
    echo "MaxStartups 50:30:100"; \
    echo "Compression no"; \
    } >> /etc/ssh/sshd_config

# Add Custom Aesthetic Banner
COPY banner.txt /etc/ssh/banner.txt
RUN echo "Banner /etc/ssh/banner.txt" >> /etc/ssh/sshd_config

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
