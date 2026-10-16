#!/bin/bash -e

if [ -z "$NETBIOS_NAME" ]; then
  NETBIOS_NAME=$(hostname -s | tr '[:lower:]' '[:upper:]')
else
  NETBIOS_NAME=$(echo "$NETBIOS_NAME" | tr '[:lower:]' '[:upper:]')
fi

REALM=$(echo "$REALM" | tr '[:upper:]' '[:lower:]')

if [ ! -f /etc/timezone ] && [ -n "$TZ" ]; then
  echo 'Set timezone'
  cp "/usr/share/zoneinfo/$TZ" /etc/localtime
  echo "$TZ" >/etc/timezone
fi

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

case "$BIND_INTERFACES_ONLY" in
  yes|no) ;;
  *) fail "BIND_INTERFACES_ONLY must be yes or no (got '$BIND_INTERFACES_ONLY')." ;;
esac

case "$SADM_AGENT" in
  yes|no) ;;
  *) fail "SADM_AGENT must be yes or no (got '$SADM_AGENT')." ;;
esac

# A virtual address moves between the DCs. Samba registers every address of
# its "interfaces" setting as A record of this DC, so the virtual address
# must never end up there - neither directly nor through an interface name.
if [ -n "$BIND_VIRTUAL_IPS" ]; then
  if [ -z "$INTERFACES" ]; then
    fail "INTERFACES is required when a virtual address is configured."
  fi
  for entry in $INTERFACES; do
    if [[ ! $entry =~ ^[0-9A-Fa-f.:]+/[0-9]+$ ]]; then
      fail "INTERFACES entry '$entry' must have the form address/prefix" \
        "when a virtual address is configured (no interface names)."
    fi
  done
fi
for vip in $BIND_VIRTUAL_IPS; do
  if [[ ! $vip =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    fail "Virtual address '$vip' is not an IPv4 address without prefix."
  fi
  if [ "$vip" == "$BIND_HOST_IP" ]; then
    fail "Virtual address $vip must differ from the host address."
  fi
  if [ "$vip" == "$PEER_SERVER" ]; then
    fail "Virtual address $vip must not be used as PEER_SERVER."
  fi
  for entry in $DNS_FORWARDER; do
    if [ "$vip" == "$entry" ]; then
      fail "Virtual address $vip must not be used as DNS forwarder."
    fi
  done
  for entry in $INTERFACES; do
    if [ "$vip" == "${entry%%/*}" ]; then
      fail "Virtual address $vip must not be listed in INTERFACES."
    fi
  done
done

if { [ -f /tls/cert.pem ] && [ ! -f /tls/key.pem ]; } ||
    { [ ! -f /tls/cert.pem ] && [ -f /tls/key.pem ]; }; then
  fail "A custom certificate needs both /tls/cert.pem and /tls/key.pem."
fi

case "$LETSENCRYPT" in
  yes|no) ;;
  *) fail "LETSENCRYPT must be yes or no (got '$LETSENCRYPT')." ;;
esac

# The names of the certificate are those under which applications reach the
# LDAP server. They are independent of the realm: nothing ties them to it.
if [ "$LETSENCRYPT" == yes ]; then
  if [ -f /tls/cert.pem ]; then
    fail "Let's Encrypt and a certificate in /tls exclude each other;" \
      "remove tls/cert.pem and tls/key.pem or set SAMBA_LETSENCRYPT=no."
  fi
  if [ -z "$ACME_DOMAINS" ]; then
    fail "ACME_DOMAINS is required for Let's Encrypt."
  fi
  for name in $ACME_DOMAINS; do
    if [[ ! $name =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
      fail "ACME_DOMAINS entry '$name' is not a DNS name."
    fi
  done
  if [ -z "$ACME_EMAIL" ]; then
    fail "ACME_EMAIL is required for Let's Encrypt."
  fi
  case "$ACME_KEY_TYPE" in
    rsa2048|ec256) ;;
    *) fail "ACME_KEY_TYPE must be rsa2048 or ec256 (got '$ACME_KEY_TYPE')." ;;
  esac
  if [[ ! $ACME_PROPAGATION_SECONDS =~ ^[0-9]+$ ]]; then
    fail "ACME_PROPAGATION_SECONDS must be a number of seconds."
  fi
  if [ -n "${CLOUDFLARE_DNS_API_TOKEN:-}" ] &&
      [ -n "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]; then
    fail "Set CLOUDFLARE_DNS_API_TOKEN or CLOUDFLARE_DNS_API_TOKEN_FILE, not both."
  fi
  if [ -n "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]; then
    [ -r "$CLOUDFLARE_DNS_API_TOKEN_FILE" ] ||
      fail "CLOUDFLARE_DNS_API_TOKEN_FILE cannot be read: $CLOUDFLARE_DNS_API_TOKEN_FILE"
    CLOUDFLARE_DNS_API_TOKEN=$(tr -d '[:space:]' < "$CLOUDFLARE_DNS_API_TOKEN_FILE")
  fi
  if [ -z "${CLOUDFLARE_DNS_API_TOKEN:-}" ]; then
    fail "Let's Encrypt needs the Cloudflare API token:" \
      "CLOUDFLARE_DNS_API_TOKEN in acme.env next to compose.yaml."
  fi
fi

if [ $# == 1 ] && [ "$1" == "init" ]; then
  if [ -f /var/lib/samba/private/secrets.ldb ]; then
    echo Samba already initialized - cleanup first!
    exit 1
  fi

  if [ "$DOMAIN_ACTION" != provision ] && [ "$DOMAIN_ACTION" != join ]; then
    echo 'Only provision and join actions are supported.'
    exit 1
  fi

  if [ -z "$ADMIN_PASSWORD" ]; then
    read -r -s -p "Password: " ADMIN_PASSWORD
    echo
  fi

  INTERFACE_OPTS=()
  if [ -n "$INTERFACES" ]; then
    INTERFACE_OPTS=("--option=bind interfaces only=yes"
      "--option=interfaces=$INTERFACES")
  fi

  if [ "$DOMAIN_ACTION" == provision ]; then
    PROVISION_OPTS=(--server-role=dc --use-rfc2307 "--domain=$WORKGROUP"
      "--realm=$REALM")
    PASSWORD_OPT="--adminpass=$ADMIN_PASSWORD"
  else
    PROVISION_OPTS=("$REALM" DC -UAdministrator)
    if [ -n "$PEER_SERVER" ]; then
      PROVISION_OPTS+=("--server=$PEER_SERVER")
    fi
    PASSWORD_OPT="--password=$ADMIN_PASSWORD"
  fi

  unset ADMIN_PASSWORD

  rm -f /etc/samba/smb.conf /etc/krb5.conf

  # The password option is deliberately left out of the logged command
  echo "samba-tool domain $DOMAIN_ACTION ${PROVISION_OPTS[*]}" \
    "${INTERFACE_OPTS[*]} --dns-backend=BIND9_DLZ"
  samba-tool domain "$DOMAIN_ACTION" "${PROVISION_OPTS[@]}" "$PASSWORD_OPT" \
    "${INTERFACE_OPTS[@]}" --dns-backend=BIND9_DLZ

  unset PASSWORD_OPT

  mv /etc/bind/named.conf /etc/bind/named.conf.bak
  mv /etc/samba/smb.conf /etc/samba/smb.conf.bak

  echo 'root = administrator' > /etc/samba/smbusers
fi

# /etc/samba exists, so -m applies to the only directory that is created
# shellcheck disable=SC2174
mkdir -p -m 700 /etc/samba/conf.d

# Samba uses the BIND 9.18 DLZ module for BIND 9.20 as well
DLZ_MODULE=$(ls /usr/lib/*-linux-gnu/samba/bind9/dlz_bind9_18.so)

FORWARDERS=
if [ -n "$DNS_FORWARDER" ]; then
  read -ra forwarders <<< "$DNS_FORWARDER"
  FORWARDERS="forwarders { $(printf '%s; ' "${forwarders[@]}")};"
fi

# 127.0.0.1 allows local health checks, e.g. from keepalived
LISTEN_ON="127.0.0.1;"
for address in $BIND_HOST_IP $BIND_VIRTUAL_IPS; do
  if [[ " $LISTEN_ON" != *" $address;"* ]]; then
    LISTEN_ON+=" $address;"
  fi
done

# Reads /root/<name>.j2 and writes <file>, never the same file
# shellcheck disable=SC2094
for file in /etc/bind/named.conf \
      /etc/samba/smb.conf /etc/samba/conf.d/netlogon.conf \
      /etc/samba/conf.d/sysvol.conf; do
  sed -e "s:{{ DNS_FORWARDER }}:$DNS_FORWARDER:" \
      -e "s:{{ FORWARDERS }}:$FORWARDERS:" \
      -e "s:{{ DLZ_MODULE }}:$DLZ_MODULE:" \
      -e "s:{{ ALLOW_DNS_UPDATES }}:$ALLOW_DNS_UPDATES:" \
      -e "s:{{ DOMAIN_MASTER }}:$DOMAIN_MASTER:" \
      -e "s+{{ INTERFACES }}+$INTERFACES+" \
      -e "s:{{ LOG_LEVEL }}:$LOG_LEVEL:" \
      -e "s:{{ NETBIOS_NAME }}:$NETBIOS_NAME:" \
      -e "s:{{ REALM }}:$REALM:" \
      -e "s:{{ SERVER_STRING }}:$SERVER_STRING:" \
      -e "s:{{ WINBIND_USE_DEFAULT_DOMAIN }}:$WINBIND_USE_DEFAULT_DOMAIN:" \
      -e "s:{{ WORKGROUP }}:$WORKGROUP:" \
      -e "s:{{ LISTEN_ON }}:$LISTEN_ON:" \
      -e "s:{{ BIND_INTERFACES_ONLY }}:$BIND_INTERFACES_ONLY:" \
      "/root/$(basename "$file").j2" > "$file"
done

# Samba insists on a private key that only root can read, so the mounted
# files are copied instead of being used in place.
rm -rf /etc/samba/tls
if [ "$LETSENCRYPT" == yes ]; then
  letsencrypt.sh install
  {
    echo '	tls enabled = yes'
    echo '	tls certfile = /etc/samba/tls/cert.pem'
    echo '	tls keyfile = /etc/samba/tls/key.pem'
    # The chain is part of the certfile
    echo '	tls cafile ='
  } >> /etc/samba/smb.conf
elif [ -f /tls/cert.pem ]; then
  echo 'Using the custom TLS certificate from /tls'
  mkdir -m 700 /etc/samba/tls
  install -m 644 /tls/cert.pem /etc/samba/tls/cert.pem
  install -m 600 /tls/key.pem /etc/samba/tls/key.pem
  {
    echo '	tls enabled = yes'
    echo '	tls certfile = /etc/samba/tls/cert.pem'
    echo '	tls keyfile = /etc/samba/tls/key.pem'
    if [ -f /tls/ca.pem ]; then
      install -m 644 /tls/ca.pem /etc/samba/tls/ca.pem
      echo '	tls cafile = /etc/samba/tls/ca.pem'
    else
      # Without this, Samba looks for its own generated CA and fails to start
      echo '	tls cafile ='
    fi
  } >> /etc/samba/smb.conf
fi

for file in /etc/samba/conf.d/*.conf; do
  echo "include = $file" >> /etc/samba/smb.conf
done

ln -fns /var/lib/samba/private/krb5.conf /etc/

if [ $# == 1 ] && [ "$1" == "init" ]; then
  exit 0
else
  export MODEL

  # The SADM agent is a program of the same supervisord. It reads LOG_LEVEL
  # as well, but expects a name instead of Samba's number. Samba's default (1)
  # and the agent's default (info) both mean normal operation, so the scale is
  # shifted by one step compared to Samba's own names.
  mkdir -p /etc/supervisor/conf.d
  rm -f /etc/supervisor/conf.d/sadm-client.conf
  if [ "$SADM_AGENT" == yes ]; then
    # LOG_LEVEL may carry debug classes ("1 auth:3"); the leading number counts
    case "${LOG_LEVEL%%[!0-9]*}" in
      0) SADM_LOG_LEVEL=warn ;;
      ''|1|2) SADM_LOG_LEVEL=info ;;
      10) SADM_LOG_LEVEL=trace ;;
      *) SADM_LOG_LEVEL=debug ;;
    esac
    echo "Starting the SADM agent (log level $SADM_LOG_LEVEL)"
    {
      cat /opt/sadm-client/supervisor.conf
      echo "environment=LOG_LEVEL=\"$SADM_LOG_LEVEL\""
    } > /etc/supervisor/conf.d/sadm-client.conf
  fi

  # The API token goes to certbot alone, in a file only root can read; Samba,
  # BIND and the agent are started without it.
  rm -f /etc/supervisor/conf.d/letsencrypt.conf
  rm -rf /run/letsencrypt
  if [ "$LETSENCRYPT" == yes ]; then
    echo "Starting Let's Encrypt for $ACME_DOMAINS"
    mkdir -m 700 /run/letsencrypt
    (umask 077; echo "dns_cloudflare_api_token = $CLOUDFLARE_DNS_API_TOKEN" \
      > /run/letsencrypt/cloudflare.ini)
    cp /etc/supervisor/letsencrypt.conf /etc/supervisor/conf.d/
  fi
  unset CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_DNS_API_TOKEN_FILE

  exec supervisord
fi
