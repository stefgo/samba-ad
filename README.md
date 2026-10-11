# samba-ad

Samba Active Directory domain controller as a Docker container, using BIND 9
as DNS backend (`BIND9_DLZ`). The image is based on Debian trixie; Samba is
installed from trixie-backports (4.24).

## Requirements

- Linux host with Docker and the Compose plugin
- The container runs with `network_mode: host`. The ports for DNS (53),
  Kerberos (88, 464), LDAP (389, 636, 3268, 3269) and SMB (135, 139, 445)
  must be free on the host.
- The short hostname of the host becomes the NetBIOS name of the domain
  controller.
- The container is granted the `SYS_ADMIN` capability. Samba stores NT ACLs
  in `security.*` xattrs; without this capability provisioning fails while
  setting the sysvol ACLs.

## Configuration

```sh
cp .env.example .env
```

| Variable | Meaning |
|---|---|
| `SAMBA_HOST_NAME` | Short name of the Docker host |
| `SAMBA_HOST_ADDRESS` | IP address of the host; BIND listens on it, and it is the container's DNS server during normal operation |
| `SAMBA_REALM` | Kerberos realm / DNS domain, e.g. `EXAMPLE.LAN` |
| `WORKGROUP` | NetBIOS domain name, e.g. `EXAMPLE` |
| `SAMBA_PEER_SERVER` | Existing DC, only required for a join |
| `SAMBA_INTERFACE` | Interfaces Samba binds to |
| `SAMBA_DNS_FORWARDER` | Optional: forwarders for external names (space-separated) |
| `TZ` | Time zone, defaults to `UTC` |

The `.env` file holds site-specific values and is not committed.

## Image

GitHub Actions builds the image for `linux/amd64` and `linux/arm64` and
publishes it to the GitHub Container Registry: on changes below `docker/`,
every Monday (to pick up Debian and Samba updates) and on demand via
"Run workflow".

| Tag | Content |
|---|---|
| `latest` | Current build |
| `YYYYMMDD` | Build of a specific day, e.g. for a rollback |

`compose.yaml` uses `ghcr.io/stefgo/samba-ad:latest`. The package is private,
so the Docker host has to log in once with a personal access token
(`read:packages` scope):

```sh
docker login ghcr.io -u stefgo
docker compose pull
```

Alternatively, `docker compose build` builds the image locally under the same
name.

## Modes of operation

| Command | Purpose | DNS server of the container |
|---|---|---|
| `./init.sh provision` | Fully initialize a new domain | `SAMBA_HOST_ADDRESS` |
| `./init.sh join` | Initialize and join an existing domain | `SAMBA_PEER_SERVER` |
| `docker compose up -d` | Start an existing installation | `SAMBA_HOST_ADDRESS` |

`init.sh` works in this order:

1. It checks Docker, `.env` and the required settings.
2. It downloads the image. If that fails and no local copy exists, it stops
   here without changing anything.
3. It shows the planned settings and the volumes that will be deleted, and
   asks for confirmation.
4. It asks for the password of the domain administrator. With `provision` the
   password is newly set (entered twice), with `join` it is the password of
   the existing domain. For unattended runs the password can be passed in the
   `ADMIN_PASSWORD` environment variable.
5. It **deletes the volumes** `samba-dc-etc`, `samba-dc-lib` and
   `samba-dc-bind` and runs the initialization.

After initialization, start the domain controller with:

```sh
docker compose up -d
```

## Operation

```sh
docker compose logs -f                          # logs of BIND and Samba
docker compose exec samba-dc samba-tool drs showrepl
docker compose exec samba-dc samba-tool dbcheck
docker compose pull && docker compose up -d      # update the image
```

Updating to a newer Samba version works with existing volumes; going back to
an older version does not.

## Layout

| Path | Content |
|---|---|
| `compose.yaml` | Service definition and volumes |
| `init.sh` | Initialization (`provision` / `join`) |
| `.github/workflows/build.yml` | Builds and publishes the image |
| `docker/Dockerfile` | Image with Samba, BIND and supervisord |
| `docker/entrypoint.sh` | Initialization and config generation at startup |
| `docker/*.j2` | Templates for `named.conf` and `smb.conf` |

`smb.conf` and `named.conf` are regenerated from the templates on every
start. Custom Samba settings belong in `*.conf` files below
`/etc/samba/conf.d` in the `samba-dc-etc` volume.

## Notes

- `named.conf` contains `allow-update { any; }`. The AD zones are managed by
  Samba's DLZ module (`allow dns updates = secure`); restrict the option if
  you add further zones to BIND.
- Samba uses the DLZ module `dlz_bind9_18.so` for BIND 9.20 as well.
