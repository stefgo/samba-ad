#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat <<EOF
Usage: $0 provision|join

  provision  Fully initialize a new domain
  join       Initialize the installation and join an existing domain
             (SAMBA_PEER_SERVER is used as DNS server)

An already initialized installation is started with "docker compose up -d".
EOF
}

env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1 | tr -d "\"'"
}

ACTION=${1:-}
case "$ACTION" in
  provision|join) ;;
  *) usage; exit 1 ;;
esac

if [ ! -f .env ]; then
  echo "The .env file is missing - create it from .env.example."
  exit 1
fi

if [ "$ACTION" == join ]; then
  PEER=${SAMBA_PEER_SERVER:-$(env_value SAMBA_PEER_SERVER)}
  if [ -z "$PEER" ]; then
    echo "SAMBA_PEER_SERVER must be set in .env for a join."
    exit 1
  fi
  # During the join the container has to resolve the domain via the peer
  export SAMBA_DNS_SERVER=$PEER
fi

echo "WARNING: The volumes samba-dc-etc, samba-dc-lib and samba-dc-bind will be"
echo "deleted. An existing installation will be lost completely."
read -r -p "Continue with '$ACTION'? [y/N] " ANSWER
case "$ANSWER" in
  y|Y|j|J) ;;
  *) echo "Aborted."; exit 1 ;;
esac

docker compose down -v
docker compose run -t -i --rm -e DOMAIN_ACTION="$ACTION" samba-dc init

echo "Initialization finished. Start with: docker compose up -d"
