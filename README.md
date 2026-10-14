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
| `SAMBA_HOST_ADDRESS` | Fixed IP address of the host; BIND listens on it, and it is the container's DNS server during normal operation |
| `SAMBA_VIRTUAL_ADDRESS` | Optional: virtual addresses BIND answers on as well (space-separated, without prefix length), see [Virtual address](#virtual-address-vrrp--keepalived) |
| `SAMBA_REALM` | Kerberos realm / DNS domain, e.g. `EXAMPLE.LAN` |
| `WORKGROUP` | NetBIOS domain name, e.g. `EXAMPLE` |
| `SAMBA_PEER_SERVER` | Fixed address of an existing DC, only required for a join |
| `SAMBA_INTERFACE` | Fixed addresses of this DC with prefix length, e.g. `127.0.0.1/8 192.168.1.10/24`; Samba registers them in DNS |
| `SAMBA_BIND_INTERFACES_ONLY` | `yes` (default): Samba listens on the addresses of `SAMBA_INTERFACE` only; `no`: on every address of the host |
| `SAMBA_DNS_FORWARDER` | Optional: forwarders for external names (space-separated) |
| `SAMBA_LOG_LEVEL` | Log level of Samba, `0` to `10`, defaults to `1`. The [SADM agent](#sadm-agent) follows it |
| `SADM_AGENT` | `yes` starts the [SADM agent](#sadm-agent); defaults to `no` |
| `TZ` | Time zone, defaults to `UTC` |

The `.env` file holds site-specific values and is not committed.

## Virtual address (VRRP / keepalived)

Two DCs can share a virtual address that keepalived moves to the surviving
host, e.g. as the single DNS server address handed out to clients. keepalived
itself is not part of this project; it runs next to the container on the same
host.

```sh
SAMBA_HOST_ADDRESS=192.168.1.10
SAMBA_VIRTUAL_ADDRESS=192.168.1.100
SAMBA_INTERFACE=127.0.0.1/8 192.168.1.10/24
```

BIND then answers on `127.0.0.1`, the host address and the virtual address.
It starts listening on the virtual address as soon as keepalived assigns it
and stops when the address moves away; no restart is needed.

The virtual address must appear in `SAMBA_VIRTUAL_ADDRESS` only:

- **Not in `SAMBA_INTERFACE`**, and no interface names such as `eth0` there.
  Samba registers every address of this setting in DNS as address of the DC.
  With the virtual address, both DCs would resolve to the same address, which
  breaks replication and Kerberos between them.
- **Not as `SAMBA_HOST_ADDRESS`, `SAMBA_PEER_SERVER` or
  `SAMBA_DNS_FORWARDER`**; the host would end up talking to itself.

The container refuses to start if one of these rules is violated, and
`init.sh` checks them before it changes anything.

A check script for keepalived that follows the DNS service:

```sh
/usr/bin/nc -z -w 1 127.0.0.1 53
```

### LDAP through the virtual address

By default Samba listens on the addresses of `SAMBA_INTERFACE` only, so LDAP,
Kerberos and SMB are not reachable through the virtual address. With

```sh
SAMBA_BIND_INTERFACES_ONLY=no
```

Samba listens on every address of the host, including the virtual address
while the host holds it. The DNS registration still follows
`SAMBA_INTERFACE`. Give the virtual address a name once; the record is
replicated to all DCs:

```sh
docker compose exec samba-dc samba-tool dns add dc1 example.lan ldap A 192.168.1.100 -UAdministrator
```

and let keepalived follow the LDAP service as well:

```sh
/usr/bin/nc -z -w 1 127.0.0.1 389
```

Limits that no setting removes:

- No Kerberos for the virtual name. A service principal such as
  `ldap/ldap.example.lan` can belong to one DC only. Applications that bind
  with a DN or user name and a password (simple bind, NTLM) work.
- The virtual address is no DC address for domain members. Only TCP is
  reliable; replies to UDP requests (CLDAP, Kerberos over UDP) leave from the
  fixed address of the host.
- Samba becomes reachable on every address of the host, including Docker
  bridges and further networks. Restrict this with a firewall where needed.
- Referrals and the `dnsHostName` attribute name the real DCs, whose fixed
  addresses must be reachable for clients that follow them.
- Open connections break on a failover; the application has to reconnect.

### Custom TLS certificate

Each DC generates a self-signed certificate for its own host name, which does
not match the name of a virtual address. To use your own certificate, place
these files in the `tls` directory next to `compose.yaml` and restart the
container:

| File | Content |
|---|---|
| `tls/cert.pem` | Certificate; list the virtual name and the host name of the DC as subject alternative names |
| `tls/key.pem` | Private key, unencrypted |
| `tls/ca.pem` | Optional: certificate of the issuing CA |

The files are copied into the container at every start, so a renewed
certificate becomes active with `docker compose restart`. Without
`tls/cert.pem` Samba keeps using its generated certificate. The content of
`tls` is not committed.

#### Creating the certificate

The simplest setup is a small CA of your own and one certificate shared by
all DCs. It carries the virtual name and the host names of the DCs, so it
still matches after a failover, and clients only have to trust the CA. The
commands run on any machine with `openssl`; adjust the names.

Create the CA once. `ca-key.pem` is protected by a passphrase and does not
belong on the DCs:

```sh
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
  -keyout ca-key.pem -out ca.pem \
  -subj "/CN=EXAMPLE.LAN LDAP CA"
```

Create the key and the signing request. Samba cannot load a key protected by
a passphrase, hence `-noenc` (`-nodes` with older OpenSSL versions):

```sh
openssl req -newkey rsa:2048 -noenc \
  -keyout key.pem -out dc.csr \
  -subj "/CN=ldap.example.lan"
```

Set the names and sign the request with the CA. The `IP:` entry is only
needed if applications address the virtual address by its IP address:

```sh
cat > dc.ext <<'EOF'
subjectAltName = DNS:ldap.example.lan, DNS:dc1.example.lan, DNS:dc2.example.lan, IP:192.168.1.100
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

openssl x509 -req -in dc.csr -sha256 -days 825 \
  -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -extfile dc.ext -out cert.pem
```

Check the result:

```sh
openssl verify -CAfile ca.pem cert.pem
openssl x509 -in cert.pem -noout -subject -enddate -ext subjectAltName
```

Copy `cert.pem`, `key.pem` and `ca.pem` into the `tls` directory on every DC
and restart the container:

```sh
chmod 600 tls/key.pem
docker compose restart
```

The log then contains `Using the custom TLS certificate from /tls`. From a
client, the following command must report `Verify return code: 0 (ok)`:

```sh
openssl s_client -connect ldap.example.lan:636 -CAfile ca.pem </dev/null | grep "Verify return code"
```

Every application that connects through LDAPS needs `ca.pem` as a trusted
CA, either in its own configuration or in the certificate store of its
system. To renew the certificate, repeat the steps from the signing request
onwards; the CA and with it the configuration of the clients stay unchanged.

## SADM agent

[Samba AD Manager](https://github.com/stefgo/samba-ad-manager) (SADM) measures
a domain controller over the network. Its agent runs inside this container
and reports what cannot be asked that way: the services of the `samba`
process, the programs of supervisord, free space, the group policy versions
in the sysvol and a read-only database check. It changes nothing on the
domain controller.

The agent is part of the image but off by default. Switch it on per domain
controller in `.env` and recreate the container:

```sh
SADM_AGENT=yes
```

```sh
docker compose up -d
```

It runs as a third program of supervisord, after BIND and Samba. It is not
part of the health check: a domain controller whose agent is down keeps
running.

### Registering the agent

Each agent is registered once, with "Add Agent" on the page of its domain
controller in SADM. There are two ways:

- **The agent connects to the server.** Generate a token in SADM, set
  `SADM_SERVER_URL` and `SADM_REGISTRATION_TOKEN` and recreate the container.
  The token is valid for one registration and one hour; remove it from `.env`
  afterwards. Nothing listens on the domain controller.
- **The server connects to the agent.** Leave `SADM_SERVER_URL` empty. The
  agent then listens on `SADM_CLIENT_PORT` and prints a setup PIN into the
  log (`docker compose logs samba-dc | grep PIN`). Enter the address of the
  domain controller and the PIN in SADM. Because of `network_mode: host` the
  port is open on every address of the host; restrict it with a firewall or
  with `allowedNetworks` in the agent's `config.yaml`.

The agent keeps the identity it was given in `/var/lib/samba/sadm-client`,
that is in the `samba-dc-lib` volume. `init.sh` deletes that volume, so a
domain controller that is provisioned or joined anew has to be registered
again. To register an existing one again, delete `identity.json` in that
directory and restart the container. An optional `config.yaml` in the same
directory holds further settings, see the
[agent documentation](https://github.com/stefgo/samba-ad-manager/blob/main/docs/agent.md).

| Variable | Meaning |
|---|---|
| `SADM_AGENT` | `yes` starts the agent; defaults to `no` |
| `SADM_SERVER_URL` | URL of the SADM server, e.g. `https://sadm.example.net`. Empty: the agent waits for the server to connect |
| `SADM_REGISTRATION_TOKEN` | Token from "Add Agent", only needed for the registration |
| `SADM_ALLOW_SELF_SIGNED` | `true` accepts a server certificate that does not validate |
| `SADM_CLIENT_PORT` | Port the agent listens on without `SADM_SERVER_URL`, defaults to `3021` |

The agent has no log level of its own. It follows `SAMBA_LOG_LEVEL`, shifted
so that the default of Samba is the default of the agent:

| `SAMBA_LOG_LEVEL` | Agent |
|---|---|
| `0` | `warn` |
| `1`, `2` | `info` |
| `3` to `9` | `debug` |
| `10` | `trace` |

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

The image takes the SADM agent from `ghcr.io/stefgo/sadm-client`. The build
argument `SADM_CLIENT_TAG` selects its tag and defaults to `main`. If that
package is private, it has to grant this repository read access (package
settings, "Manage Actions access"), otherwise the build in GitHub Actions
fails.

## Modes of operation

| Command | Purpose | DNS server of the container |
|---|---|---|
| `./init.sh provision` | Fully initialize a new domain | `SAMBA_HOST_ADDRESS` |
| `./init.sh join` | Initialize and join an existing domain | `SAMBA_PEER_SERVER` |
| `docker compose up -d` | Start an existing installation | `SAMBA_HOST_ADDRESS` |

`init.sh` works in this order:

1. It checks Docker, `.env` and the required settings, including the rules
   for a virtual address.
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
docker compose logs -f                          # logs of BIND, Samba and the agent
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
| `tls/` | Optional custom certificate, see [Custom TLS certificate](#custom-tls-certificate) |
| `.github/workflows/build.yml` | Builds and publishes the image |
| `docker/Dockerfile` | Image with Samba, BIND, supervisord and the SADM agent |
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
