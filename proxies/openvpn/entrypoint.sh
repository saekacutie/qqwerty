#!/bin/sh
set -eu
umask 077

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${OPENVPN_SECRET_NAME:?OPENVPN_SECRET_NAME is required}"

# Check the TUN device first, so a missing device fails before any key material is written.
if [ ! -c /dev/net/tun ]; then
  printf '%s\n' "The VM does not expose /dev/net/tun to the OpenVPN container." >&2
  exit 1
fi

metadata_url="http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
secret_url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${OPENVPN_SECRET_NAME}/versions/latest:access"

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
[ -n "$secret_json" ] || { printf '%s\n' "Unable to read the OpenVPN configuration from Secret Manager." >&2; exit 1; }

# /run/openvpn is owned by nobody so OpenVPN can write its status and IP pool files after dropping root.
mkdir -p /run/openvpn
chmod 0700 /run/openvpn
chown nobody:nogroup /run/openvpn

printf '%s' "$secret_json" | python3 -c '
import base64
import json
import os
import pathlib
import sys

payload = json.load(sys.stdin)["payload"]["data"]
bundle = json.loads(base64.b64decode(payload))
directory = pathlib.Path("/run/openvpn")
for key, filename in (
    ("ca", "ca.crt"),
    ("server_cert", "server.crt"),
    ("server_key", "server.key"),
    ("tls_crypt", "tls-crypt.key"),
):
    value = bundle.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"Missing OpenVPN secret field: {key}")
    path = directory / filename
    # Create with 0600 from the start, so the key is never readable by others.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as handle:
        handle.write(value)
'

unset token_json access_token secret_json

exec openvpn --config /etc/openvpn/server.conf
