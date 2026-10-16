#!/bin/bash -e
#
# The Let's Encrypt certificate of Samba's LDAP server (LDAPS and StartTLS).
#
#   letsencrypt.sh install  Copy the certificate to /etc/samba/tls; until one
#                           is issued, a temporary self-signed one for the
#                           same names. Run by entrypoint.sh before Samba.
#   letsencrypt.sh run      Obtain, renew and keep the names in line with
#                           ACME_DOMAINS, for as long as the container runs.
#                           A program of supervisord.
#   letsencrypt.sh deploy   certbot's deploy hook: install the new certificate
#                           and have Samba load it, without a restart.
#
# The DNS-01 challenge is answered through Cloudflare's API. Samba never waits
# for any of this: it starts with what /etc/samba/tls holds.

ACME_DIR=/var/lib/acme
LINEAGE=samba
LIVE=$ACME_DIR/live/$LINEAGE
CREDENTIALS=/run/letsencrypt/cloudflare.ini
TLS_DIR=/etc/samba/tls

# How long to wait between rounds once a round succeeded, and the longest
# wait after one that failed
ROUND_SECONDS=$((12 * 3600))
# Up to an hour on top, so that the domain controllers do not all ask at once
JITTER_SECONDS=3600
FIRST_RETRY_SECONDS=300

log() {
  echo "letsencrypt: $*"
}

install_certificate() {
  mkdir -p -m 700 "$TLS_DIR"
  if [ -f "$LIVE/fullchain.pem" ]; then
    # Samba insists on a private key that only root can read
    install -m 644 "$LIVE/fullchain.pem" "$TLS_DIR/cert.pem"
    install -m 600 "$LIVE/privkey.pem" "$TLS_DIR/key.pem"
    log "Using the Let's Encrypt certificate for $ACME_DOMAINS"
  else
    # Samba's own certificate lives elsewhere and smb.conf names this
    # directory, so the time until the first issue is bridged here
    local san=
    for name in $ACME_DOMAINS; do
      san+="${san:+,}DNS:$name"
    done
    openssl req -x509 -newkey rsa:2048 -noenc -days 30 -sha256 \
      -subj "/CN=${ACME_DOMAINS%% *}" -addext "subjectAltName=$san" \
      -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" 2>/dev/null
    chmod 600 "$TLS_DIR/key.pem"
    log "No Let's Encrypt certificate yet: using a temporary self-signed" \
      "one until it is issued"
  fi
}

reload_samba() {
  # The LDAP server may still be starting when the first certificate arrives
  for attempt in 1 2 3 4 5 6; do
    if smbcontrol ldap_server reload-certs >/dev/null 2>&1; then
      log "Samba's LDAP server loaded the new certificate"
      return 0
    fi
    sleep 10
  done
  log "Samba's LDAP server could not be told to load the new certificate;" \
    "it takes effect with the next restart of the container"
}

obtain() {
  local args=(certonly --non-interactive --agree-tos
    --email "$ACME_EMAIL"
    --config-dir "$ACME_DIR" --work-dir "$ACME_DIR/work"
    --logs-dir /var/log/letsencrypt
    --dns-cloudflare --dns-cloudflare-credentials "$CREDENTIALS"
    --dns-cloudflare-propagation-seconds "$ACME_PROPAGATION_SECONDS"
    # One lineage under a fixed name: certbot then changes its names to
    # those asked for instead of starting a second one
    --cert-name "$LINEAGE"
    # Issue when there is none, renew when it is due (a third of its
    # lifetime left), otherwise keep it
    --keep-until-expiring
    --deploy-hook "/usr/local/bin/letsencrypt.sh deploy")
  case "$ACME_KEY_TYPE" in
    rsa2048) args+=(--key-type rsa --rsa-key-size 2048) ;;
    ec256) args+=(--key-type ecdsa --elliptic-curve secp256r1) ;;
  esac
  if [ -n "$ACME_SERVER" ]; then
    args+=(--server "$ACME_SERVER")
  fi
  for name in $ACME_DOMAINS; do
    args+=(-d "$name")
  done
  certbot "${args[@]}"
}

run() {
  local retry=$FIRST_RETRY_SECONDS wait
  while true; do
    if obtain; then
      retry=$FIRST_RETRY_SECONDS
      wait=$((ROUND_SECONDS + RANDOM % JITTER_SECONDS))
      log "Next check in $((wait / 3600)) hours"
    else
      wait=$retry
      log "Obtaining the certificate failed (see above); the current one" \
        "stays in use. Next attempt in $((wait / 60)) minutes"
      retry=$((retry * 2))
      if [ $retry -gt $ROUND_SECONDS ]; then
        retry=$ROUND_SECONDS
      fi
    fi
    sleep "$wait"
  done
}

case "${1:-}" in
  install) install_certificate ;;
  run) run ;;
  deploy)
    install_certificate
    reload_samba
    ;;
  *)
    echo "Usage: $0 install|run|deploy" >&2
    exit 1
    ;;
esac
