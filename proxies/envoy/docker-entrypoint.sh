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

# Parses a host:port value (TCP and TLS upstreams). Sets UP_HOST, UP_PORT.
parse_hostport() {
  case "$1" in
    *:*) ;;
    *) die "'$1' must be in host:port form" ;;
  esac
  UP_HOST="${1%:*}"
  UP_PORT="${1##*:}"
  validate_host "$UP_HOST" "$1"
  validate_port "$UP_PORT" "$1"
}

# Emits an UpstreamTlsContext transport socket for a host.
# A second argument of "h2" adds ALPN h2 (needed for gRPC over TLS).
tls_socket() {
  printf '%s\n' "transport_socket:"
  printf '%s\n' "        name: envoy.transport_sockets.tls"
  printf '%s\n' "        typed_config:"
  printf '%s\n' "          \"@type\": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext"
  printf '%s\n' "          sni: \"$1\""
  printf '%s\n' "          common_tls_context:"
  if [ "${2:-}" = h2 ]; then
    printf '%s\n' "            alpn_protocols: [\"h2\"]"
  fi
  printf '%s\n' "            validation_context:"
  printf '%s\n' "              trusted_ca:"
  printf '%s\n' "                filename: /etc/ssl/certs/ca-certificates.crt"
  printf '%s\n' "              match_typed_subject_alt_names:"
  printf '%s\n' "                - san_type: DNS"
  printf '%s\n' "                  matcher: { exact: \"$1\" }"
}

# Primary and fallback share one cluster, so they share one TLS transport socket.
parse_upstream "${UPSTREAM_PRIMARY:?UPSTREAM_PRIMARY is required}"
PRIMARY_SCHEME="$UP_SCHEME"; PRIMARY_HOST="$UP_HOST"; PRIMARY_PORT="$UP_PORT"

parse_upstream "${UPSTREAM_FALLBACK:?UPSTREAM_FALLBACK is required}"
FALLBACK_SCHEME="$UP_SCHEME"; FALLBACK_HOST="$UP_HOST"; FALLBACK_PORT="$UP_PORT"

[ "$PRIMARY_SCHEME" = "$FALLBACK_SCHEME" ] || \
  die "primary and fallback upstreams must use the same scheme"

if [ "$PRIMARY_SCHEME" = https ] && [ "$PRIMARY_HOST" != "$FALLBACK_HOST" ]; then
  die "with https, the fallback host must match the primary host (TLS is validated against the primary's name)"
fi

UPSTREAM_TRANSPORT_SOCKET=""
if [ "$PRIMARY_SCHEME" = https ]; then
  UPSTREAM_TRANSPORT_SOCKET="$(tls_socket "$PRIMARY_HOST")"
fi

parse_upstream "${PROTOCOL_UPSTREAM:?PROTOCOL_UPSTREAM is required}"
PROTOCOL_SCHEME="$UP_SCHEME"; PROTOCOL_HOST="$UP_HOST"; PROTOCOL_PORT="$UP_PORT"

PROTOCOL_H1_TRANSPORT_SOCKET=""
PROTOCOL_H2_TRANSPORT_SOCKET=""
if [ "$PROTOCOL_SCHEME" = https ]; then
  PROTOCOL_H1_TRANSPORT_SOCKET="$(tls_socket "$PROTOCOL_HOST")"
  PROTOCOL_H2_TRANSPORT_SOCKET="$(tls_socket "$PROTOCOL_HOST" h2)"
fi

parse_hostport "${TCP_UPSTREAM_HOST:?TCP_UPSTREAM_HOST is required}"
TCP_HOST="$UP_HOST"; TCP_PORT="$UP_PORT"

parse_hostport "${TLS_UPSTREAM_HOST:?TLS_UPSTREAM_HOST is required}"
TLS_HOST="$UP_HOST"; TLS_PORT="$UP_PORT"

export PRIMARY_HOST PRIMARY_PORT FALLBACK_HOST FALLBACK_PORT
export PROTOCOL_HOST PROTOCOL_PORT
export TCP_HOST TCP_PORT TLS_HOST TLS_PORT
export UPSTREAM_TRANSPORT_SOCKET PROTOCOL_H1_TRANSPORT_SOCKET PROTOCOL_H2_TRANSPORT_SOCKET

envsubst '${PRIMARY_HOST} ${PRIMARY_PORT} ${FALLBACK_HOST} ${FALLBACK_PORT} ${PROTOCOL_HOST} ${PROTOCOL_PORT} ${TCP_HOST} ${TCP_PORT} ${TLS_HOST} ${TLS_PORT} ${UPSTREAM_TRANSPORT_SOCKET} ${PROTOCOL_H1_TRANSPORT_SOCKET} ${PROTOCOL_H2_TRANSPORT_SOCKET}' \
  < /etc/envoy/envoy.yaml.template > /tmp/envoy.yaml

# Always validate before starting, so a bad config fails here with a clear message.
envoy --mode validate -c /tmp/envoy.yaml || die "generated Envoy config is invalid (see /tmp/envoy.yaml)"

if [ "${ENVOY_VALIDATE:-false}" = "true" ]; then
  printf '%s\n' "Configuration is valid."
  exit 0
fi

exec envoy -c /tmp/envoy.yaml --log-format '[%Y-%m-%dT%T.%e%z][%l][%n] %v'
