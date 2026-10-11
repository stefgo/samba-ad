# samba-ad-docker

Samba Active Directory Domain Controller als Docker-Container, mit BIND 9 als
DNS-Backend (`BIND9_DLZ`). Basis ist Debian trixie; Samba kommt wahlweise aus
trixie (4.22) oder trixie-backports (4.24).

## Voraussetzungen

- Linux-Host mit Docker und dem Compose-Plugin
- Der Container läuft mit `network_mode: host`. Auf dem Host dürfen die
  Ports von DNS (53), Kerberos (88, 464), LDAP (389, 636, 3268, 3269) und
  SMB (135, 139, 445) nicht belegt sein.
- Der Kurzname des Hosts wird zum NetBIOS-Namen des Domain Controllers.
- Der Container erhält die Capability `SYS_ADMIN`. Samba speichert NT-ACLs in
  `security.*`-xattrs; ohne diese Capability schlägt das Provisioning beim
  Setzen der Sysvol-ACLs fehl.

## Konfiguration

```sh
cp .env.example .env
```

| Variable | Bedeutung |
|---|---|
| `SAMBA_HOST_NAME` | Kurzname des Docker-Hosts |
| `SAMBA_HOST_ADDRESS` | IP-Adresse des Hosts; BIND lauscht darauf, im Betrieb DNS-Server des Containers |
| `SAMBA_REALM` | Kerberos-Realm / DNS-Domäne, z. B. `EXAMPLE.LAN` |
| `WORKGROUP` | NetBIOS-Domänenname, z. B. `EXAMPLE` |
| `SAMBA_PEER_SERVER` | Bestehender DC, nur für den Join nötig |
| `SAMBA_INTERFACE` | Schnittstellen, an die Samba bindet |
| `SAMBA_DNS_FORWARDER` | Optional: Forwarder für externe Namen (leerzeichengetrennt) |
| `SAMBA_SUITE` | `trixie` oder `trixie-backports` (Vorgabe) |
| `TZ` | Zeitzone, Vorgabe `UTC` |

Die `.env` enthält standortspezifische Werte und wird nicht eingecheckt.

## Betriebsarten

| Aufruf | Zweck | DNS-Server des Containers |
|---|---|---|
| `./init.sh provision` | Neue Domäne vollständig initialisieren | `SAMBA_HOST_ADDRESS` |
| `./init.sh join` | Initialisieren und einer bestehenden Domäne beitreten | `SAMBA_PEER_SERVER` |
| `docker compose up -d` | Bestehende Installation starten | `SAMBA_HOST_ADDRESS` |

`init.sh` **löscht nach einer Sicherheitsabfrage die Volumes** `samba-dc-etc`,
`samba-dc-lib` und `samba-dc-bind` und fragt anschließend das Passwort des
Domänen-Administrators ab. Bei `provision` wird es neu vergeben, bei `join`
ist es das Passwort der bestehenden Domäne.

Nach der Initialisierung wird der Domain Controller gestartet mit:

```sh
docker compose up -d
```

## Betrieb

```sh
docker compose logs -f                          # Logs von BIND und Samba
docker compose exec samba-dc samba-tool drs showrepl
docker compose exec samba-dc samba-tool dbcheck
docker compose build --pull && docker compose up -d   # Image aktualisieren
```

Ein Wechsel von `SAMBA_SUITE` auf eine neuere Samba-Version ist mit
bestehenden Volumes möglich, der Weg zurück auf eine ältere Version nicht.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `compose.yaml` | Service-Definition und Volumes |
| `init.sh` | Initialisierung (`provision` / `join`) |
| `docker/Dockerfile` | Image mit Samba, BIND und supervisord |
| `docker/entrypoint.sh` | Initialisierung und Erzeugen der Konfiguration beim Start |
| `docker/*.j2` | Vorlagen für `named.conf` und `smb.conf` |

`smb.conf` und `named.conf` werden bei jedem Start aus den Vorlagen neu
erzeugt. Eigene Samba-Einstellungen gehören als `*.conf` nach
`/etc/samba/conf.d` im Volume `samba-dc-etc`.

## Hinweise

- `named.conf` enthält `allow-update { any; }`. Die AD-Zonen werden über das
  DLZ-Modul von Samba verwaltet (`allow dns updates = secure`); wer weitere
  Zonen in BIND einrichtet, sollte die Option einschränken.
- Samba verwendet für BIND 9.20 das DLZ-Modul `dlz_bind9_18.so`.
