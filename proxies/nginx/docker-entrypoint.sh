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
UPSTREAM_PRIMARY_SCHEME="$(printf '%s\n' "$primary_values" | sed -n '1p')"
UPSTREAM_PRIMARY_HOST="$(printf '%s\n' "$primary_values" | sed -n '2p')"
UPSTREAM_PRIMARY_PORT="$(printf '%s\n' "$primary_values" | sed -n '3p')"
UPSTREAM_FALLBACK_SCHEME="$(printf '%s\n' "$fallback_values" | sed -n '1p')"
UPSTREAM_FALLBACK_HOST="$(printf '%s\n' "$fallback_values" | sed -n '2p')"
UPSTREAM_FALLBACK_PORT="$(printf '%s\n' "$fallback_values" | sed -n '3p')"
[ "$UPSTREAM_PRIMARY_SCHEME" = "$UPSTREAM_FALLBACK_SCHEME" ] || {
  printf '%s\n' "Primary and fallback upstreams must use the same HTTP scheme." >&2
  exit 1
}
export UPSTREAM_PRIMARY_HOST UPSTREAM_PRIMARY_PORT UPSTREAM_FALLBACK_HOST UPSTREAM_FALLBACK_PORT
if [ "$UPSTREAM_PRIMARY_SCHEME" = https ]; then
  UPSTREAM_GRPC_SCHEME=grpcs
else
  UPSTREAM_GRPC_SCHEME=grpc
fi
export UPSTREAM_PRIMARY_SCHEME UPSTREAM_GRPC_SCHEME
envsubst '${UPSTREAM_PRIMARY_HOST} ${UPSTREAM_PRIMARY_PORT} ${UPSTREAM_FALLBACK_HOST} ${UPSTREAM_FALLBACK_PORT} ${UPSTREAM_PRIMARY_SCHEME} ${UPSTREAM_GRPC_SCHEME}' \
  < /etc/nginx/templates/default.conf.template \
  > /etc/nginx/conf.d/default.conf
nginx -t