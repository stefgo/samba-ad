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

mkdir -p -m 700 /etc/samba/conf.d

# Samba uses the BIND 9.18 DLZ module for BIND 9.20 as well
DLZ_MODULE=$(ls /usr/lib/*-linux-gnu/samba/bind9/dlz_bind9_18.so)

FORWARDERS=
if [ -n "$DNS_FORWARDER" ]; then
  FORWARDERS="forwarders { $(echo $DNS_FORWARDER | sed 's/ /; /g'); };"
fi

# 127.0.0.1 allows local health checks, e.g. from keepalived
LISTEN_ON="127.0.0.1;"
for address in $BIND_HOST_IP $BIND_VIRTUAL_IPS; do
  if [[ " $LISTEN_ON" != *" $address;"* ]]; then
    LISTEN_ON+=" $address;"
  fi
done

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
      "/root/$(basename $file).j2" > $file
done

# Samba insists on a private key that only root can read, so the mounted
# files are copied instead of being used in place.
rm -rf /etc/samba/tls
if [ -f /tls/cert.pem ]; then
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

  exec supervisord
fi
