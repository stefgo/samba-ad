#!/bin/bash
#
# Creates the sysvol folder of every group policy the directory knows and the sysvol of
# this domain controller lacks: {GUID}/GPT.INI with the version the directory names, and
# the empty MACHINE and USER folders -- what "samba-tool domain provision" creates. A
# folder that exists is left alone. Sets no ACLs.
#
#   ./restore-gpo-folders.sh            show what is missing, change nothing
#   ./restore-gpo-folders.sh --apply    create the missing folders
#
# The container is samba-dc unless SAMBA_CONTAINER names another.

set -euo pipefail

CONTAINER=${SAMBA_CONTAINER:-samba-dc}

case "${1:-}" in
  "") APPLY= ;;
  --apply) APPLY=--apply ;;
  *)
    echo "Usage: $0 [--apply]" >&2
    exit 2
    ;;
esac

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]; then
  echo "ERROR: Container '$CONTAINER' is not running." >&2
  exit 1
fi

docker exec -i "$CONTAINER" python3 - $APPLY <<'EOF'
import os
import sys

from samba.auth import system_session
from samba.param import LoadParm
from samba.samdb import SamDB

apply = "--apply" in sys.argv[1:]

lp = LoadParm()
lp.load_default()
db = SamDB(session_info=system_session(), lp=lp)

policies = os.path.join(lp.get("path", "sysvol"), db.domain_dns_name().lower(), "Policies")
print("sysvol policies:", policies)

missing = 0
for msg in db.search("CN=Policies,CN=System," + str(db.domain_dn()),
                     expression="(objectClass=groupPolicyContainer)",
                     attrs=["cn", "displayName", "versionNumber"]):
    guid = str(msg["cn"][0])
    name = str(msg.get("displayName", idx=0) or guid)
    version = int(str(msg.get("versionNumber", idx=0) or 0))
    folder = os.path.join(policies, guid)

    if os.path.isdir(folder):
        print(f"present   {guid}  {name}")
        continue
    missing += 1
    if not apply:
        print(f"missing   {guid}  {name}  -> would create with Version={version}")
        continue

    for sub in ("MACHINE", "USER"):
        os.makedirs(os.path.join(folder, sub), 0o775, exist_ok=True)
    with open(os.path.join(folder, "GPT.INI"), "w", newline="") as f:
        f.write(f"[General]\r\nVersion={version}\r\n")
    print(f"created   {guid}  {name}  Version={version}")

if missing and not apply:
    print("Nothing changed. Run again with --apply to create the missing folders.")
elif not missing:
    print("Nothing to do.")
EOF
