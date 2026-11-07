#!/bin/sh
set -eu

grpc_upstream() {
  case "$1" in
    http://*) printf 'h2c://%s\n' "${1#http://}" ;;
    https://*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "Upstream must use http:// or https://." >&2; return 1 ;;
  esac
}

UPSTREAM_GRPC_PRIMARY="$(grpc_upstream "$UPSTREAM_PRIMARY")"
UPSTREAM_GRPC_FALLBACK="$(grpc_upstream "$UPSTREAM_FALLBACK")"
PROTOCOL_GRPC_UPSTREAM="$(grpc_upstream "$PROTOCOL_UPSTREAM")"
export UPSTREAM_GRPC_PRIMARY UPSTREAM_GRPC_FALLBACK PROTOCOL_GRPC_UPSTREAM
envsubst '${UPSTREAM_PRIMARY} ${UPSTREAM_FALLBACK} ${UPSTREAM_GRPC_PRIMARY} ${UPSTREAM_GRPC_FALLBACK} ${PROTOCOL_UPSTREAM} ${PROTOCOL_GRPC_UPSTREAM}' \
  < /etc/traefik/dynamic.yml.template > /etc/traefik/dynamic.yml
exec traefik --configFile=/etc/traefik/traefik.yml