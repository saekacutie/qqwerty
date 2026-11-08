#!/bin/sh
set -eu
umask 077

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${PROTOCOL_SECRET_NAME:?PROTOCOL_SECRET_NAME is required}"
if [ "${PROTOCOL_HTTP_ONLY:-false}" != "true" ]; then
  : "${RELAY_DOMAIN:?RELAY_DOMAIN is required}"
fi

# Plenty of file descriptors for many concurrent tunnels ("too many open files" shows up as random I/O errors).
ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true

# Caddy and Xray run as an unprivileged uid with no passwd entry; give them writable, predictable homes.
export HOME=/tmp
export XDG_DATA_HOME=/data
export XDG_CONFIG_HOME=/config
mkdir -p /data /config /run/xgcpx
chown 10001:10001 /data /config 2>/dev/null || true

metadata_url="http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
secret_url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PROTOCOL_SECRET_NAME}/versions/latest:access"

# Both the metadata server and the IAM binding can lag behind container start; retry instead of crash-looping.
access_token=""
attempt=0
while [ "$attempt" -lt 20 ]; do
  if token_json="$(curl --fail --silent --show-error \
    --connect-timeout 3 --max-time 15 \
    --header 'Metadata-Flavor: Google' "$metadata_url")"; then
    access_token="$(printf '%s' "$token_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' 2>/dev/null || true)"
    [ -z "$access_token" ] || break
  fi
  attempt=$((attempt + 1))
  sleep 3
done
[ -n "$access_token" ] || { printf '%s\n' "Unable to obtain a service-account access token from the metadata server." >&2; exit 1; }

secret_json=""
attempt=0
while [ "$attempt" -lt 20 ]; do
  if secret_json="$(curl --fail --silent --show-error \
    --connect-timeout 3 --max-time 15 \
    --header "Authorization: Bearer ${access_token}" "$secret_url")"; then
    break
  fi
  secret_json=""
  attempt=$((attempt + 1))
  sleep 5
done
[ -n "$secret_json" ] || { printf '%s\n' "Unable to read the protocol config from Secret Manager." >&2; exit 1; }

printf '%s' "$secret_json" | python3 -c '
import base64
import json
import os
import sys

payload = json.loads(base64.b64decode(json.load(sys.stdin)["payload"]["data"]))
with open("/tmp/xray-config.json", "w", encoding="utf-8") as config_file:
    json.dump(payload["xray_config"], config_file)
password = payload.get("ssh_password", "")
if password:
    fd = os.open("/run/xgcpx/ssh-password", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as password_file:
        password_file.write(password)
'
unset token_json access_token secret_json
chown 10001:10001 /tmp/xray-config.json
chmod 0600 /tmp/xray-config.json

xray run -test -config /tmp/xray-config.json

sshd_pid=""
xray_pid=""
caddy_pid=""

stop_services() {
  trap - EXIT HUP INT TERM
  for pid in $xray_pid $caddy_pid $sshd_pid; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap stop_services EXIT
trap 'exit 143' HUP INT TERM

if [ -s /run/xgcpx/ssh-password ]; then
  if ! id xgcpx >/dev/null 2>&1; then
    adduser -D -s /bin/sh xgcpx
  fi
  {
    printf 'xgcpx:'
    cat /run/xgcpx/ssh-password
    printf '\n'
  } > /run/xgcpx/chpasswd
  chpasswd < /run/xgcpx/chpasswd
  rm -f /run/xgcpx/ssh-password /run/xgcpx/chpasswd
  mkdir -p /run/sshd
  if [ ! -s /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
  fi
  /usr/sbin/sshd -t
  /usr/sbin/sshd -D -e &
  sshd_pid=$!
fi

su-exec 10001:10001 xray run -config /tmp/xray-config.json &
xray_pid=$!

caddy_config=/etc/caddy/Caddyfile
if [ "${PROTOCOL_HTTP_ONLY:-false}" = "true" ]; then
  caddy_config=/etc/caddy/Caddyfile.cloudrun
fi
su-exec 10001:10001 caddy run --config "$caddy_config" --adapter caddyfile &
caddy_pid=$!

# Exit (so the orchestrator restarts the container) as soon as any service dies.
while kill -0 "$xray_pid" 2>/dev/null && kill -0 "$caddy_pid" 2>/dev/null; do
  if [ -n "$sshd_pid" ] && ! kill -0 "$sshd_pid" 2>/dev/null; then
    break
  fi
  sleep 2
done

printf '%s\n' "A protocol service exited; shutting down so the container restarts." >&2
exit 1
