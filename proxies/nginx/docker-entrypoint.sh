#!/bin/sh
set -eu

die() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

validate_host() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) die "invalid host '$1' in '$2'" ;;
  esac
}

validate_port() {
  case "$1" in
    ""|*[!0-9]*) die "invalid port '$1' in '$2'" ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "port '$1' out of range (1-65535) in '$2'"
}

# Parses an http:// or https:// URL. Sets UP_SCHEME, UP_HOST, UP_PORT.
parse_upstream() {
  url="$1"
  case "$url" in
    https://*) UP_SCHEME=https; rest="${url#https://}"; default_port=443 ;;
    http://*)  UP_SCHEME=http;  rest="${url#http://}";  default_port=80 ;;
    *) die "upstream must start with http:// or https:// (got '$url')" ;;
  esac
  authority="${rest%%/*}"
  case "$authority" in
    *:*) UP_HOST="${authority%:*}"; UP_PORT="${authority##*:}" ;;
    *)   UP_HOST="$authority";      UP_PORT="$default_port" ;;
  esac
  validate_host "$UP_HOST" "$url"
  validate_port "$UP_PORT" "$url"
}

# Primary and fallback share one upstream block and one TLS name, so for https
# they must share a host. Otherwise the fallback fails certificate checks.
parse_upstream "${UPSTREAM_PRIMARY:?UPSTREAM_PRIMARY is required}"
PRIMARY_SCHEME="$UP_SCHEME"; PRIMARY_HOST="$UP_HOST"; PRIMARY_PORT="$UP_PORT"

parse_upstream "${UPSTREAM_FALLBACK:?UPSTREAM_FALLBACK is required}"
FALLBACK_SCHEME="$UP_SCHEME"; FALLBACK_HOST="$UP_HOST"; FALLBACK_PORT="$UP_PORT"

[ "$PRIMARY_SCHEME" = "$FALLBACK_SCHEME" ] || \
  die "primary and fallback upstreams must use the same scheme"

if [ "$PRIMARY_SCHEME" = https ] && [ "$PRIMARY_HOST" != "$FALLBACK_HOST" ]; then
  die "with https, the fallback host must match the primary host (TLS is validated against the primary's name)"
fi

parse_upstream "${PROTOCOL_UPSTREAM:?PROTOCOL_UPSTREAM is required}"
PROTOCOL_SCHEME="$UP_SCHEME"; PROTOCOL_HOST="$UP_HOST"; PROTOCOL_PORT="$UP_PORT"

# gRPC over TLS uses grpcs://, plain gRPC uses grpc://.
if [ "$PRIMARY_SCHEME" = https ]; then PRIMARY_GRPC_SCHEME=grpcs; else PRIMARY_GRPC_SCHEME=grpc; fi
if [ "$PROTOCOL_SCHEME" = https ]; then PROTOCOL_GRPC_SCHEME=grpcs; else PROTOCOL_GRPC_SCHEME=grpc; fi

export PRIMARY_SCHEME PRIMARY_HOST PRIMARY_PORT PRIMARY_GRPC_SCHEME
export FALLBACK_HOST FALLBACK_PORT
export PROTOCOL_SCHEME PROTOCOL_HOST PROTOCOL_PORT PROTOCOL_GRPC_SCHEME

TEMPLATE=/etc/nginx/templates/default.conf.template
OUTPUT=/etc/nginx/conf.d/default.conf

envsubst '${PRIMARY_SCHEME} ${PRIMARY_HOST} ${PRIMARY_PORT} ${PRIMARY_GRPC_SCHEME} ${FALLBACK_HOST} ${FALLBACK_PORT} ${PROTOCOL_SCHEME} ${PROTOCOL_HOST} ${PROTOCOL_PORT} ${PROTOCOL_GRPC_SCHEME}' \
  < "$TEMPLATE" > "$OUTPUT"

# Fail here with a clear message if the generated config is invalid.
nginx -t || die "generated nginx config is invalid (see $OUTPUT)"
