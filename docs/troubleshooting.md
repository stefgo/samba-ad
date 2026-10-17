# Troubleshooting

Start with these two; most problems show up there:

```sh
docker compose logs --tail 100 samba-dc
docker compose exec samba-dc diagnose
```

Error messages of the container start with `samba-ad: ERROR:` and link to
the matching section below.

## The container does not start

### Has not been set up yet

`This domain controller has not been set up yet.` — the volumes hold no
domain. Run `./init.sh provision` or `./init.sh join` first, see
[Installation](installation.md).

### Address is not an address of this host

`SAMBA_HOST_ADDRESS … is not an address of this host` — the address in
`.env` is not configured on any interface of the host. The message lists
the addresses the host has. Use the fixed address of the host; a virtual
address belongs in `SAMBA_DNS_VIRTUAL_ADDRESSES` or
`SAMBA_LDAP_VIRTUAL_ADDRESSES`. The same applies to every
address in `SAMBA_INTERFACES`.

### Host name is not suitable

The name of the domain controller is the host name of the host
(`hostname -s`). It has at most 15 letters, digits or `-` and must differ
from the NetBIOS name of the domain (`SAMBA_WORKGROUP`). Rename the host
(`hostnamectl set-hostname dc1`) *before* the setup; a domain controller
cannot be renamed afterwards.

### Port is already in use

`Port 53 is already in use on this host` — another program listens on a
port the domain controller needs. Find it on the host:

```sh
sudo ss -ltnup 'sport = :53'
```

Typical cases:

- **systemd-resolved** listens on 127.0.0.53 and 127.0.0.54 only, which does
  not collide. If it listens on further addresses (`DNSStubListenerExtra=`),
  remove them.
- **dnsmasq**, **unbound** or a second BIND: stop and disable it,
  e.g. `sudo systemctl disable --now dnsmasq`.
- **smbd/nmbd** of the host (ports 139, 445): `sudo systemctl disable --now smbd nmbd`.
- A second container of this domain controller: `docker ps`.

### Samba rejects the configuration

`Samba rejects the generated smb.conf` — usually a file below
`/etc/samba/conf.d` contains an unknown or misspelled setting; the message
shows Samba's complaint. Correct or remove the file:

```sh
docker compose run --rm samba-dc ls /etc/samba/conf.d
docker compose run --rm samba-dc rm /etc/samba/conf.d/local.conf
```

### Wrong setting

Every other `samba-ad: ERROR:` names the setting and the accepted values;
correct it in `.env` and run `docker compose up -d`. `docker compose run --rm
samba-dc check` repeats the checks without starting anything.

## The container restarts repeatedly

### A program does not start

When BIND or Samba fail to start three times, the container stops itself
with `could not be started` and Docker starts it again. The cause is in the
lines before that message:

```sh
docker compose logs samba-dc | grep -B 30 "could not be started"
```

## Domain and DNS

### DNS records are missing

`diagnose` reports missing service records, or clients do not find the
domain. Samba registers its records in BIND at start and every ten minutes.
Run the update by hand and read its output:

```sh
docker compose exec samba-dc samba_dnsupdate --verbose
```

Check also that the clients use the domain controller as DNS server: Windows
finds the domain through DNS only.

### External names do not resolve

The domain controller resolves names outside the domain only for
`SAMBA_DNS_ALLOW_RECURSION` (default: the host and its networks). For
clients behind a router, add their networks. Without access to the root
servers of the internet, set `SAMBA_DNS_FORWARDERS` to a DNS server of your
network.

### Clocks differ

Kerberos refuses tickets when clocks differ by more than five minutes;
joins and logons then fail. Synchronize the time of all hosts with the same
source, e.g. with chrony:

```sh
timedatectl          # "System clock synchronized: yes"
chronyc tracking
```

Windows clients take their time from a domain controller of the domain.
This image does not sign the time for them (Samba's `ntp_signd`
needs an NTP server inside the container); give Windows clients an NTP
server by group policy if they drift.

## Several domain controllers

### Join fails

- `does not answer on LDAP`: `SAMBA_PEER_SERVER` is wrong, the peer is not
  running, or a firewall blocks port 389.
- `is a domain controller of …, not of …`: `SAMBA_REALM` does not match the
  domain of the peer.
- `The clock … differs`: see [Clocks differ](#clocks-differ).
- `Failed to bind … NT_STATUS_LOGON_FAILURE` during the join: wrong password.

A failed join leaves incomplete volumes; fix the cause and run
`./init.sh join` again.

### Replication fails

`diagnose` shows the failing partner and naming context. Look at the details:

```sh
docker compose exec samba-dc samba-tool drs showrepl
```

Typical causes are DNS (the partner's name does not resolve to its fixed
address), the clock, or a firewall between the domain controllers. A
domain controller that stays broken is best removed and joined again, see
[Restore](operation.md#restore).

### The database check finds errors

`samba-tool dbcheck` lists the problems. Many can be repaired; back up
first:

```sh
docker compose exec samba-dc backup
docker compose exec samba-dc samba-tool dbcheck --cross-ncs --fix
```

## Still stuck?

Open an [issue](https://github.com/stefgo/samba-ad/issues) with the output
of `diagnose` and the start of the log (`docker compose logs samba-dc | head
-n 60`); remove names and addresses you do not want to publish.
