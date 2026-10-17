#!/bin/bash
#
# Sets up this domain controller: a new domain (provision) or a further
# domain controller of an existing one (join). Deletes an existing
# installation of this host first, after asking.
#
#   ./init.sh provision|join
#
# The settings come from .env. For unattended runs, the password of the
# domain administrator can be passed in ADMIN_PASSWORD.
# Documentation: https://stefgo.github.io/samba-ad/installation/

set -euo pipefail

cd "$(dirname "$0")"

SERVICE=samba-dc
VOLUMES=(samba-dc-etc samba-dc-lib)

usage() {
  cat <<EOF
Usage: $0 provision|join

  provision  Create a new domain with this host as its first domain controller
  join       Add this host as domain controller to an existing domain
             (SAMBA_PEER_SERVER in .env)

A domain controller that is set up already is started with "docker compose up -d".
EOF
}

step() {
  echo
  echo "==> $*"
}

die() {
  echo >&2
  echo "ERROR: $1" >&2
  shift
  if [ $# -gt 0 ]; then
    printf '       %s\n' "$@" >&2
  fi
  exit 1
}

# yes_no <question> <default y|n>
yes_no() {
  local answer prompt="[y/N]"
  if [ "$2" == y ]; then prompt="[Y/n]"; fi
  read -r -p "$1 $prompt " answer
  answer=${answer:-$2}
  [[ $answer == [yYjJ]* ]]
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

step "Checking Docker and .env"

command -v docker >/dev/null ||
  die "The docker command was not found." "Install Docker first."
docker compose version >/dev/null 2>&1 ||
  die "The Docker Compose plugin is not available."
docker info >/dev/null 2>&1 ||
  die "The Docker daemon is not reachable." "Is Docker running, and may this user access it?"
[ -f .env ] ||
  die "The .env file is missing." "Create it with: cp .env.example .env"
docker compose config -q ||
  die "compose.yaml could not be evaluated - see the message above."
IMAGE=$(docker compose config --images | head -n 1)
echo "Docker, Compose and .env are fine."

# The image is fetched before anything is deleted, so that a failed download
# leaves an existing installation untouched.
step "Fetching image $IMAGE"

if docker pull "$IMAGE"; then
  echo "Image is up to date."
elif docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo
  echo "NOTE: The image could not be downloaded (see the message above)."
  echo "      The local copy is used instead:"
  docker image inspect -f '      created {{.Created}}' "$IMAGE"
else
  die "The image $IMAGE could not be downloaded and no local copy exists." \
    "Nothing has been changed." \
    "Check the network connection, or build the image locally:" \
    "  docker compose -f compose.yaml -f compose.build.yaml build"
fi

step "Checking the settings"

# Before the check, which creates missing volumes
EXISTING=()
for VOLUME in "${VOLUMES[@]}"; do
  if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    EXISTING+=("$VOLUME")
  fi
done
RUNNING=$(docker ps -q -f "name=^${SERVICE}\$")
CHECK=(check "$ACTION")
# The ports are still held by the running domain controller, which is
# stopped below
if [ -z "$RUNNING" ]; then
  CHECK+=(--ports)
fi
docker compose run --rm --no-deps -T "$SERVICE" "${CHECK[@]}" ||
  die "The settings are not usable - see the message above." "Nothing has been changed."

echo
if [ "$ACTION" == provision ]; then
  echo "This creates a NEW domain with the settings above."
else
  echo "This adds this host as domain controller to the EXISTING domain above."
fi
if [ ${#EXISTING[@]} -gt 0 ]; then
  echo "WARNING: This host is a domain controller already. Its volumes will be"
  echo "         DELETED: ${EXISTING[*]}"
  if [ -n "$RUNNING" ]; then
    echo "         The running container $SERVICE will be stopped."
  fi
fi
yes_no "Continue with '$ACTION'?" n || { echo "Aborted. Nothing has been changed."; exit 1; }

SAVE=no
if [ ${#EXISTING[@]} -gt 0 ] && yes_no "Save the existing volumes to backup/ first?" y; then
  SAVE=yes
fi

step "Password of the domain administrator"

if [ -n "${ADMIN_PASSWORD:-}" ]; then
  echo "Using the password from the ADMIN_PASSWORD environment variable."
elif [ "$ACTION" == provision ]; then
  echo "Choose the password of the account 'Administrator' of the new domain."
  echo "At least 7 characters from three of: upper case, lower case, digits,"
  echo "special characters. The input is not displayed."
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
  echo "Enter the password of the account 'Administrator' of the existing"
  echo "domain. The input is not displayed."
  while [ -z "${ADMIN_PASSWORD:-}" ]; do
    read -r -s -p "Password: " ADMIN_PASSWORD
    echo
  done
fi
export ADMIN_PASSWORD

if [ "$SAVE" == yes ]; then
  step "Saving the existing volumes"
  # Stopped, so that the databases are consistent
  docker compose stop
  mkdir -p backup
  ARCHIVE=backup/volumes-$(date +%Y%m%d-%H%M%S).tar.gz
  MOUNTS=()
  for VOLUME in "${EXISTING[@]}"; do
    MOUNTS+=(-v "$VOLUME:/volumes/$VOLUME:ro")
  done
  # Reading security.* xattrs (NT ACLs) needs SYS_ADMIN
  docker run --rm --cap-add SYS_ADMIN "${MOUNTS[@]}" -v "$PWD/backup:/backup" \
    --entrypoint tar "$IMAGE" --xattrs --xattrs-include='*' --warning=no-file-ignored -czf "/$ARCHIVE" -C /volumes . ||
    die "The volumes could not be saved. Nothing has been deleted." \
      "Start the domain controller again with: docker compose up -d"
  echo "Saved to $ARCHIVE"
fi

step "Removing the old installation"
docker compose down -v

step "Running 'samba-tool domain $ACTION' - this can take a few minutes"
# ADMIN_PASSWORD is passed by name only, so it does not show up in the
# process list
if ! docker compose run --rm --no-deps -e ADMIN_PASSWORD "$SERVICE" "$ACTION"; then
  HINTS=("The output above shows the cause. Fix it and run '$0 $ACTION' again;"
    "the volumes are incomplete until then.")
  if [ "$ACTION" == join ]; then
    HINTS+=("Common causes: wrong password, or the time of the hosts differs.")
  fi
  HINTS+=("See https://stefgo.github.io/samba-ad/troubleshooting/")
  die "The setup failed." "${HINTS[@]}"
fi
unset ADMIN_PASSWORD

step "Domain controller set up"

if ! yes_no "Start it now?" y; then
  echo "Start it with: docker compose up -d"
  exit 0
fi
docker compose up -d
echo "Waiting for the services to answer ..."
for _ in $(seq 60); do
  HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$SERVICE" 2>/dev/null || echo missing)
  [ "$HEALTH" != starting ] && break
  sleep 3
done
if [ "$HEALTH" != healthy ]; then
  docker compose logs --tail 30 "$SERVICE"
  die "The domain controller did not come up (state: $HEALTH)." \
    "See the log above and https://stefgo.github.io/samba-ad/troubleshooting/"
fi

step "Diagnosis"
docker compose exec -T "$SERVICE" diagnose || true

echo
if [ "$ACTION" == join ]; then
  cat <<EOF
Next steps for a joined domain controller:
- The sysvol is not replicated. Copy it from an existing DC, or create
  missing group policy folders: docker compose exec $SERVICE restore-gpo-folders
- See https://stefgo.github.io/samba-ad/installation/#after-a-join
EOF
else
  echo "Next: https://stefgo.github.io/samba-ad/installation/#after-the-setup"
fi
