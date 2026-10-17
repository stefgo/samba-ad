# Shared by the commands of the image: settings with their defaults, the
# checks of the settings, and messages that say how to fix a problem.
# shellcheck shell=bash

DOCS_URL=https://stefgo.github.io/samba-ad
# shellcheck disable=SC2034 # used by entrypoint.sh
TEMPLATES=/usr/local/share/samba-ad

info() {
  echo "samba-ad: $*"
}

warn() {
  echo "samba-ad: WARNING: $*" >&2
}

# fail <message> [<hint>...]: prints the message and the hints and exits.
# A hint of the form "docs:<page>#<anchor>" becomes a link to the
# documentation.
fail() {
  echo "samba-ad: ERROR: $1" >&2
  shift
  local hint
  for hint in "$@"; do
    if [[ $hint == docs:* ]]; then
      echo "       See $DOCS_URL/${hint#docs:}" >&2
    else
      echo "       $hint" >&2
    fi
  done
  exit 1
}

is_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local octet
  for octet in "${BASH_REMATCH[@]:1}"; do
    [ "$octet" -le 255 ] || return 1
  done
}

# The IPv4 addresses of the host with their prefix length, one per line
host_addresses() {
  ip -o -4 addr show | awk '{print $4}'
}

# The entry address/prefix of one address of the host; fails if it has none
host_address_entry() {
  host_addresses | awk -F/ -v a="$1" '$1 == a {print; found = 1; exit} END {exit !found}'
}

# The settings of .env (see .env.example) with their defaults. Every default
# lives here and nowhere else.
load_settings() {
  : "${SAMBA_HOST_ADDRESS:=}"
  : "${SAMBA_REALM:=}"
  : "${SAMBA_PEER_SERVER:=}"
  : "${SAMBA_INTERFACES:=}"
  : "${SAMBA_BIND_INTERFACES_ONLY:=yes}"
  : "${SAMBA_VIRTUAL_ADDRESSES:=}"
  : "${SAMBA_DNS_FORWARDERS:=}"
  : "${SAMBA_DNS_ALLOW_RECURSION:=localhost localnets}"
  : "${SAMBA_LDAP_REQUIRE_STRONG_AUTH:=no}"
  : "${SAMBA_LOG_LEVEL:=1}"
  : "${SAMBA_LETSENCRYPT:=no}"
  : "${ACME_DOMAINS:=}"
  : "${ACME_EMAIL:=}"
  : "${ACME_SERVER:=}"
  : "${ACME_KEY_TYPE:=rsa2048}"
  : "${ACME_PROPAGATION_SECONDS:=30}"
  : "${SADM_AGENT:=no}"
  : "${TZ:=UTC}"

  # The DNS domain in lower case, the Kerberos realm in upper case
  DNS_DOMAIN=${SAMBA_REALM,,}
  REALM=${SAMBA_REALM^^}
  # Like samba-tool: the first label of the realm
  : "${SAMBA_WORKGROUP:=${REALM%%.*}}"
  SAMBA_WORKGROUP=${SAMBA_WORKGROUP^^}
  # The host name of the Docker host is the name of the domain controller
  HOST_NAME=$(hostname -s)
  NETBIOS_NAME=${HOST_NAME^^}
  FQDN=${HOST_NAME,,}.$DNS_DOMAIN

  if [ -z "$SAMBA_INTERFACES" ] && [ -n "$SAMBA_HOST_ADDRESS" ]; then
    local entry
    if entry=$(host_address_entry "$SAMBA_HOST_ADDRESS"); then
      SAMBA_INTERFACES="127.0.0.1/8 $entry"
    fi
  fi

  export SAMBA_HOST_ADDRESS SAMBA_REALM SAMBA_PEER_SERVER SAMBA_INTERFACES \
    SAMBA_BIND_INTERFACES_ONLY SAMBA_VIRTUAL_ADDRESSES SAMBA_DNS_FORWARDERS \
    SAMBA_DNS_ALLOW_RECURSION SAMBA_LDAP_REQUIRE_STRONG_AUTH SAMBA_LOG_LEVEL \
    SAMBA_LETSENCRYPT ACME_DOMAINS ACME_EMAIL ACME_SERVER ACME_KEY_TYPE \
    ACME_PROPAGATION_SECONDS SADM_AGENT TZ SAMBA_WORKGROUP DNS_DOMAIN REALM \
    HOST_NAME NETBIOS_NAME FQDN
}

check_yes_no() {
  case "${!1}" in
    yes|no) ;;
    *) fail "$1 must be yes or no, not '${!1}'." "docs:configuration/" ;;
  esac
}

# Checks the settings; $1 is start, provision or join
check_settings() {
  local mode=$1 entry vip

  [ -n "$SAMBA_HOST_ADDRESS" ] ||
    fail "SAMBA_HOST_ADDRESS is not set." "Set it in .env to the fixed IPv4 address of this host." \
      "docs:configuration/"
  [ -n "$SAMBA_REALM" ] ||
    fail "SAMBA_REALM is not set." "Set it in .env to the DNS name of the domain, e.g. EXAMPLE.LAN." \
      "docs:configuration/"

  is_ipv4 "$SAMBA_HOST_ADDRESS" ||
    fail "SAMBA_HOST_ADDRESS '$SAMBA_HOST_ADDRESS' is not an IPv4 address."
  host_address_entry "$SAMBA_HOST_ADDRESS" >/dev/null ||
    fail "SAMBA_HOST_ADDRESS $SAMBA_HOST_ADDRESS is not an address of this host." \
      "The host has: $(host_addresses | tr '\n' ' ')" \
      "Use the fixed address of the host; a virtual address belongs in SAMBA_VIRTUAL_ADDRESSES." \
      "docs:troubleshooting/#address-is-not-an-address-of-this-host"

  [[ $DNS_DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] ||
    fail "SAMBA_REALM '$SAMBA_REALM' is not a DNS name with at least two parts, e.g. EXAMPLE.LAN."
  [[ $SAMBA_WORKGROUP =~ ^[A-Z0-9][A-Z0-9_-]{0,14}$ ]] ||
    fail "The NetBIOS domain name '$SAMBA_WORKGROUP' is invalid." \
      "It has at most 15 letters, digits, '-' or '_'. Set SAMBA_WORKGROUP in .env;" \
      "without it, the first part of SAMBA_REALM is used." "docs:configuration/"
  [[ $NETBIOS_NAME =~ ^[A-Z0-9][A-Z0-9-]{0,14}$ ]] ||
    fail "The host name '$HOST_NAME' cannot be the name of a domain controller." \
      "It has at most 15 letters, digits or '-'. Rename the host." \
      "docs:troubleshooting/#host-name-is-not-suitable"
  [ "$NETBIOS_NAME" != "$SAMBA_WORKGROUP" ] ||
    fail "The host name '$HOST_NAME' equals the NetBIOS domain name '$SAMBA_WORKGROUP'." \
      "Rename the host or set another SAMBA_WORKGROUP." \
      "docs:troubleshooting/#host-name-is-not-suitable"

  [ -n "$SAMBA_INTERFACES" ] ||
    fail "SAMBA_INTERFACES could not be derived from SAMBA_HOST_ADDRESS; set it in .env."
  # Samba registers every address of SAMBA_INTERFACES in DNS as address of
  # this DC; an interface name would include a virtual address while this
  # host holds it.
  for entry in $SAMBA_INTERFACES; do
    if [[ ! $entry =~ ^[0-9.]+/[0-9]{1,2}$ ]] || ! is_ipv4 "${entry%/*}"; then
      fail "SAMBA_INTERFACES entry '$entry' is not of the form address/prefix." \
        "List the fixed addresses of the host, e.g. 127.0.0.1/8 $SAMBA_HOST_ADDRESS/24;" \
        "no interface names." "docs:configuration/"
    fi
    [ "${entry%/*}" == 127.0.0.1 ] || host_address_entry "${entry%/*}" >/dev/null ||
      fail "SAMBA_INTERFACES lists ${entry%/*}, which is not an address of this host." \
        "The host has: $(host_addresses | tr '\n' ' ')"
  done
  [[ " $SAMBA_INTERFACES " == *" $SAMBA_HOST_ADDRESS/"* ]] ||
    fail "SAMBA_INTERFACES must contain SAMBA_HOST_ADDRESS ($SAMBA_HOST_ADDRESS)." \
      "Leave SAMBA_INTERFACES empty to derive it."

  check_yes_no SAMBA_BIND_INTERFACES_ONLY
  check_yes_no SAMBA_LETSENCRYPT
  check_yes_no SADM_AGENT

  case "$SAMBA_LDAP_REQUIRE_STRONG_AUTH" in
    yes|no|allow_sasl_without_tls_channel_bindings) ;;
    *) fail "SAMBA_LDAP_REQUIRE_STRONG_AUTH must be yes, no or" \
         "allow_sasl_without_tls_channel_bindings, not '$SAMBA_LDAP_REQUIRE_STRONG_AUTH'." ;;
  esac
  # A number, optionally followed by debug classes such as "auth:3"
  [[ $SAMBA_LOG_LEVEL =~ ^[0-9]{1,2}(\ +[a-z_]+:[0-9]{1,2})*$ ]] ||
    fail "SAMBA_LOG_LEVEL '$SAMBA_LOG_LEVEL' is invalid." \
      "Use a number from 0 to 10, optionally followed by classes, e.g. '1 auth:3'."
  [ -f "/usr/share/zoneinfo/$TZ" ] ||
    fail "TZ '$TZ' is not a known time zone, e.g. Europe/Berlin."

  for entry in $SAMBA_DNS_FORWARDERS; do
    is_ipv4 "$entry" ||
      fail "SAMBA_DNS_FORWARDERS entry '$entry' is not an IPv4 address."
  done
  for entry in $SAMBA_DNS_ALLOW_RECURSION; do
    [[ $entry =~ ^(any|none|localhost|localnets|[0-9.]+(/[0-9]{1,2})?)$ ]] ||
      fail "SAMBA_DNS_ALLOW_RECURSION entry '$entry' is invalid." \
        "Use any, none, localhost, localnets, addresses or networks such as 10.0.0.0/8."
  done

  if [ "$mode" == join ]; then
    [ -n "$SAMBA_PEER_SERVER" ] ||
      fail "SAMBA_PEER_SERVER is not set." \
        "A join needs the fixed address of an existing domain controller in .env."
  fi
  if [ -n "$SAMBA_PEER_SERVER" ]; then
    is_ipv4 "$SAMBA_PEER_SERVER" ||
      fail "SAMBA_PEER_SERVER '$SAMBA_PEER_SERVER' is not an IPv4 address."
  fi

  # A virtual address moves between the DCs. It must not be registered in
  # DNS as address of one of them, nor be used to reach another DC.
  for vip in $SAMBA_VIRTUAL_ADDRESSES; do
    is_ipv4 "$vip" ||
      fail "SAMBA_VIRTUAL_ADDRESSES entry '$vip' is not an IPv4 address without prefix."
    [ "$vip" != "$SAMBA_HOST_ADDRESS" ] ||
      fail "SAMBA_HOST_ADDRESS must be the fixed address of the host, not the virtual address $vip." \
        "docs:virtual-address/"
    [ "$vip" != "$SAMBA_PEER_SERVER" ] ||
      fail "SAMBA_PEER_SERVER must be the fixed address of the peer, not the virtual address $vip." \
        "docs:virtual-address/"
    for entry in $SAMBA_DNS_FORWARDERS; do
      [ "$vip" != "$entry" ] ||
        fail "The virtual address $vip must not be a DNS forwarder; BIND would ask itself." \
          "docs:virtual-address/"
    done
    for entry in $SAMBA_INTERFACES; do
      [ "$vip" != "${entry%/*}" ] ||
        fail "The virtual address $vip must not be listed in SAMBA_INTERFACES." \
          "Samba would register it in DNS as address of this DC." "docs:virtual-address/"
    done
  done

  check_tls_settings
}

check_tls_settings() {
  if { [ -f /tls/cert.pem ] && [ ! -f /tls/key.pem ]; } ||
      { [ ! -f /tls/cert.pem ] && [ -f /tls/key.pem ]; }; then
    fail "An own certificate needs both tls/cert.pem and tls/key.pem." "docs:tls/#own-certificate"
  fi
  [ "$SAMBA_LETSENCRYPT" == yes ] || return 0

  # The certificate is served by haproxy on the virtual addresses; Samba
  # keeps its own and must leave 389 and 636 there to haproxy
  [ -n "$SAMBA_VIRTUAL_ADDRESSES" ] ||
    fail "SAMBA_LETSENCRYPT=yes needs SAMBA_VIRTUAL_ADDRESSES." \
      "The Let's Encrypt certificate is served on the virtual addresses only." \
      "docs:tls/#lets-encrypt"
  [ "$SAMBA_BIND_INTERFACES_ONLY" == yes ] ||
    fail "SAMBA_LETSENCRYPT=yes needs SAMBA_BIND_INTERFACES_ONLY=yes." \
      "haproxy serves LDAP on the virtual addresses; Samba listening on every" \
      "address would take the ports from it." "docs:virtual-address/#central-ldap-names"
  [ -n "$ACME_DOMAINS" ] ||
    fail "ACME_DOMAINS is required with SAMBA_LETSENCRYPT=yes." \
      "List the names under which applications reach LDAP on the virtual address." \
      "docs:tls/#lets-encrypt"
  local name
  for name in $ACME_DOMAINS; do
    [[ $name =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] ||
      fail "ACME_DOMAINS entry '$name' is not a DNS name."
  done
  [ -n "$ACME_EMAIL" ] ||
    fail "ACME_EMAIL is required with SAMBA_LETSENCRYPT=yes." "docs:tls/#lets-encrypt"
  case "$ACME_KEY_TYPE" in
    rsa2048|ec256) ;;
    *) fail "ACME_KEY_TYPE must be rsa2048 or ec256, not '$ACME_KEY_TYPE'." ;;
  esac
  [[ $ACME_PROPAGATION_SECONDS =~ ^[0-9]+$ ]] ||
    fail "ACME_PROPAGATION_SECONDS must be a number of seconds."
  if [ -n "${CLOUDFLARE_DNS_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]; then
    fail "Set CLOUDFLARE_DNS_API_TOKEN or CLOUDFLARE_DNS_API_TOKEN_FILE in acme.env, not both."
  fi
  if [ -n "${CLOUDFLARE_DNS_API_TOKEN_FILE:-}" ]; then
    [ -r "$CLOUDFLARE_DNS_API_TOKEN_FILE" ] ||
      fail "CLOUDFLARE_DNS_API_TOKEN_FILE cannot be read: $CLOUDFLARE_DNS_API_TOKEN_FILE"
  elif [ -z "${CLOUDFLARE_DNS_API_TOKEN:-}" ]; then
    fail "Let's Encrypt needs the Cloudflare API token." \
      "Create acme.env next to compose.yaml: cp acme.env.example acme.env" "docs:tls/#lets-encrypt"
  fi
}

# Fails if another program listens on a port this DC needs: 53 (BIND) on the
# addresses BIND uses, 88, 389 and 445 (Samba) on Samba's addresses, and with
# Let's Encrypt 389 and 636 (haproxy) on the virtual addresses
check_ports() {
  local samba_addresses=() bind_addresses=(127.0.0.1 "$SAMBA_HOST_ADDRESS")
  local proxy_addresses=() entry port local_address address wanted
  # shellcheck disable=SC2206
  bind_addresses+=($SAMBA_VIRTUAL_ADDRESSES)
  if [ "$SAMBA_BIND_INTERFACES_ONLY" == yes ]; then
    for entry in $SAMBA_INTERFACES; do
      samba_addresses+=("${entry%/*}")
    done
  else
    samba_addresses=(any)
  fi
  if [ "$SAMBA_LETSENCRYPT" == yes ]; then
    # shellcheck disable=SC2206
    proxy_addresses=($SAMBA_VIRTUAL_ADDRESSES)
  fi

  for port in 53 88 389 445 636; do
    case $port in
      53) wanted=" ${bind_addresses[*]} " ;;
      389) wanted=" ${samba_addresses[*]} ${proxy_addresses[*]} " ;;
      # Samba's own 636 follows 389; only haproxy's is checked
      636) wanted=" ${proxy_addresses[*]} " ;;
      *) wanted=" ${samba_addresses[*]} " ;;
    esac
    [ -n "${wanted// /}" ] || continue
    while read -r local_address; do
      address=${local_address%:*}
      address=${address%%%*}
      address=${address#[}
      address=${address%]}
      if [[ $address == @(0.0.0.0|::|\*) || $wanted == *" any "* || $wanted == *" $address "* ]]; then
        fail "Port $port is already in use on this host ($local_address)." \
          "Another program listens there, e.g. a DNS server, or a second container" \
          "of this DC. Find it on the host with: sudo ss -ltnup 'sport = :$port'" \
          "docs:troubleshooting/#port-is-already-in-use"
      fi
    done < <(ss -Hltn "sport = :$port" | awk '{print $4}')
  done
}

# Samba's DLZ module for the installed BIND: the one of its version, else the
# newest one (Samba builds no module for every BIND version)
dlz_module() {
  local version modules
  version=$(named -v | sed -nE 's/^BIND ([0-9]+)\.([0-9]+).*/\1_\2/p')
  modules=$(printf '%s\n' /usr/lib/*-linux-gnu/samba/bind9/dlz_bind*.so | sort -V)
  [ -f "${modules%%$'\n'*}" ] ||
    fail "Samba's DLZ modules for BIND are missing in this image." \
      "Report this at https://github.com/stefgo/samba-ad/issues"
  grep "/dlz_bind${version}\.so$" <<< "$modules" || tail -n 1 <<< "$modules"
}

versions() {
  echo "Image   samba-ad ${SAMBA_AD_VERSION:-unknown}${SAMBA_AD_REVISION:+ (${SAMBA_AD_REVISION:0:7})}"
  echo "Samba   $(samba -V | sed 's/^Version //')"
  echo "BIND    $(named -v | awk '{print $2}')"
  echo "certbot $(certbot --version 2>&1 | awk '{print $2}')"
  echo "haproxy $(haproxy -v 2>/dev/null | awk 'NR == 1 {print $3}')"
  echo "SADM    $(/opt/sadm-client/bin/sadm-client --version 2>/dev/null || echo unknown)"
}

# The effective settings, shown at start and by init.sh before it changes
# anything
summary() {
  local tls vip_tls=none listen recursion
  if [ -f /tls/cert.pem ]; then
    tls="own certificate from tls/cert.pem"
  else
    tls="self-signed, generated by Samba"
  fi
  if [ "$SAMBA_LETSENCRYPT" == yes ]; then
    vip_tls="Let's Encrypt for $ACME_DOMAINS (haproxy)"
  fi
  if [ "$SAMBA_BIND_INTERFACES_ONLY" == yes ]; then
    listen=$SAMBA_INTERFACES
  else
    listen="every address of the host"
  fi
  recursion=$SAMBA_DNS_ALLOW_RECURSION
  if [ -n "$SAMBA_DNS_FORWARDERS" ]; then
    recursion+=", via $SAMBA_DNS_FORWARDERS"
  fi
  cat <<EOF
  Domain controller  $NETBIOS_NAME ($FQDN)
  Domain             $REALM (NetBIOS: $SAMBA_WORKGROUP)
  Address            $SAMBA_HOST_ADDRESS
  Virtual addresses  ${SAMBA_VIRTUAL_ADDRESSES:-none}
  Samba listens on   $listen
  DNS recursion for  $recursion
  LDAP without TLS   $([ "$SAMBA_LDAP_REQUIRE_STRONG_AUTH" == no ] && echo "simple bind allowed" || echo "simple bind refused")
  Samba certificate  $tls
  VIP certificate    $vip_tls
  SADM agent         $SADM_AGENT
  Time zone          $TZ
EOF
}

# The container's /etc/hosts and /etc/resolv.conf are files of Docker that
# may be rewritten, not replaced: the name of this DC must resolve to its
# address, not to 127.0.1.1 as Debian hosts often list it.
set_host_entry() {
  local hosts
  hosts=$(awk -v h="${HOST_NAME,,}" -v f="$FQDN" '
    { for (i = 2; i <= NF; i++) if (tolower($i) == h || tolower($i) == f) next; print }
  ' /etc/hosts)
  printf '%s\n%s %s %s\n' "$hosts" "$SAMBA_HOST_ADDRESS" "$FQDN" "${HOST_NAME,,}" > /etc/hosts
}

set_name_server() {
  printf 'search %s\nnameserver %s\n' "$DNS_DOMAIN" "$1" > /etc/resolv.conf
}

is_provisioned() {
  [ -f /var/lib/samba/private/sam.ldb ]
}

# The realm this DC was provisioned for
provisioned_realm() {
  sed -nE 's/^[[:space:]]*default_realm[[:space:]]*=[[:space:]]*//p' \
    /var/lib/samba/private/krb5.conf 2>/dev/null | head -n 1
}

# Asks the rootDSE of a DC, which answers without credentials. Prints
# "<naming context> <seconds the local clock is ahead>".
query_peer() {
  python3 - "$1" <<'EOF'
import sys
from datetime import datetime, timezone

import ldb
from samba.param import LoadParm
from samba.samdb import SamDB

try:
    db = SamDB(url="ldap://" + sys.argv[1], lp=LoadParm())
    msg = db.search(base="", scope=ldb.SCOPE_BASE,
                    attrs=["defaultNamingContext", "currentTime"])[0]
except Exception as e:
    print(e, file=sys.stderr)
    sys.exit(1)
remote = datetime.strptime(str(msg["currentTime"][0]), "%Y%m%d%H%M%S.0Z")
offset = datetime.now(timezone.utc).replace(tzinfo=None) - remote
print(str(msg["defaultNamingContext"][0]), int(offset.total_seconds()))
EOF
}

# The naming context of a DNS domain, e.g. DC=example,DC=lan
naming_context() {
  echo "DC=${1//./,DC=}"
}

check_peer() {
  local result context offset
  result=$(query_peer "$SAMBA_PEER_SERVER" 2>&1) ||
    fail "The domain controller $SAMBA_PEER_SERVER (SAMBA_PEER_SERVER) does not answer on LDAP." \
      "$result" "Is the address right, is it running, and is port 389 reachable from here?" \
      "docs:troubleshooting/#join-fails"
  read -r context offset <<< "$result"
  [ "${context,,}" == "$(naming_context "$DNS_DOMAIN" | tr '[:upper:]' '[:lower:]')" ] ||
    fail "$SAMBA_PEER_SERVER is a domain controller of $context, not of $REALM." \
      "Check SAMBA_REALM and SAMBA_PEER_SERVER."
  offset=${offset#-}
  [ "$offset" -lt 300 ] ||
    fail "The clock of this host differs by $offset seconds from $SAMBA_PEER_SERVER." \
      "Kerberos allows five minutes. Synchronize the time of both hosts (e.g. chrony)." \
      "docs:troubleshooting/#clocks-differ"
  if [ "$offset" -ge 60 ]; then
    warn "The clock of this host differs by $offset seconds from $SAMBA_PEER_SERVER."
  fi
}
