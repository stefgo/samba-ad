<!--
The hand-written part of the next release: what is new, why it matters, and
what an upgrade needs. It is placed above the list of commits in the GitHub
release and in CHANGELOG.md.

Write below this comment. Use "###" for headings -- "##" is the level of the
version itself. A release with nothing written here is refused. A beta from
dev keeps the text; the stable release from main empties this file again.

Nothing inside an HTML comment is published.
-->

### The first release

A Samba Active Directory domain controller as a Docker container, on Debian trixie with
Samba from trixie-backports and BIND 9 as its DNS backend (`BIND9_DLZ`). `init.sh provision`
creates a new domain, `init.sh join` adds a domain controller to an existing one.
Documentation: https://stefgo.github.io/samba-ad/

- **Checks with hints:** the container checks its settings at every start and refuses to
  start with a message that says what to change. `diagnose` checks a running domain
  controller (programs, ports, DNS records, replication, clock, certificate, sysvol).
- **Commands in the image:** `diagnose`, `backup` (`samba-tool domain backup offline`),
  `restore-gpo-folders`, `check` and `version`.
- **Samba's defaults:** `smb.conf` sets only what the image needs, so that Samba updates
  bring their defaults along (e.g. the `ft_scanner` service of Samba 4.24).
- **Virtual addresses:** BIND answers on the addresses of a VRRP pair as well.
- **Certificates:** Let's Encrypt (DNS-01 over Cloudflare), renewed and loaded without a
  restart, or an own certificate.
- **SADM agent:** optional, with `SADM_AGENT=yes`.
- **Tested images:** every image sets up a test domain before it is tagged. `latest` is the
  last release, `X.Y.Z` and `X.Y` name one; the last release is rebuilt every Monday.

### Upgrading from an image before this release

The volumes stay; `.env` has to be adapted, `docker compose up -d` then starts as before.

- Renamed in `.env`: `SAMBA_INTERFACE` → `SAMBA_INTERFACES`, `SAMBA_VIRTUAL_ADDRESS` →
  `SAMBA_VIRTUAL_ADDRESSES`, `SAMBA_DNS_FORWARDER` → `SAMBA_DNS_FORWARDERS`, `WORKGROUP` →
  `SAMBA_WORKGROUP`. `SAMBA_HOST_NAME` is gone: the host name of the host is used.
- Take `compose.yaml` and `init.sh` from this release; `restore-gpo-folders.sh` is now a
  command of the image (`docker compose exec samba-dc restore-gpo-folders`).
- New, with the old behaviour as default: `SAMBA_LDAP_REQUIRE_STRONG_AUTH=no`.
- Changed behaviour: BIND answers recursive queries only for `SAMBA_DNS_ALLOW_RECURSION`
  (default: the host and its networks); add client networks behind a router. BIND runs as
  user `bind`, and `allow-update { any; }` is gone (Samba's secure updates are unaffected).
- `smb.conf` no longer sets `domain master`, `winbind use default domain`,
  `winbind refresh tickets`, `client ldap sasl wrapping` and the fixed `server services`
  list, and adds the missing `idmap_ldb:use rfc2307 = yes`. Samba runs in its default
  process model (prefork).
- The `YYYYMMDD` image tags are no longer produced; pin an `X.Y.Z` tag instead.
- No longer used: the volume `samba-dc-bind` (`docker volume rm samba-dc-bind`) and the
  files `netlogon.conf` and `sysvol.conf` below `/etc/samba/conf.d` (delete them).
