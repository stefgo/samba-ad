#!/bin/bash
#
# Sets up a test domain with the image and checks that the domain controller
# works: DNS, Kerberos and LDAP. Runs in GitHub Actions before an image is
# tagged, and locally:
#
#   tests/smoke-test.sh <image>
#
# Uses a Docker network of its own and removes everything afterwards.

set -euo pipefail

IMAGE=${1:?usage: $0 <image>}
NAME=samba-ad-smoke-$$
SUBNET=172.31.254.0/24
ADDRESS=172.31.254.10
REALM=SMOKE.TEST
PASSWORD=Smoke-Test-1

step() {
  echo
  echo "==> $*"
}

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$NAME-etc" "$NAME-lib" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
[ -z "${KEEP:-}" ] || trap - EXIT

docker network create --subnet "$SUBNET" "$NAME" >/dev/null
common=(--network "$NAME" --ip "$ADDRESS" --hostname dc1 --dns "$ADDRESS"
  --cap-add SYS_ADMIN -e SAMBA_HOST_ADDRESS="$ADDRESS" -e SAMBA_REALM="$REALM"
  -v "$NAME-etc:/etc/samba" -v "$NAME-lib:/var/lib/samba")

step "Versions"
docker run --rm "$IMAGE" version

step "A container that is not set up refuses to start"
if output=$(docker run --rm "${common[@]}" "$IMAGE" 2>&1); then
  echo "$output"
  echo "FAILED: the container started without a domain" >&2
  exit 1
fi
grep "has not been set up yet" <<< "$output"

step "Provision $REALM"
docker run --rm "${common[@]}" -e ADMIN_PASSWORD="$PASSWORD" "$IMAGE" provision

step "Start the domain controller"
docker run -d --name "$NAME" "${common[@]}" "$IMAGE" >/dev/null
for _ in $(seq 60); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$NAME")
  [ "$health" != starting ] && break
  sleep 3
done
if [ "$health" != healthy ]; then
  docker logs "$NAME"
  echo "FAILED: the container is $health" >&2
  exit 1
fi
docker logs "$NAME" 2>&1 | sed -n '/Starting the domain controller/,/Time zone/p'

step "Diagnose"
docker exec "$NAME" diagnose

step "Kerberos and LDAP"
docker exec "$NAME" bash -c "echo '$PASSWORD' | kinit administrator@$REALM >/dev/null && klist -s"
docker exec "$NAME" samba-tool user list -H "ldap://dc1.smoke.test" --use-kerberos=required | grep -x Administrator

step "Backup"
docker exec "$NAME" mkdir -p /backup
docker exec "$NAME" backup

echo
echo "Smoke test passed."
