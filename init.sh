#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

SERVICE=samba-dc
VOLUMES=(samba-dc-etc samba-dc-lib samba-dc-bind)

usage() {
  cat <<EOF
Usage: $0 provision|join

  provision  Fully initialize a new domain
  join       Initialize the installation and join an existing domain
             (SAMBA_PEER_SERVER is used as DNS server)

An already initialized installation is started with "docker compose up -d".
EOF
}

step() {
  echo
  echo "==> $*"
}

die() {
  echo
  echo "ERROR: $1" >&2
  shift
  if [ $# -gt 0 ]; then
    printf '       %s\n' "$@" >&2
  fi
  exit 1
}

env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1 | tr -d "\"'"
}

# Value of a setting the way compose resolves it: environment, .env, default
setting() {
  local value=${!1:-}
  if [ -z "$value" ]; then
    value=$(env_value "$1")
  fi
  echo "${value:-${2:-}}"
}

# Samba's default policy: at least 7 characters from 3 character classes
password_ok() {
  local classes=0
  [ ${#1} -ge 7 ] || return 1
  if [[ $1 =~ [[:upper:]] ]]; then classes=$((classes + 1)); fi
  if [[ $1 =~ [[:lower:]] ]]; then classes=$((classes + 1)); fi
  if [[ $1 =~ [[:digit:]] ]]; then classes=$((classes + 1)); fi
  if [[ $1 =~ [^[:alnum:]] ]]; then classes=$((classes + 1)); fi
  [ $classes -ge 3 ]
}

ACTION=${1:-}
case "$ACTION" in
  provision|join) ;;
  *) usage; exit 1 ;;
esac

step "Checking prerequisites"

command -v docker >/dev/null ||
  die "The docker command was not found." "Install Docker first."
docker compose version >/dev/null 2>&1 ||
  die "The Docker Compose plugin is not available."
docker info >/dev/null 2>&1 ||
  die "The Docker daemon is not reachable." \
    "Is Docker running, and may this user access it?"

[ -f .env ] ||
  die "The .env file is missing." "Create it with: cp .env.example .env"

MISSING=()
for NAME in SAMBA_HOST_NAME SAMBA_HOST_ADDRESS SAMBA_REALM SAMBA_INTERFACE; do
  if [ -z "$(setting $NAME)" ]; then
    MISSING+=("$NAME")
  fi
done
if [ "$ACTION" == join ] && [ -z "$(setting SAMBA_PEER_SERVER)" ]; then
  MISSING+=("SAMBA_PEER_SERVER (required for a join)")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  die "These settings are missing in .env:" "${MISSING[@]}"
fi

docker compose config -q ||
  die "compose.yaml could not be evaluated - see the message above."

HOST_NAME=$(setting SAMBA_HOST_NAME)
HOST_ADDRESS=$(setting SAMBA_HOST_ADDRESS)
REALM=$(setting SAMBA_REALM)
DOMAIN=$(setting WORKGROUP HOME)
PEER=$(setting SAMBA_PEER_SERVER)
INTERFACES=$(setting SAMBA_INTERFACE)
VIRTUAL_ADDRESSES=$(setting SAMBA_VIRTUAL_ADDRESS)
BIND_INTERFACES_ONLY=$(setting SAMBA_BIND_INTERFACES_ONLY yes)
IMAGE=$(docker compose config --images | head -n 1)

# Samba registers every address of SAMBA_INTERFACE in DNS as address of this
# DC. An interface name would include a virtual address while this host
# holds it, so only fixed addresses are accepted.
for ENTRY in $INTERFACES; do
  [[ $ENTRY =~ ^[0-9A-Fa-f.:]+/[0-9]+$ ]] ||
    die "SAMBA_INTERFACE entry '$ENTRY' is not of the form address/prefix." \
      "List the fixed addresses of the host, e.g. 127.0.0.1/8 $HOST_ADDRESS/24"
done

case "$BIND_INTERFACES_ONLY" in
  yes|no) ;;
  *) die "SAMBA_BIND_INTERFACES_ONLY must be yes or no." ;;
esac

for VIP in $VIRTUAL_ADDRESSES; do
  [[ $VIP =~ ^[0-9]+(\.[0-9]+){3}$ ]] ||
    die "SAMBA_VIRTUAL_ADDRESS entry '$VIP' is not an IPv4 address." \
      "List the addresses without prefix length."
  [ "$VIP" != "$HOST_ADDRESS" ] ||
    die "SAMBA_HOST_ADDRESS must be the fixed address of the host," \
      "not the virtual address $VIP."
  [ "$VIP" != "$PEER" ] ||
    die "SAMBA_PEER_SERVER must be the fixed address of the peer," \
      "not the virtual address $VIP."
  for ENTRY in $(setting SAMBA_DNS_FORWARDER); do
    [ "$VIP" != "$ENTRY" ] ||
      die "The virtual address $VIP must not be used as DNS forwarder."
  done
  for ENTRY in $INTERFACES; do
    [ "$VIP" != "${ENTRY%%/*}" ] ||
      die "The virtual address $VIP must not be listed in SAMBA_INTERFACE." \
        "Samba would register it in DNS as address of this DC."
  done
done

if { [ -f tls/cert.pem ] && [ ! -f tls/key.pem ]; } ||
    { [ ! -f tls/cert.pem ] && [ -f tls/key.pem ]; }; then
  die "A custom certificate needs both tls/cert.pem and tls/key.pem."
fi

echo "Docker, Compose and .env are fine."

# The image is fetched before anything is deleted, so that a failed download
# leaves an existing installation untouched.
step "Fetching image $IMAGE"

if docker pull "$IMAGE"; then
  echo "Image is up to date."
elif docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo
  echo "NOTE: The image could not be downloaded (see the message above)."
  echo "      A local copy exists and is used instead:"
  docker image inspect -f '      created {{.Created}}, id {{.Id}}' "$IMAGE"
else
  die "The image $IMAGE could not be downloaded and no local copy exists." \
    "Nothing has been changed; existing volumes are untouched." \
    "" \
    "Possible causes and remedies (see the docker message above):" \
    "- Not logged in - the package is private. Log in with a personal" \
    "  access token (read:packages):  docker login ${IMAGE%%/*}" \
    "- No network connection or the registry is unreachable." \
    "- Build the image locally instead:  docker compose build"
fi

step "Planned initialization"

if [ "$ACTION" == provision ]; then
  echo "Action:          provision - create a NEW domain"
else
  echo "Action:          join - add this host as DC to an EXISTING domain"
fi
echo "Realm:           $REALM"
echo "NetBIOS domain:  $DOMAIN"
echo "DC host name:    $HOST_NAME"
echo "DC address:      $HOST_ADDRESS"
echo "Virtual address: ${VIRTUAL_ADDRESSES:-none}"
if [ "$BIND_INTERFACES_ONLY" == yes ]; then
  echo "Samba listens:   on $INTERFACES"
else
  echo "Samba listens:   on every address of the host"
fi
if [ -f tls/cert.pem ]; then
  echo "TLS certificate: tls/cert.pem"
else
  echo "TLS certificate: self-signed, generated by Samba"
fi
if [ "$ACTION" == join ]; then
  echo "Join partner:    $PEER (also DNS server during the join)"
fi

EXISTING=()
for VOLUME in "${VOLUMES[@]}"; do
  if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    EXISTING+=("$VOLUME")
  fi
done

echo
if [ ${#EXISTING[@]} -gt 0 ]; then
  echo "WARNING: An installation already exists. These volumes will be DELETED:"
  printf '           %s\n' "${EXISTING[@]}"
  if [ -n "$(docker ps -q -f "name=^${SERVICE}\$")" ]; then
    echo "         The running container $SERVICE will be stopped."
  fi
  echo "         The existing installation will be lost completely."
else
  echo "No existing volumes found - nothing will be deleted."
fi
read -r -p "Continue with '$ACTION'? [y/N] " ANSWER
case "$ANSWER" in
  y|Y|j|J) ;;
  *) echo "Aborted. Nothing has been changed."; exit 1 ;;
esac

step "Password of the domain administrator"

if [ -n "${ADMIN_PASSWORD:-}" ]; then
  echo "Using the password from the ADMIN_PASSWORD environment variable."
elif [ "$ACTION" == provision ]; then
  echo "Choose the password for the account 'Administrator' of the new domain"
  echo "$REALM. It needs at least 7 characters from three of these classes:"
  echo "upper case, lower case, digits, special characters."
  echo "The input is not displayed."
  while true; do
    read -r -s -p "New password: " ADMIN_PASSWORD
    echo
    if ! password_ok "$ADMIN_PASSWORD"; then
      echo "The password does not meet the requirements - try again."
      continue
    fi
    read -r -s -p "Repeat password: " REPEATED
    echo
    if [ "$ADMIN_PASSWORD" == "$REPEATED" ]; then
      break
    fi
    echo "The passwords do not match - try again."
  done
  unset REPEATED
else
  echo "Enter the password of the existing account 'Administrator' of the"
  echo "domain $REALM. It is used to authenticate the join at $PEER."
  echo "The input is not displayed."
  while [ -z "${ADMIN_PASSWORD:-}" ]; do
    read -r -s -p "Password: " ADMIN_PASSWORD
    echo
  done
fi
export ADMIN_PASSWORD

if [ "$ACTION" == join ]; then
  # During the join the container has to resolve the domain via the peer
  export SAMBA_DNS_SERVER=$PEER
fi

step "Removing the old installation"
docker compose down -v

step "Running 'samba-tool domain $ACTION' - this can take a few minutes"
# ADMIN_PASSWORD is passed by name only, so it does not show up in the
# process list
if ! docker compose run --rm -e DOMAIN_ACTION="$ACTION" -e ADMIN_PASSWORD \
    "$SERVICE" init; then
  HINTS=("The output of samba-tool above shows the cause."
    "The volumes are now incomplete; fix the cause and run"
    "'$0 $ACTION' again.")
  if [ "$ACTION" == join ]; then
    HINTS+=("" "Common causes: wrong password, $PEER not reachable or not"
      "a DC of $REALM, time difference to the peer of more than 5 minutes.")
  fi
  die "The initialization failed." "${HINTS[@]}"
fi

step "Initialization finished"
echo "Start the domain controller:  docker compose up -d"
echo "Follow the logs:              docker compose logs -f"
