#!/bin/bash
set -e

# Raise open-file ceiling before anything starts - SSH channels + udpgw
# connections + WS sockets can exhaust the default 1024 limit under load,
# which shows up as random, hard-to-diagnose disconnects.
ulimit -n 65535 || true

echo "[+] Generating SSH Host Keys..."
ssh-keygen -A
mkdir -p /run/sshd

echo "[+] Starting SSH Daemon..."
/usr/sbin/sshd

echo "[+] Starting BadVPN UDPGW (tuned for high-throughput gaming UDP)..."
# --max-clients: total simultaneous tunnel clients
# --max-connections-for-client: concurrent UDP sockets PER client (this is what
#   causes "out of UDP buffer" under bursty gaming traffic if left too low)
# --loglevel warning: stop flooding stdout/Cloud Logging with per-packet errors,
#   which itself costs CPU and log-ingestion overhead under load
badvpn-udpgw \
  --listen-addr 127.0.0.1:7300 \
  --max-clients 1000 \
  --max-connections-for-client 40 \
  --loglevel warning &
UDPGW_PID=$!

echo "[+] Creating Optimized WS-to-TCP Bridge..."
cat << 'PYEOF' > /tmp/bridge.py
import socket, threading

BUF_SIZE = 65536  # bigger buffer = fewer syscalls, higher throughput

def tune_socket(sock):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)  # kill Nagle-induced latency
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    except OSError:
        pass

def bridge(src, dst):
    try:
        while True:
            data = src.recv(BUF_SIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        src.close()
        dst.close()

def handle(client):
    try:
        tune_socket(client)
        client.recv(4096)
        client.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tune_socket(ssh)
        ssh.connect(('127.0.0.1', 22))
        threading.Thread(target=bridge, args=(client, ssh), daemon=True).start()
        threading.Thread(target=bridge, args=(ssh, client), daemon=True).start()
    except Exception:
        client.close()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 2222))
server.listen(200)
while True:
    client, _ = server.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PYEOF

python3 /tmp/bridge.py &
BRIDGE_PID=$!

echo "[+] Starting Watchdog (auto-restarts sshd/udpgw/bridge if any crash)..."
(
  while true; do
    sleep 10
    if ! kill -0 "$UDPGW_PID" 2>/dev/null; then
      echo "[watchdog] udpgw died, restarting..."
      badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 \
        --max-connections-for-client 40 --loglevel warning &
      UDPGW_PID=$!
    fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "[watchdog] bridge died, restarting..."
      python3 /tmp/bridge.py &
      BRIDGE_PID=$!
    fi
    if ! pgrep -x sshd > /dev/null; then
      echo "[watchdog] sshd died, restarting..."
      /usr/sbin/sshd
    fi
  done
) &

echo "[+] Starting Optimized Nginx..."
exec nginx -g "daemon off;"
