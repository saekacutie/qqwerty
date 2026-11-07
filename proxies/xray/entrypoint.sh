#!/bin/sh
set -eu
umask 077

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${PROTOCOL_SECRET_NAME:?PROTOCOL_SECRET_NAME is required}"
: "${RELAY_DOMAIN:?RELAY_DOMAIN is required}"

metadata_url="http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
secret_url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PROTOCOL_SECRET_NAME}/versions/latest:access"

token_json="$(curl --fail --silent --show-error --retry 5 --retry-connrefused \
  --connect-timeout 3 --max-time 15 \
  --header 'Metadata-Flavor: Google' "$metadata_url")"
access_token="$(printf '%s' "$token_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
secret_json=""
attempt=0
while [ "$attempt" -lt 12 ]; do
  if secret_json="$(curl --fail --silent --show-error \
    --connect-timeout 3 --max-time 15 \
    --header "Authorization: Bearer ${access_token}" "$secret_url")"; then
    break
  fi
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
    os.makedirs("/run/xgcpx", exist_ok=True)
    fd = os.open("/run/xgcpx/ssh-password", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as password_file:
        password_file.write(password)
'
unset token_json access_token secret_json
chown 10001:10001 /tmp/xray-config.json
chmod 0600 /tmp/xray-config.json

xray run -test -config /tmp/xray-config.json
sshd_pid=""
if [ -s /run/xgcpx/ssh-password ]; then
  if ! id xgcpx >/dev/null 2>&1; then
    adduser -D -s /bin/sh xgcpx
  fi
  printf 'xgcpx:' > /run/xgcpx/chpasswd
  cat /run/xgcpx/ssh-password >> /run/xgcpx/chpasswd
  printf '\n' >> /run/xgcpx/chpasswd
  chpasswd < /run/xgcpx/chpasswd
  rm -f /run/xgcpx/ssh-password /run/xgcpx/chpasswd
  mkdir -p /run/sshd
  ssh-keygen -A
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
stop_services() {
  kill "$xray_pid" "$caddy_pid" 2>/dev/null || true
  if [ -n "$sshd_pid" ]; then
    kill "$sshd_pid" 2>/dev/null || true
  fi
}
trap stop_services EXIT HUP INT TERM

while kill -0 "$xray_pid" 2>/dev/null && kill -0 "$caddy_pid" 2>/dev/null; do
  if [ -n "$sshd_pid" ] && ! kill -0 "$sshd_pid" 2>/dev/null; then
    break
  fi
  sleep 2
done

exit 1
