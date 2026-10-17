# Operation

## Commands

| Command | Purpose |
|---|---|
| `docker compose logs -f` | Log of BIND, Samba and the optional programs |
| `docker compose exec samba-dc diagnose` | [Check the domain controller](#check-the-domain-controller) |
| `docker compose exec samba-dc backup` | [Back up the domain](#backup) |
| `docker compose exec samba-dc restore-gpo-folders` | [Missing group policy folders](#missing-group-policy-folders) |
| `docker compose run --rm samba-dc check` | Check `.env` and show the effective settings |
| `docker compose run --rm samba-dc version` | Versions of Samba, BIND and the image |
| `docker compose exec samba-dc samba-tool …` | Samba's own administration tool |

## Check the domain controller

```sh
docker compose exec samba-dc diagnose
```

It checks, without changing anything: the programs, the ports, the DNS
records of the domain, name resolution outside the domain, replication, the
clock against `SAMBA_PEER_SERVER`, the group policy folders, the certificate
and the free space. Each failed check names the next step. `--dbcheck` adds
a check of the directory database, which takes longer.

At every start the log shows the versions and the effective settings:

```sh
docker compose logs samba-dc | grep -A 16 "Starting the domain controller"
```

Docker's health check tests every 30 seconds that BIND and Samba run and that
DNS, Kerberos, LDAP and SMB answer;
`docker compose ps` shows the result, `docker inspect samba-dc` the output.

## Update

The image is rebuilt every week with the current Debian and Samba packages
and published as `latest`. To update a domain controller:

```sh
docker compose pull
docker compose up -d
docker compose exec samba-dc diagnose
```

- **One domain controller at a time.** Update the next one only after
  `diagnose` reports no failed check on the first.
- **Back up first** (`backup`). A newer Samba may upgrade the database; going
  back to an older image is then not possible.
- **Release lines:** `SAMBA_IMAGE_TAG=1.2` in `.env` stays on the 1.2 line,
  which still gets the weekly package updates. `X.Y.Z` pins one release.
  The changes of each release are in the
  [releases](https://github.com/stefgo/samba-ad/releases).
- An unattended update tool (e.g. Watchtower) would update every domain
  controller at the same moment; leave domain controllers out of it.

## Backup

```sh
docker compose exec samba-dc backup
```

`samba-tool domain backup offline` writes the directory database, the
sysvol and the configuration into `backup/samba-backup-<date>.tar.bz2` on
the host, while the domain controller keeps running. `--keep 7` deletes all
but the seven newest archives. For a daily backup at 02:30, as a cron job of
the host:

```sh
30 2 * * * cd /path/to/samba-ad && docker compose exec -T samba-dc backup --keep 7
```

Copy the archives to another machine: they contain the password hashes of
all accounts.

## Restore

Which way fits depends on what is lost:

**One of several domain controllers.** Do not restore it; set it up anew
from the others. On a remaining domain controller, remove the lost one from
the directory (here `DC2`), then join it again on its host:

```sh
docker compose exec samba-dc samba-tool domain demote --remove-other-dead-server=DC2
./init.sh join
```

**The only domain controller, from a volume archive.** `init.sh` offers to
save the volumes before it deletes them (`backup/volumes-<date>.tar.gz`). To
go back to such an archive on the same host:

```sh
docker compose down -v
docker volume create samba-dc-etc
docker volume create samba-dc-lib
docker run --rm --cap-add SYS_ADMIN --entrypoint tar \
  -v samba-dc-etc:/volumes/samba-dc-etc -v samba-dc-lib:/volumes/samba-dc-lib \
  -v "$PWD/backup:/backup:ro" ghcr.io/stefgo/samba-ad \
  --xattrs --xattrs-include='*' -xzf /backup/volumes-<date>.tar.gz -C /volumes
docker compose up -d
```

!!! danger "Never with further domain controllers"
    A domain controller restored to an older state while others kept
    running confuses replication for good (USN rollback). With further
    domain controllers, take the first way.

**Every domain controller, from a `backup` archive.**
`samba-tool domain backup restore` creates a new first domain controller
with a new name from the archive; the others are joined again afterwards.
Follow
[Back up and Restoring a Samba AD DC](https://wiki.samba.org/index.php/Back_up_and_Restoring_a_Samba_AD_DC)
in the Samba wiki.

## Missing group policy folders

Samba does not replicate the sysvol. A group policy that exists in the
directory can therefore lack its folder below `sysvol/<realm>/Policies` on
a domain controller, e.g. after a join; `diagnose` reports it.

```sh
docker compose exec samba-dc restore-gpo-folders            # show what is missing
docker compose exec samba-dc restore-gpo-folders --apply    # create it
```

It creates `{GUID}/GPT.INI` with the version the directory names and empty
`MACHINE` and `USER` folders, then resets the ACLs of the sysvol. Folders that
exist are left alone. The folders it creates hold no policy settings: copy
the folder of a policy with settings from a domain controller that has it
instead.
