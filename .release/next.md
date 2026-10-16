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
creates a new domain, `init.sh join` adds a domain controller to an existing one; after
that `docker compose up -d` starts it.

- **Virtual addresses:** BIND answers on the addresses of a VRRP pair as well, so that
  clients can use one DNS server address for several domain controllers.
- **Certificates:** a certificate from Let's Encrypt (DNS-01 over Cloudflare), renewed in
  the container and loaded by Samba without a restart, or a certificate of your own.
  Central LDAP/LDAPS names can be carried by it.
- **SADM agent:** optional, with `SADM_AGENT=yes`; it reports the domain controller to a
  [SADM](https://github.com/stefgo/samba-ad-manager) server.

### Versioned images

The image is now published per release: `latest` is the last release, `X.Y.Z` and `X.Y`
name one, and `main` is the state of the main branch. Every Monday the last release is
rebuilt with the current Debian and Samba packages. The `YYYYMMDD` tags are no longer
produced; a rollback goes to an `X.Y.Z` tag instead.
