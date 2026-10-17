# Configuration

All settings live in `.env` next to `compose.yaml`; `.env.example` is the
template and explains each one. An empty value means the default. After a
change, recreate the container:

```sh
docker compose up -d
```

The container checks the settings at every start and refuses to start with
a message that names the wrong value. `docker compose run --rm samba-dc
check` runs the same checks and shows the effective settings without
starting anything. A variable starting with `SAMBA_` or `ACME_` that is no
setting, e.g. a misspelled or removed one, causes a warning in the log
(`SADM_*` variables are passed to the [SADM agent](sadm-agent.md) and not
checked).

## Required

| Setting | Meaning |
|---|---|
| `SAMBA_HOST_ADDRESS` | Fixed IPv4 address of this host. Samba registers it in DNS as the address of this domain controller; BIND answers on it. |
| `SAMBA_REALM` | DNS name of the domain, which is also its Kerberos realm, e.g. `EXAMPLE.LAN`. Use a name you own or a private one; not `.local`. |
| `SAMBA_PEER_SERVER` | Only for `./init.sh join`: fixed address of an existing domain controller. Also used by `diagnose` to compare the clocks. |

The name of the domain controller is the host name of the host.

## Optional

| Setting | Default | Meaning |
|---|---|---|
| `SAMBA_WORKGROUP` | first part of `SAMBA_REALM` | NetBIOS name of the domain, at most 15 characters |
| `SAMBA_DNS_FORWARDERS` | none | DNS servers that resolve names outside the domain. Without, BIND asks the root servers of the internet |
| `SAMBA_DNS_ALLOW_RECURSION` | `localhost localnets` | Who may resolve names outside the domain through this DC. `localnets` are the networks of the host; add networks of clients behind a router, e.g. `localhost localnets 10.20.0.0/16`. The AD zones answer everyone |
| `SAMBA_LDAP_REQUIRE_STRONG_AUTH` | `no` | `no` accepts LDAP simple binds with a password on port 389 without TLS, as many applications do them. `yes` (Samba's own default) accepts them over LDAPS or StartTLS only; prefer it once every application uses TLS |
| `SAMBA_LOG_LEVEL` | `1` | Log level of Samba, `0` to `10`, optionally with classes such as `1 auth:3`. The SADM agent follows it |
| `TZ` | `UTC` | Time zone of the logs, e.g. `Europe/Berlin` |
| `SAMBA_IMAGE_TAG` | `latest` | Tag of the image, e.g. `1.2` to stay on a release line, see [Updates](operation.md#update) |

### Addresses

| Setting | Default | Meaning |
|---|---|---|
| `SAMBA_INTERFACES` | `127.0.0.1/8` and `SAMBA_HOST_ADDRESS` with its prefix | Addresses Samba listens on and registers in DNS, with prefix length. Fixed addresses only, no interface names |
| `SAMBA_VIRTUAL_ADDRESSES` | none | [Virtual addresses](virtual-address.md): BIND answers on them as well, haproxy serves [LDAP and the Global Catalog](virtual-address.md#central-ldap-names) there |

### Let's Encrypt and SADM agent

`SAMBA_LETSENCRYPT` and the `ACME_*` settings are described in
[TLS certificates](tls.md#lets-encrypt), `SADM_*` in
[SADM agent](sadm-agent.md).

## Files next to compose.yaml

| File | Content |
|---|---|
| `.env` | The settings above; not committed |
| `acme.env` | Cloudflare API token for [Let's Encrypt](tls.md#lets-encrypt); not committed |
| `tls/` | [Own certificate](tls.md#own-certificate) |
| `letsencrypt/` | Account and certificates of Let's Encrypt, written by the container |
| `sadm-config.yaml` | Further settings of the [SADM agent](sadm-agent.md) |
| `backup/` | Archives of the [backup](operation.md#backup) |

## Own Samba settings

`smb.conf` and `named.conf` are written anew at every start; they set only
what this image needs and leave everything else at Samba's defaults, so that
an update of Samba brings its new defaults along.

Further Samba settings go into files `*.conf` below `/etc/samba/conf.d` in
the volume `samba-dc-etc`. They are included at the end of `[global]` and
win over the generated settings:

```sh
docker compose exec samba-dc sh -c 'cat > /etc/samba/conf.d/local.conf' <<'EOF'
	kdc enable fast = yes
EOF
docker compose restart samba-dc
```

The container checks the result with `testparm` and refuses to start if
Samba rejects it.
