#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat <<EOF
Aufruf: $0 provision|join

  provision  Neue Domäne vollständig initialisieren
  join       Installation initialisieren und einer bestehenden Domäne
             beitreten (SAMBA_PEER_SERVER dient als DNS-Server)

Eine bereits initialisierte Installation wird mit "docker compose up -d"
gestartet.
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
  echo "Die Datei .env fehlt - bitte aus .env.example erstellen."
  exit 1
fi

if [ "$ACTION" == join ]; then
  PEER=${SAMBA_PEER_SERVER:-$(env_value SAMBA_PEER_SERVER)}
  if [ -z "$PEER" ]; then
    echo "Für den Join muss SAMBA_PEER_SERVER in der .env gesetzt sein."
    exit 1
  fi
  # Während des Joins muss der Container die Domäne über den Peer auflösen
  export SAMBA_DNS_SERVER=$PEER
fi

echo "ACHTUNG: Die Volumes samba-dc-etc, samba-dc-lib und samba-dc-bind werden"
echo "gelöscht. Eine vorhandene Installation geht dabei vollständig verloren."
read -r -p "Fortfahren mit '$ACTION'? [j/N] " ANSWER
case "$ANSWER" in
  j|J|y|Y) ;;
  *) echo "Abgebrochen."; exit 1 ;;
esac

docker compose down -v
docker compose run -t -i --rm -e DOMAIN_ACTION="$ACTION" samba-dc init

echo "Initialisierung abgeschlossen. Start mit: docker compose up -d"
