#!/bin/sh
set -eu

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

check_upstream() {
  [ -n "$2" ] || fail "$1 is empty."
  case "$2" in
    http://* | https://*) ;;
    *) fail "$1 must use http:// or https://." ;;
  esac
  case "$2" in
    *[[:space:]]* | *\"* | *\\*) fail "$1 contains unsupported whitespace or quoting." ;;
  esac
}

# Plain-HTTP upstreams are spoken to as HTTP/2 cleartext (needed for gRPC and streaming xHTTP). HTTPS upstreams
# negotiate h2 via ALPN. WebSocket/HTTPUpgrade routes keep the original URL: Traefik cannot upgrade over h2c.
h2_upstream() {
  case "$1" in
    http://*) printf 'h2c://%s\n' "${1#http://}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# One <server> entry, or two when primary and fallback really differ (a duplicate would only skew load balancing).
servers_block() {
  printf -- '- url: "%s"' "$1"
  if [ "$2" != "$1" ]; then
    printf '\n          - url: "%s"' "$2"
  fi
}

: "${UPSTREAM_PRIMARY:?UPSTREAM_PRIMARY is required}"
: "${UPSTREAM_FALLBACK:=$UPSTREAM_PRIMARY}"
: "${PROTOCOL_UPSTREAM:?PROTOCOL_UPSTREAM is required}"
check_upstream UPSTREAM_PRIMARY "$UPSTREAM_PRIMARY"
check_upstream UPSTREAM_FALLBACK "$UPSTREAM_FALLBACK"
check_upstream PROTOCOL_UPSTREAM "$PROTOCOL_UPSTREAM"

API_SERVERS="$(servers_block "$UPSTREAM_PRIMARY" "$UPSTREAM_FALLBACK")"
GRPC_SERVERS="$(servers_block "$(h2_upstream "$UPSTREAM_PRIMARY")" "$(h2_upstream "$UPSTREAM_FALLBACK")")"
PROTOCOL_H2_UPSTREAM="$(h2_upstream "$PROTOCOL_UPSTREAM")"
export API_SERVERS GRPC_SERVERS PROTOCOL_UPSTREAM PROTOCOL_H2_UPSTREAM

config_dir="${TRAEFIK_CONFIG_DIR:-/etc/traefik}"
envsubst '${API_SERVERS} ${GRPC_SERVERS} ${PROTOCOL_UPSTREAM} ${PROTOCOL_H2_UPSTREAM}' \
  < "${config_dir}/dynamic.yml.template" > "${config_dir}/dynamic.yml.tmp"
[ -s "${config_dir}/dynamic.yml.tmp" ] || fail "Generated Traefik dynamic configuration is empty."
mv "${config_dir}/dynamic.yml.tmp" "${config_dir}/dynamic.yml"

exec traefik --configFile="${config_dir}/traefik.yml"
