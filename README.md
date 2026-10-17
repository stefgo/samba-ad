# samba-ad

A Samba Active Directory domain controller as a Docker container, with BIND 9
as DNS server. Debian with Samba from its backports; the image is rebuilt
every week with the current packages.

**Documentation: https://stefgo.github.io/samba-ad/**

## Quick start

On a Linux host with Docker, a fixed IPv4 address and the host name the
domain controller should have (e.g. `dc1`):

```sh
git clone https://github.com/stefgo/samba-ad.git && cd samba-ad
cp .env.example .env          # set SAMBA_HOST_ADDRESS and SAMBA_REALM
./init.sh provision           # new domain; "./init.sh join" adds a DC to an existing one
```

`init.sh` checks the settings, asks before it changes anything, starts the
domain controller and checks it. Afterwards:

```sh
docker compose logs -f                        # log
docker compose exec samba-dc diagnose         # check, with hints for every problem
docker compose pull && docker compose up -d   # update
```

## Documentation

- [Installation](https://stefgo.github.io/samba-ad/installation/): requirements, new domain, further domain controllers
- [Configuration](https://stefgo.github.io/samba-ad/configuration/): every setting of `.env`
- [Operation](https://stefgo.github.io/samba-ad/operation/): updates, backup and restore
- [Troubleshooting](https://stefgo.github.io/samba-ad/troubleshooting/)
- Optional: [virtual address](https://stefgo.github.io/samba-ad/virtual-address/),
  [TLS certificates and Let's Encrypt](https://stefgo.github.io/samba-ad/tls/),
  [SADM agent](https://stefgo.github.io/samba-ad/sadm-agent/)
- [Development](https://stefgo.github.io/samba-ad/development/): layout, tests, releases

The sources of the documentation are in [`docs/`](docs/).
