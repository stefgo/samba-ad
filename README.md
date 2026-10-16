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
| `SAMBA_LETSENCRYPT` | `yes` obtains a certificate from Let's Encrypt, see [Let's Encrypt certificate](#lets-encrypt-certificate); defaults to `no`. The `ACME_*` settings are described there |
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

### Central LDAP/LDAPS names

Applications can reach LDAP (389, also with StartTLS) and LDAPS (636) under
one name that follows the virtual address, e.g. `ldap://ldap.example.net`
and `ldaps://ldap.example.net`, or under one name each. Three things make
this work.

**Samba listens on the virtual address.** By default Samba listens on the
addresses of `SAMBA_INTERFACE` only, so LDAP, Kerberos and SMB are not
reachable through the virtual address. With

```sh
SAMBA_BIND_INTERFACES_ONLY=no
```

Samba listens on every address of the host, including the virtual address
while the host holds it. The DNS registration still follows
`SAMBA_INTERFACE`.

**The names resolve to the virtual address.** The names do not have to lie
in the realm: `ldap.example.net` for the realm `example.lan` is fine. Create
an A record for each name pointing to the virtual address, once, where the
domain of the name is served:

- In a public zone, e.g. at Cloudflare. A private address is allowed there.
  At Cloudflare the record has to be **DNS only**: the Cloudflare proxy
  forwards HTTP, not LDAP.
- In an internal zone of the same name (split DNS).
- For a name inside the realm, in the AD zone; the record is replicated to
  all DCs:

  ```sh
  docker compose exec samba-dc samba-tool dns add dc1 example.lan ldap A 192.168.1.100 -UAdministrator
  ```

  Let's Encrypt cannot issue a certificate for a private realm such as
  `example.lan`; use a [custom certificate](#custom-tls-certificate) then.

**The certificate carries the names.** Each DC generates a self-signed
certificate for its own host name, which matches none of them. Either let
the DC obtain one from [Let's Encrypt](#lets-encrypt-certificate), or use a
[custom certificate](#custom-tls-certificate).

Let keepalived follow both LDAP services as well:

```sh
/usr/bin/nc -z -w 1 127.0.0.1 389 && /usr/bin/nc -z -w 1 127.0.0.1 636
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
- Samba has one certificate and presents it under every name. A certificate
  that carries the central names only does not match the DC's own host name;
  clients that address a DC directly and check the name fail. Domain members
  use LDAP with signing and are not affected. A SADM server accepts such a
  certificate for a DC once the central names are listed in its
  `directory.serviceUrls`.

### Let's Encrypt certificate

A DC can obtain a certificate for the central names from Let's Encrypt
itself and renew it before it expires. The challenge is answered through the
DNS (DNS-01) with Cloudflare's API, so the names need not be reachable from
the internet; only their domain has to be at Cloudflare. It is independent of
the realm.

Requirements:

- The names lie in a domain whose DNS is served by Cloudflare.
- A Cloudflare API token with the permissions **Zone / DNS / Edit** and
  **Zone / Zone / Read**, restricted to the zones of these names
  (*My Profile → API Tokens → Create Token*, template "Edit zone DNS").
- No certificate in `tls/`: the two exclude each other.

Put the token into `acme.env` next to `compose.yaml`; it is not committed:

```sh
cp acme.env.example acme.env
chmod 600 acme.env
```

```sh
CLOUDFLARE_DNS_API_TOKEN=...
```

and switch Let's Encrypt on in `.env`:

```sh
SAMBA_LETSENCRYPT=yes
ACME_DOMAINS=ldap.example.net
ACME_EMAIL=hostmaster@example.net
```

| Variable | Meaning |
|---|---|
| `SAMBA_LETSENCRYPT` | `yes` obtains and renews the certificate; defaults to `no` |
| `ACME_DOMAINS` | Names in the certificate, space-separated; the first becomes the common name. One name for LDAP and LDAPS or one each, e.g. `ldap.example.net ldaps.example.net` |
| `ACME_EMAIL` | Contact address of the Let's Encrypt account |
| `ACME_SERVER` | Optional ACME directory; empty means Let's Encrypt. `https://acme-staging-v02.api.letsencrypt.org/directory` for a test |
| `ACME_KEY_TYPE` | `rsa2048` (default) or `ec256`. RSA works with older LDAP clients as well |
| `ACME_PROPAGATION_SECONDS` | Seconds to wait for the TXT record before Let's Encrypt checks it; defaults to `30` |

Recreate the container:

```sh
docker compose up -d
```

What happens then:

- Samba never waits for the certificate. Until the first one is issued it
  uses a temporary self-signed certificate for the same names, and switches
  as soon as the real one is there.
- certbot runs as a further program of supervisord and checks the
  certificate at the start and then every 12 to 13 hours. It renews it once a
  third of its lifetime is left (30 of 90 days today); the threshold follows
  shorter lifetimes by itself. A changed `ACME_DOMAINS` takes effect at the
  next start.
- Samba's LDAP server loads a new certificate without a restart, for LDAPS
  and StartTLS; open connections stay up.
- If obtaining it fails, e.g. with a wrong token, the current certificate
  stays in use, the log says why and the attempt is repeated after 5
  minutes, then with growing distance up to 12 hours.
- Account and certificates are kept in `letsencrypt/` next to
  `compose.yaml`. `init.sh` does not delete it, so a DC provisioned anew
  reuses the certificate instead of running into Let's Encrypt's rate
  limits.

The token reaches certbot only: Samba, BIND and the SADM agent are started
without it. It is still visible in the container's configuration
(`docker inspect`); to avoid that, mount it as a file (e.g. a Docker secret)
and name the file in `CLOUDFLARE_DNS_API_TOKEN_FILE` instead.

Test with the staging server first (`ACME_SERVER` above): its certificates
are not trusted, but its rate limits are generous. Remove `letsencrypt/`
before switching to the real one. Check the result from a client:

```sh
openssl s_client -connect ldap.example.net:636 </dev/null | grep -E "subject=|issuer=|Verify return code"
openssl s_client -connect ldap.example.net:389 -starttls ldap </dev/null | grep "Verify return code"
docker compose logs samba-dc | grep letsencrypt
```

Applications need no CA of their own for a Let's Encrypt certificate; the
certificate stores of current systems trust it.

### Custom TLS certificate

Instead of Let's Encrypt, e.g. for names inside a private realm, a
certificate of your own can be used. Place these files in the `tls`
directory next to `compose.yaml` and restart the container:

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
  agent then listens on `listenPort` from `sadm-config.yaml` (3021) and
  prints a setup PIN into the log (`docker compose logs samba-dc | grep PIN`).
  Enter the address of the domain controller and the PIN in SADM. Because of
  `network_mode: host` the port is open on every address of the host;
  restrict it with a firewall or with `allowedNetworks` in
  `sadm-config.yaml`.

The agent keeps the identity it was given in `/var/lib/samba/sadm-client`,
that is in the `samba-dc-lib` volume. `init.sh` deletes that volume, so a
domain controller that is provisioned or joined anew has to be registered
again. To register an existing one again, delete `identity.json` in that
directory and restart the container.

### Agent settings

The basic settings come from `.env`:

| Variable | Meaning |
|---|---|
| `SADM_AGENT` | `yes` starts the agent; defaults to `no` |
| `SADM_SERVER_URL` | URL of the SADM server, e.g. `https://sadm.example.net`. Empty: the agent waits for the server to connect |
| `SADM_REGISTRATION_TOKEN` | Token from "Add Agent", only needed for the registration |
| `SADM_ALLOW_SELF_SIGNED` | `true` accepts a server certificate that does not validate |

Everything else lives in `sadm-config.yaml` next to `compose.yaml`, which is
mounted as the agent's `config.yaml`. Every key in it is commented out and
shows its default, so an unchanged file changes nothing. Remove the `#` of a
key, change its value and restart the container:

```sh
docker compose restart samba-dc
```

The variables win over the file: `SADM_SERVER_URL` over `serverUrl` and
`SADM_ALLOW_SELF_SIGNED` over `allowSelfSignedCertificates`, as long as they
are not empty. When the server connects to the agent, the agent writes the
server's URL into the file itself, which is why it is mounted writable.
Paths in the file, e.g. for `tls`, have to be absolute. See the
[agent documentation](https://github.com/stefgo/samba-ad-manager/blob/main/docs/agent.md)
for all settings.

Without `logLevel` in `sadm-config.yaml` the agent follows `SAMBA_LOG_LEVEL`,
shifted so that the default of Samba is the default of the agent:

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

### Missing group policy folders

Samba does not replicate the sysvol. A group policy that exists in the
directory can therefore lack its folder below
`sysvol/<realm>/Policies` on a domain controller, e.g. after a join.
`restore-gpo-folders.sh` creates such folders: `{GUID}/GPT.INI` with the
version the directory names and empty `MACHINE` and `USER` folders. Folders
that exist are left alone.

```sh
./restore-gpo-folders.sh            # show what is missing, change nothing
./restore-gpo-folders.sh --apply    # create the missing folders
```

The script runs inside the running container `samba-dc`; `SAMBA_CONTAINER`
names another one. It sets no ACLs; reset them afterwards with:

```sh
docker compose exec samba-dc samba-tool ntacl sysvolreset
```

The folders it creates hold no policy settings. If a policy contains
settings, copy its folder from a domain controller that has it instead.

## Layout

| Path | Content |
|---|---|
| `compose.yaml` | Service definition and volumes |
| `init.sh` | Initialization (`provision` / `join`) |
| `tls/` | Optional custom certificate, see [Custom TLS certificate](#custom-tls-certificate) |
| `acme.env` | Cloudflare API token for Let's Encrypt, not committed (template: `acme.env.example`), see [Let's Encrypt certificate](#lets-encrypt-certificate) |
| `letsencrypt/` | Account and certificates of Let's Encrypt, created by the container, not committed |
| `sadm-config.yaml` | Settings of the SADM agent, see [Agent settings](#agent-settings) |
| `restore-gpo-folders.sh` | Creates missing group policy folders in the sysvol, see [Missing group policy folders](#missing-group-policy-folders) |
| `.github/workflows/build.yml` | Builds and publishes the image |
| `docker/Dockerfile` | Image with Samba, BIND, supervisord and the SADM agent |
| `docker/entrypoint.sh` | Initialization and config generation at startup |
| `docker/letsencrypt.sh` | Obtains, renews and installs the Let's Encrypt certificate |
| `docker/*.j2` | Templates for `named.conf` and `smb.conf` |

`smb.conf` and `named.conf` are regenerated from the templates on every
start. Custom Samba settings belong in `*.conf` files below
`/etc/samba/conf.d` in the `samba-dc-etc` volume.

## Notes

- `named.conf` contains `allow-update { any; }`. The AD zones are managed by
  Samba's DLZ module (`allow dns updates = secure`); restrict the option if
  you add further zones to BIND.
- Samba uses the DLZ module `dlz_bind9_18.so` for BIND 9.20 as well.
