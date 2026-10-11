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
      -e "s:{{ BIND_HOST_IP }}:$BIND_HOST_IP:" \
      "/root/$(basename $file).j2" > $file
done

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
