#!/bin/sh
set -eu
parse_upstream() {
  case "$1" in
    https://*) scheme=https; authority="${1#https://}"; default_port=443 ;;
    http://*) scheme=http; authority="${1#http://}"; default_port=80 ;;
    *) printf '%s\n' "Upstream must use http:// or https://." >&2; return 1 ;;
  esac
  authority="${authority%%/*}"
  case "$authority" in
    *:*) host="${authority%:*}"; port="${authority##*:}" ;;
    *) host="$authority"; port="$default_port" ;;
  esac
  case "$host" in ""|*[!A-Za-z0-9.-]*) printf '%s\n' "Invalid upstream host." >&2; return 1 ;; esac
  case "$port" in ""|*[!0-9]*) printf '%s\n' "Invalid upstream port." >&2; return 1 ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { printf '%s\n' "Upstream port must be between 1 and 65535." >&2; return 1; }
  printf '%s\n%s\n%s\n' "$scheme" "$host" "$port"
}

primary_values="$(parse_upstream "$UPSTREAM_PRIMARY")"
fallback_values="$(parse_upstream "$UPSTREAM_FALLBACK")"
PRIMARY_SCHEME="$(printf '%s\n' "$primary_values" | sed -n '1p')"
primary_host="$(printf '%s\n' "$primary_values" | sed -n '2p')"
primary_port="$(printf '%s\n' "$primary_values" | sed -n '3p')"
FALLBACK_SCHEME="$(printf '%s\n' "$fallback_values" | sed -n '1p')"
fallback_host="$(printf '%s\n' "$fallback_values" | sed -n '2p')"
fallback_port="$(printf '%s\n' "$fallback_values" | sed -n '3p')"
[ "$PRIMARY_SCHEME" = "$FALLBACK_SCHEME" ] || {
  printf '%s\n' "Primary and fallback upstreams must use the same HTTP scheme." >&2
  exit 1
}
export PRIMARY_HOST="$primary_host" PRIMARY_PORT="$primary_port"
export FALLBACK_HOST="$fallback_host" FALLBACK_PORT="$fallback_port"
UPSTREAM_TRANSPORT_SOCKET=""
if [ "$PRIMARY_SCHEME" = https ]; then
  UPSTREAM_TRANSPORT_SOCKET="transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          \"@type\": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
          sni: \"${PRIMARY_HOST}\"
          common_tls_context:
            validation_context:
              trusted_ca:
                filename: /etc/ssl/certs/ca-certificates.crt
              match_typed_subject_alt_names:
                - san_type: DNS
                  matcher: { exact: \"${PRIMARY_HOST}\" }"
fi
TCP_HOST="${TCP_UPSTREAM_HOST%:*}"
TCP_PORT="${TCP_UPSTREAM_HOST##*:}"
TLS_HOST="${TLS_UPSTREAM_HOST%:*}"
TLS_PORT="${TLS_UPSTREAM_HOST##*:}"
export TCP_HOST TCP_PORT TLS_HOST TLS_PORT
envsubst '${PRIMARY_HOST} ${PRIMARY_PORT} ${FALLBACK_HOST} ${FALLBACK_PORT} ${UPSTREAM_TRANSPORT_SOCKET} ${TCP_HOST} ${TCP_PORT} ${TLS_HOST} ${TLS_PORT}' \
  < /etc/envoy/envoy.yaml.template > /tmp/envoy.yaml
if [ "${ENVOY_VALIDATE:-false}" = "true" ]; then
  exec envoy --mode validate -c /tmp/envoy.yaml
fi
exec envoy -c /tmp/envoy.yaml --log-format '[%Y-%m-%dT%T.%e%z][%l][%n] %v'