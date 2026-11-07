#!/bin/sh
set -eu
primary="${UPSTREAM_PRIMARY#*://}"
primary="${primary%%/*}"
fallback="${UPSTREAM_FALLBACK#*://}"
fallback="${fallback%%/*}"
export UPSTREAM_PRIMARY_HOST="$primary" UPSTREAM_FALLBACK_HOST="$fallback"
envsubst '${UPSTREAM_PRIMARY_HOST} ${UPSTREAM_FALLBACK_HOST}' \
  < /etc/nginx/templates/default.conf.template \
  > /etc/nginx/conf.d/default.conf
nginx -t