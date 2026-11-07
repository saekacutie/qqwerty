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
printf '%s' "$secret_json" | python3 -c \
  'import base64,json,sys; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)["payload"]["data"]))' \
  > /tmp/xray-config.json
unset token_json access_token secret_json

xray run -test -config /tmp/xray-config.json
xray run -config /tmp/xray-config.json &
xray_pid=$!
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!
trap 'kill "$xray_pid" "$caddy_pid" 2>/dev/null || true' EXIT HUP INT TERM

while kill -0 "$xray_pid" 2>/dev/null && kill -0 "$caddy_pid" 2>/dev/null; do
  sleep 2
done

exit 1
