# Virtual address

Two domain controllers can share a virtual address that keepalived (VRRP)
moves to the surviving host, e.g. as the one DNS server address handed out
to clients. keepalived is not part of this project; it runs next to the
container on each host.

```sh
SAMBA_HOST_ADDRESS=192.168.1.10
SAMBA_VIRTUAL_ADDRESSES=192.168.1.100
```

BIND then answers on `127.0.0.1`, the host address and the virtual address.
It starts answering on the virtual address as soon as keepalived assigns it
and stops when the address moves away; no restart is needed.

The virtual address belongs in `SAMBA_VIRTUAL_ADDRESSES` only:

- **Not in `SAMBA_INTERFACES`.** Samba registers every address there in DNS
  as an address of this domain controller. Both domain controllers would then
  resolve to the same address, which breaks replication and Kerberos between
  them. For the same reason `SAMBA_INTERFACES` takes no interface names such
  as `eth0`.
- **Not as `SAMBA_HOST_ADDRESS`, `SAMBA_PEER_SERVER` or in
  `SAMBA_DNS_FORWARDERS`**; the host would end up talking to itself.

The container refuses to start if one of these rules is violated.

A check script for keepalived that follows the DNS service:

```sh
/usr/bin/nc -z -w 1 127.0.0.1 53
```

## Central LDAP names

Applications can reach LDAP (389) and LDAPS (636) under one name that follows
the virtual address, e.g. `ldap.example.net`.

**The name resolves to the virtual address.** The name need not lie in the
realm. Create an A record pointing to the virtual address once, where the
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

**Something serves LDAP on the virtual address**, in one of two ways.

### With Let's Encrypt

With [Let's Encrypt](tls.md#lets-encrypt) switched on, haproxy runs in the
container and serves LDAP on the virtual addresses. The Let's Encrypt
certificate belongs to the virtual addresses only; Samba keeps its own
certificate (self-signed, or an [own certificate](tls.md#own-certificate))
for the host names:

```
ldaps://ldap.example.net:636  →  haproxy, Let's Encrypt certificate  →  TLS  →  Samba
ldap://ldap.example.net:389   →  haproxy, passed on unchanged        →         Samba
ldaps://dc1.example.lan:636   →  Samba, its own certificate
```

```sh
SAMBA_VIRTUAL_ADDRESSES=192.168.1.100
SAMBA_LETSENCRYPT=yes
ACME_DOMAINS=ldap.example.net
```

Samba listens on its fixed addresses only and leaves 389 and 636 on the
virtual address to haproxy; `SAMBA_BIND_INTERFACES_ONLY=no` is refused. haproxy
binds the virtual address even while the other host holds it, so a failover
needs no restart. It passes LDAPS on to Samba encrypted, so
`SAMBA_LDAP_REQUIRE_STRONG_AUTH=yes` still accepts simple binds through it.

### Without Let's Encrypt

Samba listens on the virtual address itself with

```sh
SAMBA_BIND_INTERFACES_ONLY=no
```

on every address of the host, including the virtual address while the host
holds it. The DNS registration still follows `SAMBA_INTERFACES`. Samba then
serves one certificate for every name: an [own certificate](tls.md#own-certificate)
that lists the central names and the host names of the domain controllers.

### Check for keepalived

Let keepalived follow both LDAP services of Samba as well:

```sh
/usr/bin/nc -z -w 1 127.0.0.1 389 && /usr/bin/nc -z -w 1 127.0.0.1 636
```

With Let's Encrypt, the container's health check also covers haproxy, and
`diagnose` checks LDAPS on the virtual address while this host holds it.

### Limits

- **No Kerberos for the virtual name.** A service principal such as
  `ldap/ldap.example.lan` can belong to one domain controller only.
  Applications that bind with a DN or user name and a password (simple bind,
  NTLM) work.
- **Not a domain controller address for domain members.** With Let's
  Encrypt only 389 and 636 are served there at all. Without it, only TCP is
  reliable; replies to UDP requests (CLDAP, Kerberos over UDP) leave from the
  fixed address of the host.
- **Referrals and `dnsHostName` name the real domain controllers**, whose
  fixed addresses must be reachable for clients that follow them.
- **Open connections break on a failover**; the application reconnects.
- With Let's Encrypt:
    - **StartTLS on port 389 gets Samba's own certificate**; haproxy cannot
      take part in StartTLS. Applications use LDAPS (636) on the central name.
    - **Samba sees the host address as the client** of every connection
      through the virtual address. haproxy logs one line per connection with
      the real client address (`docker compose logs samba-dc`).
    - **Samba's own LDAP client hangs** on LDAPS through haproxy (TLS 1.3),
      e.g. `samba-tool ... -H ldaps://ldap.example.net`. Point Samba's tools at
      a domain controller's host name instead. OpenLDAP's client library,
      which many applications use, is not affected.
- Without Let's Encrypt:
    - **Samba becomes reachable on every address of the host**, including
      Docker bridges and further networks. Restrict this with a firewall where
      needed.
    - **One certificate for all names.** A certificate that carries the
      central names only does not match the domain controller's own host
      name; clients that address a domain controller directly and check the
      name fail. A SADM server accepts such a certificate once the central
      names are listed in its `directory.serviceUrls`.
