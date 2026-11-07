#!/bin/sh
set -eu
envsubst '${UPSTREAM_PRIMARY} ${UPSTREAM_FALLBACK}' \
  < /etc/traefik/dynamic.yml.template > /etc/traefik/dynamic.yml
exec traefik --configFile=/etc/traefik/traefik.yml