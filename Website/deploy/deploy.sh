#!/usr/bin/env bash
# Build the site and put it on the server behind the Cloudflare Tunnel.
#
#   Website/deploy/deploy.sh
#
# The tunnel route and the DNS record are created once by route.py; this script
# only rebuilds, syncs and reloads.

set -euo pipefail

HOST="${HOST:-vultr_tokyo}"
REMOTE="${REMOTE:-/srv/apexterminal}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE="$(dirname "$HERE")"

echo "==> building"
python3 "$SITE/build.py"

echo "==> syncing to $HOST:$REMOTE"
ssh "$HOST" "mkdir -p $REMOTE/site"
rsync -az --delete "$SITE/dist/" "$HOST:$REMOTE/site/"
rsync -az "$HERE/nginx.conf" "$HERE/docker-compose.yml" "$HOST:$REMOTE/"

echo "==> starting"
ssh "$HOST" "cd $REMOTE && docker compose up -d && docker compose exec -T site nginx -s reload || true"

echo "==> checking"
ssh "$HOST" "curl -sS -o /dev/null -w 'local nginx: %{http_code}\n' http://127.0.0.1:8090/"
curl -sS -o /dev/null -w 'public: %{http_code}\n' https://apexterminal.lucian-dev.com/ || true
