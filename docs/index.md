# samba-ad

A Samba Active Directory domain controller as a Docker container. Windows
and Linux clients join the domain as they would join one run by Windows
Server; users, groups and group policies are managed with the usual tools
(RSAT, `samba-tool`).

- **One container per domain controller**, with BIND 9 as DNS server.
- **Two commands to set up:** `./init.sh provision` creates a new domain,
  `./init.sh join` adds a domain controller to an existing one.
- **Checks before it acts:** wrong settings stop the container with a message
  that says what to change; `diagnose` checks a running domain controller.
- **Current components:** Debian with Samba from its backports. The image is
  rebuilt every week with the current packages.
- **Optional:** a shared virtual address for several domain controllers
  (VRRP) with a certificate from Let's Encrypt for LDAPS on it, and the agent of
  [Samba AD Manager](https://github.com/stefgo/samba-ad-manager).

## How it works

```
container samba-dc, on the network of the host
  supervisord
    ├─ BIND         port 53; the AD zones come from Samba's database (DLZ)
    ├─ Samba        Kerberos 88, LDAP 389/636, SMB 445, Global Catalog 3268, …
    ├─ haproxy      optional, LDAP and Global Catalog on the virtual addresses
    ├─ SADM agent   optional
    └─ certbot      optional, Let's Encrypt for haproxy
  volume samba-dc-etc  →  /etc/samba
  volume samba-dc-lib  →  /var/lib/samba   (directory database, sysvol)
```

At every start the container checks the settings from `.env`, writes
`smb.conf` and `named.conf` anew and starts BIND and Samba. Everything that
makes up the domain lives in the two volumes; the container itself can be
replaced at any time, which is how an update works.

## Next

- [Installation](installation.md): requirements and the first domain controller
- [Configuration](configuration.md): every setting of `.env`
- [Operation](operation.md): logs, updates, backups
- [Troubleshooting](troubleshooting.md): what an error message means and what to do
