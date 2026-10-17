# TLS certificates

Samba serves LDAPS (636) and StartTLS (389) with a certificate. There are
three sources; `diagnose` shows which certificate is in use and when it
expires.

| Source | When | Setting |
|---|---|---|
| Self-signed by Samba | Default; fine for domain members, which do not check it | nothing |
| [Let's Encrypt](#lets-encrypt) | Applications connect by a name in a public domain | `SAMBA_LETSENCRYPT=yes` |
| [Own certificate](#own-certificate) | Names inside a private realm, or an own CA | files in `tls/` |

Let's Encrypt and an own certificate exclude each other.

## Let's Encrypt

The domain controller obtains a certificate for the names applications use
and renews it before it expires. The challenge is answered through DNS
(DNS-01) with Cloudflare's API, so the names need not be reachable from the
internet; only their domain has to be at Cloudflare.

Requirements:

- A Cloudflare API token with the permissions **Zone / DNS / Edit** and
  **Zone / Zone / Read**, restricted to the zones of the names
  (*My Profile → API Tokens → Create Token*, template "Edit zone DNS").
- No certificate in `tls/`.

Put the token into `acme.env` next to `compose.yaml`:

```sh
cp acme.env.example acme.env
chmod 600 acme.env
nano acme.env        # CLOUDFLARE_DNS_API_TOKEN=...
```

and switch Let's Encrypt on in `.env`:

```sh
SAMBA_LETSENCRYPT=yes
ACME_DOMAINS=ldap.example.net
ACME_EMAIL=hostmaster@example.net
```

| Setting | Default | Meaning |
|---|---|---|
| `SAMBA_LETSENCRYPT` | `no` | `yes` obtains and renews the certificate |
| `ACME_DOMAINS` | | Names in the certificate, space-separated; the first becomes the common name |
| `ACME_EMAIL` | | Contact address of the Let's Encrypt account |
| `ACME_SERVER` | Let's Encrypt | ACME directory; `https://acme-staging-v02.api.letsencrypt.org/directory` for a test |
| `ACME_KEY_TYPE` | `rsa2048` | `rsa2048` or `ec256`; RSA works with older LDAP clients as well |
| `ACME_PROPAGATION_SECONDS` | `30` | Seconds to wait for the DNS record before Let's Encrypt checks it |

Then `docker compose up -d`. What happens:

- Samba never waits for the certificate. Until the first one is issued it
  uses a temporary self-signed one for the same names.
- certbot checks the certificate at the start and every 12 to 13 hours and
  renews it once a third of its lifetime is left. A changed `ACME_DOMAINS`
  takes effect at the next start.
- Samba loads a new certificate without a restart; open connections stay up.
- If obtaining it fails, e.g. with a wrong token, the current certificate
  stays in use, the log says why (`docker compose logs samba-dc | grep
  letsencrypt`) and certbot tries again after 5 minutes, then with growing
  distance up to 12 hours.
- Account and certificates are kept in `letsencrypt/` on the host, so a
  domain controller set up anew reuses them instead of running into the rate
  limits of Let's Encrypt.

The token reaches certbot only; Samba, BIND and the SADM agent run without
it. It is still visible in `docker inspect`. To avoid that, mount it as a
file (e.g. a Docker secret) and name the file in
`CLOUDFLARE_DNS_API_TOKEN_FILE` instead.

Test with the staging server first (`ACME_SERVER`): its certificates are not
trusted, but its rate limits are generous. Remove `letsencrypt/` before
switching to the real one. Check from a client:

```sh
openssl s_client -connect ldap.example.net:636 </dev/null | grep -E "subject=|issuer=|Verify return code"
openssl s_client -connect ldap.example.net:389 -starttls ldap </dev/null | grep "Verify return code"
```

## Own certificate

Place these files in `tls/` next to `compose.yaml` and restart the container:

| File | Content |
|---|---|
| `tls/cert.pem` | Certificate; list the central name and the host names of the domain controllers as subject alternative names |
| `tls/key.pem` | Private key, unencrypted |
| `tls/ca.pem` | Optional: certificate of the issuing CA |

The files are copied into the container at every start, so a renewed
certificate becomes active with `docker compose restart`. The log then
shows `TLS certificate own certificate from tls/cert.pem`.

### Creating one with an own CA

One certificate for all domain controllers that carries the central name and
their host names still matches after a failover; clients only have to trust
the CA. Run these commands on any machine with `openssl` and adjust the
names.

Create the CA once. `ca-key.pem` is protected by a passphrase and does not
belong on the domain controllers:

```sh
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
  -keyout ca-key.pem -out ca.pem -subj "/CN=EXAMPLE.LAN LDAP CA"
```

Create the key (Samba cannot read a key with a passphrase, hence `-noenc`)
and the certificate:

```sh
openssl req -newkey rsa:2048 -noenc -keyout key.pem -out dc.csr -subj "/CN=ldap.example.lan"

cat > dc.ext <<'EOF'
subjectAltName = DNS:ldap.example.lan, DNS:dc1.example.lan, DNS:dc2.example.lan, IP:192.168.1.100
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

openssl x509 -req -in dc.csr -sha256 -days 825 \
  -CA ca.pem -CAkey ca-key.pem -CAcreateserial -extfile dc.ext -out cert.pem
```

The `IP:` entry is only needed if applications connect by the virtual
address itself. Check, copy `cert.pem`, `key.pem` and `ca.pem` into `tls/`
on every domain controller and restart:

```sh
openssl verify -CAfile ca.pem cert.pem
chmod 600 tls/key.pem
docker compose restart
```

From a client, this must report `Verify return code: 0 (ok)`:

```sh
openssl s_client -connect ldap.example.lan:636 -CAfile ca.pem </dev/null | grep "Verify return code"
```

Every application that connects with TLS needs `ca.pem` as a trusted CA. To
renew, repeat the steps from the key on; the CA stays.
