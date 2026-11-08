
#!/bin/sh
set -eu

: "${UPSTREAM_PRIMARY:?Set UPSTREAM_PRIMARY to a reachable http:// or https:// backend URL}"
: "${UPSTREAM_FALLBACK:?Set UPSTREAM_FALLBACK to a reachable http:// or https:// backend URL}"
: "${PROTOCOL_UPSTREAM:?Set PROTOCOL_UPSTREAM to a reachable http:// or https:// backend URL}"

grpc_upstream() {
  case "$1" in
    http://*)
      printf 'h2c://%s\n' "${1#http://}"
      ;;
    https://*)
      printf '%s\n' "$1"
      ;;
    *)
      printf '%s\n' "Invalid upstream URL: expected http:// or https://." >&2
      return 1
      ;;
  esac
}

TEMPLATE=/etc/traefik/dynamic.yml.template
OUTPUT=/etc/traefik/dynamic.yml
STATIC_CONFIG=/etc/traefik/traefik.yml

[ -r "$TEMPLATE" ] || {
  printf 'Missing or unreadable dynamic config template: %s\n' "$TEMPLATE" >&2
  exit 1
}

[ -r "$STATIC_CONFIG" ] || {
  printf 'Missing or unreadable static config: %s\n' "$STATIC_CONFIG" >&2
  exit 1
}

command -v envsubst >/dev/null 2>&1 || {
  printf '%s\n' "envsubst is required but was not found." >&2
  exit 1
}

command -v traefik >/dev/null 2>&1 || {
  printf '%s\n' "traefik binary was not found." >&2
  exit 1
}

UPSTREAM_GRPC_PRIMARY="$(grpc_upstream "$UPSTREAM_PRIMARY")"
UPSTREAM_GRPC_FALLBACK="$(grpc_upstream "$UPSTREAM_FALLBACK")"
PROTOCOL_GRPC_UPSTREAM="$(grpc_upstream "$PROTOCOL_UPSTREAM")"

export UPSTREAM_PRIMARY
export UPSTREAM_FALLBACK
export UPSTREAM_GRPC_PRIMARY
export UPSTREAM_GRPC_FALLBACK
export PROTOCOL_UPSTREAM
export PROTOCOL_GRPC_UPSTREAM

envsubst '${UPSTREAM_PRIMARY} ${UPSTREAM_FALLBACK} ${UPSTREAM_GRPC_PRIMARY} ${UPSTREAM_GRPC_FALLBACK} ${PROTOCOL_UPSTREAM} ${PROTOCOL_GRPC_UPSTREAM}' \
  < "$TEMPLATE" > "$OUTPUT"

exec traefik --configFile="$STATIC_CONFIG"
