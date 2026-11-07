#!/bin/sh
set -eu
primary="${UPSTREAM_PRIMARY#https://}"
primary="${primary%%/*}"
fallback="${UPSTREAM_FALLBACK#https://}"
fallback="${fallback%%/*}"
primary_host="${primary%%:*}"
fallback_host="${fallback%%:*}"
primary_port=443
fallback_port=443
case "$primary" in *:*) primary_port="${primary##*:}" ;; esac
case "$fallback" in *:*) fallback_port="${fallback##*:}" ;; esac
export PRIMARY_HOST="$primary_host" PRIMARY_PORT="$primary_port"
export FALLBACK_HOST="$fallback_host" FALLBACK_PORT="$fallback_port"
TCP_HOST="${TCP_UPSTREAM_HOST%:*}"
TCP_PORT="${TCP_UPSTREAM_HOST##*:}"
TLS_HOST="${TLS_UPSTREAM_HOST%:*}"
TLS_PORT="${TLS_UPSTREAM_HOST##*:}"
export TCP_HOST TCP_PORT TLS_HOST TLS_PORT
envsubst '${PRIMARY_HOST} ${PRIMARY_PORT} ${FALLBACK_HOST} ${FALLBACK_PORT} ${TCP_HOST} ${TCP_PORT} ${TLS_HOST} ${TLS_PORT}' \
  < /etc/envoy/envoy.yaml.template > /tmp/envoy.yaml
if [ "${ENVOY_VALIDATE:-false}" = "true" ]; then
  exec envoy --mode validate -c /tmp/envoy.yaml
fi
exec envoy -c /tmp/envoy.yaml --log-format '[%Y-%m-%dT%T.%e%z][%l][%n] %v'