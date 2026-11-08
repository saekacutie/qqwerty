#!/bin/bash
set -Eeuo pipefail

# Raise the open-file ceiling: SSH channels, udpgw connections and WS sockets can exhaust 1024.
ulimit -n 65535 || true

# Runs a command forever, restarting it 2 seconds after it exits. Each service stays a child
# of its own loop, so a crash is noticed immediately (no zombies, no pgrep guessing).
supervise() {
  local name="$1"; shift
  while true; do
    "$@" || true
    echo "[watchdog] ${name} exited, restarting in 2s..." >&2
    sleep 2
  done
}

echo "[+] Setting SSH credentials..."
if [ -z "${SSH_PASSWORD:-}" ]; then
  if [ "${ALLOW_PASSWORD_IN_LOGS:-false}" != "true" ]; then
    echo "[!] SSH_PASSWORD is not set. Provide it (ideally from Secret Manager), or set ALLOW_PASSWORD_IN_LOGS=true to generate one and print it to the logs." >&2
    exit 1
  fi
  SSH_PASSWORD="$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))')"
  echo "[+] Generated password for user 'saeka': ${SSH_PASSWORD}"
fi
printf 'saeka:%s\n' "${SSH_PASSWORD}" | chpasswd
unset SSH_PASSWORD

echo "[+] Generating SSH host keys..."
ssh-keygen -A
mkdir -p /run/sshd

echo "[+] Writing WS-to-TCP bridge..."
cat << 'PYEOF' > /tmp/bridge.py
import socket
import threading
import time

BUF_SIZE = 65536
HANDSHAKE_TIMEOUT = 10


def tune_socket(sock):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    except OSError:
        pass


def close_quietly(sock):
    # shutdown() wakes a thread blocked in recv() on this socket; close() alone does not.
    for action in (lambda: sock.shutdown(socket.SHUT_RDWR), sock.close):
        try:
            action()
        except OSError:
            pass


def bridge(src, dst):
    try:
        while True:
            data = src.recv(BUF_SIZE)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        close_quietly(src)
        close_quietly(dst)


def handle(client):
    ssh = None
    try:
        tune_socket(client)
        client.settimeout(HANDSHAKE_TIMEOUT)
        client.recv(4096)  # discard the HTTP upgrade request
        # Connect to sshd first, so a down sshd closes the client instead of leaving a dead tunnel.
        ssh = socket.create_connection(("127.0.0.1", 22), timeout=5)
        tune_socket(ssh)
        client.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        client.settimeout(None)
        ssh.settimeout(None)
    except OSError:
        close_quietly(client)
        if ssh is not None:
            close_quietly(ssh)
        return
    threading.Thread(target=bridge, args=(client, ssh), daemon=True).start()
    threading.Thread(target=bridge, args=(ssh, client), daemon=True).start()


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 2222))
    server.listen(512)
    while True:
        try:
            client, _ = server.accept()
        except OSError as exc:
            print(f"accept failed: {exc}", flush=True)
            time.sleep(0.5)
            continue
        threading.Thread(target=handle, args=(client,), daemon=True).start()


main()
PYEOF

# --max-clients: total simultaneous tunnel clients
# --max-connections-for-client: concurrent UDP sockets per client
# --loglevel warning: avoids flooding logs with per-packet messages
UDPGW_ARGS=(
  --listen-addr 127.0.0.1:7300
  --max-clients 1000
  --max-connections-for-client 40
  --loglevel warning
)

echo "[+] Starting supervised services (sshd, udpgw, bridge)..."
supervise sshd /usr/sbin/sshd -D -e &
supervise udpgw badvpn-udpgw "${UDPGW_ARGS[@]}" &
supervise bridge python3 /tmp/bridge.py &

echo "[+] Starting Caddy..."
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
