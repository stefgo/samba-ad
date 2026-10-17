# SADM agent

[Samba AD Manager](https://github.com/stefgo/samba-ad-manager) (SADM)
watches domain controllers over the network. Its agent runs inside this
container and reports what cannot be asked that way: the services of Samba,
the programs of supervisord, free space, the group policy versions in the
sysvol and a read-only database check. It changes nothing on the domain
controller.

The agent is part of the image and off by default. Switch it on per domain
controller in `.env` and recreate the container:

```sh
SADM_AGENT=yes
```

```sh
docker compose up -d
```

It runs as a program of supervisord after BIND and Samba and is not part of
the health check: a domain controller whose agent is down keeps running.

## Registering the agent

Each agent is registered once, with "Add Agent" on the page of its domain
controller in SADM. There are two ways:

- **The agent connects to the server.** Generate a token in SADM, set
  `SADM_SERVER_URL` and `SADM_REGISTRATION_TOKEN` and recreate the container.
  The token is valid for one registration and one hour; remove it from `.env`
  afterwards. Nothing listens on the domain controller.
- **The server connects to the agent.** Leave `SADM_SERVER_URL` empty. The
  agent listens on `listenPort` from `sadm-config.yaml` (3021) and prints a
  setup PIN into the log (`docker compose logs samba-dc | grep PIN`). Enter
  the address of the domain controller and the PIN in SADM. The port is open
  on every address of the host; restrict it with a firewall or with
  `allowedNetworks` in `sadm-config.yaml`.

The agent keeps its identity in `/var/lib/samba/sadm-client`, in the volume
`samba-dc-lib`. `init.sh` deletes that volume, so a domain controller set up
anew has to be registered again. To register an existing one again, delete
`identity.json` in that directory and restart the container.

## Settings

| Setting in `.env` | Meaning |
|---|---|
| `SADM_AGENT` | `yes` starts the agent; default `no` |
| `SADM_SERVER_URL` | URL of the SADM server, e.g. `https://sadm.example.net`. Empty: the agent waits for the server to connect |
| `SADM_REGISTRATION_TOKEN` | Token from "Add Agent", only for the registration |
| `SADM_ALLOW_SELF_SIGNED` | `true` accepts a server certificate that does not validate |

Every further `SADM_*` variable of the
[agent](https://github.com/stefgo/samba-ad-manager/blob/main/docs/agent.md)
can be set in `.env` as well.

Everything else lives in `sadm-config.yaml` next to `compose.yaml`, mounted
as the agent's `config.yaml`. Each key in it is commented out and shows its
default. Remove the `#` of a key, change its value and run `docker compose
restart samba-dc`. The variables win over the file as long as they are not
empty. When the server connects to the agent, the agent writes the server's
URL into the file itself, which is why it is mounted writable.

Without `logLevel` in `sadm-config.yaml` the agent follows
`SAMBA_LOG_LEVEL`, shifted so that the default of Samba is the default of
the agent:

| `SAMBA_LOG_LEVEL` | Agent |
|---|---|
| `0` | `warn` |
| `1`, `2` | `info` |
| `3` to `9` | `debug` |
| `10` | `trace` |
