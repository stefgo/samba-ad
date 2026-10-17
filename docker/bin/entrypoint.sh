#!/bin/bash
#
# Entrypoint of the image. The settings come from .env, see .env.example.
#
#   start                   Check the settings, write smb.conf and named.conf,
#                           and run BIND, Samba and the optional programs
#                           (the default)
#   provision               Create a new domain (called by init.sh)
#   join                    Join an existing domain (called by init.sh)
#   check provision|join|start [--ports]
#                           Check the settings and show them; changes nothing
#   version                 Show the versions of the components
#
# Any other command is run as is, e.g. "bash".

set -euo pipefail

# shellcheck source=docker/lib/common.sh
. /usr/local/lib/samba-ad/common.sh

# render <template> <file>: writes a file from a template in docker/templates
render() {
  /usr/local/lib/samba-ad/render-template "$1" "$2" ||
    fail "$2 could not be written from $1 (see above)." \
      "Report this at https://github.com/stefgo/samba-ad/issues"
}

# Writes smb.conf and named.conf from the templates in docker/templates. This
# function only finds the values the templates need beyond the settings; the
# text of both files is in the templates.
write_configs() {
  # Samba's DLZ module that matches the installed BIND
  DLZ_MODULE=$(dlz_module)

  # Where Samba's certificate comes from: none (Samba generates one) or own.
  # Samba insists on a private key that only root can read, so the mounted
  # files are copied instead of being used in place. The Let's Encrypt
  # certificate is haproxy's, for the virtual addresses only.
  TLS_SOURCE=none
  rm -rf /etc/samba/tls
  if [ -f /tls/cert.pem ]; then
    mkdir -m 700 /etc/samba/tls
    install -m 644 /tls/cert.pem /etc/samba/tls/cert.pem
    install -m 600 /tls/key.pem /etc/samba/tls/key.pem
    if [ -f /tls/ca.pem ]; then
      install -m 644 /tls/ca.pem /etc/samba/tls/ca.pem
    fi
    TLS_SOURCE=own
  fi
  export DLZ_MODULE TLS_SOURCE

  # /etc/samba exists, so -m applies to the only directory that is created
  # shellcheck disable=SC2174
  mkdir -p -m 700 /etc/samba/conf.d

  render named.conf.j2 /etc/bind/named.conf
  render smb.conf.j2 /etc/samba/smb.conf
  if [ "$SAMBA_LETSENCRYPT" == yes ]; then
    letsencrypt.sh install
  fi
  if [ -n "$SAMBA_VIRTUAL_ADDRESSES" ]; then
    render haproxy.cfg.j2 /etc/haproxy/haproxy.cfg
  fi
  # BIND runs as user bind and keeps its session key here
  install -d -o bind -g bind /run/named

  ln -fns /var/lib/samba/private/krb5.conf /etc/krb5.conf

  local output
  output=$(testparm -s /etc/samba/smb.conf 2>&1 >/dev/null) ||
    fail "Samba rejects the generated smb.conf:" "$output" \
      "Check your files in /etc/samba/conf.d." "docs:troubleshooting/#samba-rejects-the-configuration"
  if grep -qi "unknown parameter\|ignoring" <<< "$output"; then
    warn "Samba reports for smb.conf:"
    grep -i "unknown parameter\|ignoring" <<< "$output" >&2
  fi
  output=$(named-checkconf /etc/bind/named.conf 2>&1) ||
    fail "BIND rejects the generated named.conf:" "$output"
  if [ -n "$SAMBA_VIRTUAL_ADDRESSES" ]; then
    output=$(haproxy -c -q -f /etc/haproxy/haproxy.cfg 2>&1) ||
      fail "haproxy rejects the generated haproxy.cfg:" "$output"
  fi
}

# The optional programs of supervisord, in one file that always exists
write_programs() {
  local level file=/etc/supervisor/conf.d/optional.conf
  mkdir -p /etc/supervisor/conf.d
  echo "; Optional programs, written by entrypoint.sh at every start" > "$file"

  # The SADM agent expects a name instead of Samba's number. Samba's default
  # (1) and the agent's default (info) both mean normal operation, so the
  # scale is shifted by one step compared to Samba's own names.
  if [ "$SADM_AGENT" == yes ]; then
    case "${SAMBA_LOG_LEVEL%% *}" in
      0) level=warn ;;
      1|2) level=info ;;
      10) level=trace ;;
      *) level=debug ;;
    esac
    {
      cat /opt/sadm-client/supervisor.conf
      echo "environment=LOG_LEVEL=\"$level\""
    } >> "$file"
  fi

  if [ -n "$SAMBA_VIRTUAL_ADDRESSES" ]; then
    cat "$TEMPLATES/vip-proxy.conf" >> "$file"
  fi

  # The API token goes to certbot alone, in a file only root can read;
  # Samba, BIND and the agent are started without it.
  rm -rf /run/letsencrypt
  if [ "$SAMBA_LETSENCRYPT" == yes ]; then
    local token=${CLOUDFLARE_DNS_API_TOKEN:-}
    if [ -n "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]; then
      token=$(tr -d '[:space:]' < "$CLOUDFLARE_DNS_API_TOKEN_FILE")
    fi
    mkdir -m 700 /run/letsencrypt
    (umask 077; echo "dns_cloudflare_api_token = $token" > /run/letsencrypt/cloudflare.ini)
    cat "$TEMPLATES/letsencrypt.conf" >> "$file"
  fi
  unset CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_DNS_API_TOKEN_FILE
}

start() {
  check_settings start
  if ! is_provisioned; then
    fail "This domain controller has not been set up yet." \
      "Run ./init.sh provision for a new domain, or ./init.sh join to add it" \
      "to an existing one; then docker compose up -d." "docs:installation/"
  fi
  local provisioned
  provisioned=$(provisioned_realm)
  if [ -n "$provisioned" ] && [ "$provisioned" != "$REALM" ]; then
    fail "SAMBA_REALM is $REALM, but this domain controller belongs to $provisioned." \
      "Correct SAMBA_REALM in .env, or set up the DC anew with ./init.sh."
  fi
  check_ports
  set_host_entry
  write_configs
  write_programs

  info "Starting the domain controller"
  versions | sed 's/^/  /'
  summary
  exec supervisord -c /etc/supervisor/supervisord.conf
}

# provision or join
initialize() {
  local action=$1 password options=()

  check_settings "$action"
  if is_provisioned; then
    fail "This domain controller is set up already." \
      "./init.sh deletes the volumes before it sets it up anew."
  fi
  check_ports
  if [ "$action" == join ]; then
    check_peer
  fi

  password=${ADMIN_PASSWORD:-}
  unset ADMIN_PASSWORD
  if [ -z "$password" ]; then
    read -r -s -p "Password of the domain administrator: " password
    echo
  fi

  set_host_entry
  # During the join, the domain is resolved through the peer
  if [ "$action" == join ]; then
    set_name_server "$SAMBA_PEER_SERVER"
  else
    set_name_server 127.0.0.1
  fi

  options=(--dns-backend=BIND9_DLZ
    "--option=interfaces=$SAMBA_INTERFACES" "--option=bind interfaces only=yes")
  if [ "$action" == provision ]; then
    options+=(--server-role=dc --use-rfc2307 "--realm=$REALM"
      "--domain=$SAMBA_WORKGROUP" "--host-name=${HOST_NAME,,}")
  else
    options+=("$DNS_DOMAIN" DC "--server=$SAMBA_PEER_SERVER" -UAdministrator)
  fi

  rm -f /etc/samba/smb.conf
  info "samba-tool domain $action ${options[*]}"
  if [ "$action" == provision ]; then
    samba-tool domain provision "${options[@]}" "--adminpass=$password"
  else
    # The password is passed in the environment, not on the command line
    PASSWD=$password samba-tool domain join "${options[@]}"
  fi
  # Kept for reference; the container writes its own smb.conf at every start
  mv /etc/samba/smb.conf /etc/samba/smb.conf.provisioned
  info "The domain controller is set up. Start it with: docker compose up -d"
}

command=${1:-start}
case "$command" in
  start)
    load_settings
    start
    ;;
  provision|join)
    load_settings
    initialize "$command"
    ;;
  check)
    load_settings
    check_settings "${2:-start}"
    if [ "${3:-}" == --ports ]; then
      check_ports
    fi
    if [ "${2:-start}" == join ]; then
      check_peer
    fi
    summary
    ;;
  version)
    versions
    ;;
  *)
    exec "$@"
    ;;
esac
