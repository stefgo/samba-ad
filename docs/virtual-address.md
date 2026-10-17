# Virtual address

Two domain controllers can share virtual addresses that keepalived (VRRP)
moves to the surviving host, e.g. as the one DNS server address handed out
to clients. keepalived is not part of this project; it runs next to the
container on each host.

Two independent settings say what the container serves on which virtual
address:

| Setting | Served there |
|---|---|
| `SAMBA_DNS_VIRTUAL_ADDRESSES` | DNS: BIND answers on them as well |
| `SAMBA_LDAP_VIRTUAL_ADDRESSES` | LDAP and the Global Catalog through haproxy, see [Central LDAP names](#central-ldap-names) |

One address for both:

```sh
SAMBA_HOST_ADDRESS=192.168.1.10
SAMBA_DNS_VIRTUAL_ADDRESSES=192.168.1.100
SAMBA_LDAP_VIRTUAL_ADDRESSES=192.168.1.100
```

Or one address each, e.g. so that DNS and LDAP can be active on different
hosts:

```sh
SAMBA_HOST_ADDRESS=192.168.1.10
SAMBA_DNS_VIRTUAL_ADDRESSES=192.168.1.100
SAMBA_LDAP_VIRTUAL_ADDRESSES=192.168.1.101
```

Each address that moves on its own needs its own VRRP instance in keepalived,
with the [check](#checks-for-keepalived) of its service. Either setting may
stay empty.

BIND answers on `127.0.0.1`, the host address and
`SAMBA_DNS_VIRTUAL_ADDRESSES`. It starts answering on a virtual address as
soon as keepalived assigns it and stops when the address moves away; no
restart is needed.

A virtual address belongs in these two settings only:

- **Not in `SAMBA_INTERFACES`.** Samba registers every address there in DNS
  as an address of this domain controller. Both domain controllers would then
  resolve to the same address, which breaks replication and Kerberos between
  them. For the same reason `SAMBA_INTERFACES` takes no interface names such
  as `eth0`.
- **Not as `SAMBA_HOST_ADDRESS` or `SAMBA_PEER_SERVER`, and a DNS address
  not in `SAMBA_DNS_FORWARDERS`**; the host would end up talking to itself.

The container refuses to start if one of these rules is violated.

## Checks for keepalived

A check script for the VRRP instance of `SAMBA_DNS_VIRTUAL_ADDRESSES` that
follows the DNS service:

```sh
/usr/bin/nc -z -w 1 127.0.0.1 53
```

One for the instance of `SAMBA_LDAP_VIRTUAL_ADDRESSES` that follows the LDAP
services of Samba:

```sh
/usr/bin/nc -z -w 1 127.0.0.1 389 && /usr/bin/nc -z -w 1 127.0.0.1 636
```

With one address in both settings, one instance runs both checks. The
container's health check also covers haproxy, and `diagnose` checks DNS and
haproxy's ports on every virtual address while this host holds it.

## Central LDAP names

Applications can reach LDAP (389), LDAPS (636) and the
[Global Catalog](#global-catalog) (3268, 3269) under one name that follows the
virtual address, e.g. `ldap.example.net`.

**The name resolves to the virtual address.** The name need not lie in the
realm. Create an A record pointing to the virtual LDAP address once, where the
domain of the name is served:

- In a public zone, e.g. at Cloudflare; a private address is allowed there.
  At Cloudflare the record has to be **DNS only**: the proxy forwards HTTP,
  not LDAP.
- In an internal zone of the same name (split DNS).
- For a name inside the realm, in the AD zone; it is replicated to all
  domain controllers:

    ```sh
    docker compose exec samba-dc samba-tool dns add dc1 example.lan ldap A 192.168.1.100 -UAdministrator
    ```

**haproxy serves the virtual address.** With `SAMBA_LDAP_VIRTUAL_ADDRESSES`
set, haproxy runs in the container and serves these ports on every address
there; Samba itself listens on its fixed addresses (`SAMBA_INTERFACES`)
only:

| Port on the virtual address | Without Let's Encrypt | With [Let's Encrypt](tls.md#lets-encrypt) |
|---|---|---|
| 389 LDAP | passed on to Samba | passed on to Samba |
| 636 LDAPS | passed on, Samba's certificate | Let's Encrypt certificate, then TLS to Samba |
| 3268 Global Catalog | passed on to Samba | passed on to Samba |
| 3269 Global Catalog over TLS | passed on, Samba's certificate | Let's Encrypt certificate, then TLS to Samba |

haproxy binds the virtual address even while the other host holds it, so a
failover needs no restart.

**The certificate carries the name.** Samba's certificate serves the host
name of the domain controller (`ldaps://dc1.example.lan`). For the central
name there are two ways:

- **Let's Encrypt** (names in a public domain): the certificate belongs to
  the virtual addresses only, Samba keeps its own for the host names.
  haproxy passes LDAPS on to Samba encrypted, so
  `SAMBA_LDAP_REQUIRE_STRONG_AUTH=yes` still accepts simple binds through it.

    ```sh
    SAMBA_LDAP_VIRTUAL_ADDRESSES=192.168.1.100
    SAMBA_LETSENCRYPT=yes
    ACME_DOMAINS=ldap.example.net
    ```

- **An [own certificate](tls.md#own-certificate)** (e.g. names inside a
  private realm) for Samba that lists the central names as well as the host
  names; haproxy passes it through unchanged.

### Global Catalog

The Global Catalog (3268, 3269 with TLS) answers searches across every
domain of the forest, e.g. for applications that look up users of several
domains. It is read-only and holds a subset of the attributes of each
object. In a forest with one domain, LDAP on 389/636 finds the same objects
with all attributes; use the Global Catalog where an application asks for it.
On 3269, the certificate is the same as on 636.

### Limits

- **No Kerberos for the virtual name.** A service principal such as
  `ldap/ldap.example.lan` can belong to one domain controller only.
  Applications that bind with a DN or user name and a password (simple bind,
  NTLM) work.
- **Not a domain controller address for domain members.** Only LDAP and the
  Global Catalog are served there; Kerberos, SMB and CLDAP are not.
- **Referrals and `dnsHostName` name the real domain controllers**, whose
  fixed addresses must be reachable for clients that follow them.
- **Open connections break on a failover**; the application reconnects.
- **Samba sees the host address as the client** of every connection through
  the virtual address. haproxy logs one line per connection with the real
  client address (`docker compose logs samba-dc`).
- **StartTLS on port 389 gets Samba's own certificate**; haproxy cannot take
  part in StartTLS. With Let's Encrypt, applications use LDAPS (636) on the
  central name.
- With Let's Encrypt, **Samba's own LDAP client hangs** on LDAPS through
  haproxy (TLS 1.3), e.g. `samba-tool ... -H ldaps://ldap.example.net`. Point
  Samba's tools at a domain controller's host name instead. OpenLDAP's client
  library, which many applications use, is not affected.
- Without Let's Encrypt, **one certificate serves all names.** A certificate
  that carries the central names only does not match the domain
  controller's own host name; clients that address a domain controller
  directly and check the name fail. A SADM server accepts such a certificate
  once the central names are listed in its `directory.serviceUrls`.
