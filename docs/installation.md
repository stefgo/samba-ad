# Installation

## Requirements

- A Linux host with Docker and the Compose plugin, one per domain controller.
- A **fixed IPv4 address** for the host.
- The **host name** of the host becomes the name of the domain controller:
  at most 15 letters, digits or `-`, e.g. `dc1`. Choose it before the setup;
  renaming a domain controller later is not supported.
- **Synchronized time** (e.g. chrony or systemd-timesyncd). Kerberos fails
  when clocks differ by more than five minutes.
- The ports 53, 88, 135, 139, 389, 445, 464, 636, 3268 and 3269 are free on
  the host. On many distributions a local DNS cache (`systemd-resolved`,
  `dnsmasq`) holds port 53; see
  [Port is already in use](troubleshooting.md#port-is-already-in-use).

## Get the files

The host needs `compose.yaml`, `init.sh`, `.env.example`, `acme.env.example`
and `sadm-config.yaml` of this repository, e.g.:

```sh
git clone https://github.com/stefgo/samba-ad.git
cd samba-ad
```

## Set up a new domain

1. Create the settings and fill in the two required values,
   `SAMBA_HOST_ADDRESS` and `SAMBA_REALM`:

    ```sh
    cp .env.example .env
    nano .env
    ```

2. Create the domain. The script checks the settings, shows what it will do
   and asks for the password of the domain administrator:

    ```sh
    ./init.sh provision
    ```

3. Let it start the domain controller at the end. It waits until the services
   answer and runs [`diagnose`](operation.md#check-the-domain-controller),
   which should report no failed check.

### After the setup

- Point the clients' DNS to the address of the domain controller; Windows
  finds the domain through DNS only.
- Join a client: on Windows *Settings → Accounts → Access work or school →
  Join this device to a local Active Directory domain*, user `Administrator`.
- Set up a [backup](operation.md#backup).
- A second domain controller makes the domain survive the loss of one host:
  see the next section.

## Add a domain controller

On a further host, with its own fixed address and host name:

1. Create `.env` with the same `SAMBA_REALM` and set `SAMBA_PEER_SERVER` to
   the fixed address of an existing domain controller.
2. Run:

    ```sh
    ./init.sh join
    ```

    It first checks that the peer answers, belongs to the domain and that the
    clocks agree. The password is that of the existing `Administrator`.

### After a join

Samba replicates the directory and DNS between domain controllers, but not
the sysvol (group policies and logon scripts):

- Copy the content of `sysvol/<realm>/Policies` from an existing domain
  controller, then reset the ACLs:

    ```sh
    docker compose exec samba-dc samba-tool ntacl sysvolreset
    ```

- Or, for policies without settings of their own, let
  [`restore-gpo-folders`](operation.md#missing-group-policy-folders) create
  the missing folders.

Give the clients the addresses of both domain controllers as DNS servers, or
one [virtual address](virtual-address.md).

## Start again later

The setup is done once. Afterwards the domain controller is an ordinary
Compose service:

```sh
docker compose up -d       # start, also after a change of .env
docker compose down        # stop; the volumes stay
```

!!! warning "init.sh deletes"
    Running `./init.sh` again deletes the volumes of this domain controller
    and sets it up anew. It asks first and offers to save the volumes.
