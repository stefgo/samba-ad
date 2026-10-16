# Tag of the SADM agent that is copied into this image (see README.md)
ARG SADM_CLIENT_TAG=main

FROM ghcr.io/stefgo/sadm-client:${SADM_CLIENT_TAG} AS sadm-client

FROM debian:trixie

ARG DEBIAN_FRONTEND=noninteractive

# ADMIN_PASSWORD is only declared here, empty; the value comes from .env
# hadolint ignore=DL3064
ENV ACME_DOMAINS="" \
    ACME_EMAIL="" \
    ACME_KEY_TYPE=rsa2048 \
    ACME_PROPAGATION_SECONDS=30 \
    ACME_SERVER="" \
    ADMIN_PASSWORD="" \
    ALLOW_DNS_UPDATES=secure \
    BIND_HOST_IP=127.0.0.1 \
    BIND_INTERFACES_ONLY=yes \
    BIND_VIRTUAL_IPS="" \
    DNS_FORWARDER="" \
    DOMAIN_ACTION="" \
    DOMAIN_MASTER=no \
    INTERFACES="" \
    LETSENCRYPT=no \
    LOG_LEVEL=1 \
    MODEL=standard \
    NETBIOS_NAME="" \
    PEER_SERVER="" \
    REALM=home.lan \
    SADM_AGENT=no \
    SERVER_STRING="Domain Controller" \
    TZ="" \
    WINBIND_USE_DEFAULT_DOMAIN=yes \
    WORKGROUP=HOME

# Unpinned on purpose: every build takes the current Debian and Samba
# packages. Recommends stay, Samba and BIND rely on some of them.
# hadolint ignore=DL3008,DL3015
RUN echo "deb http://deb.debian.org/debian trixie-backports main" \
      > /etc/apt/sources.list.d/backports.list \
 && apt-get update \
 && apt-get upgrade -y \
    # Common tools, Kerberos, Bind, healthcheck tool
 && apt-get install -y apt-utils supervisor krb5-config krb5-user \
      bind9 bind9-dnsutils netcat-traditional \
    # Samba server
 && apt-get install -y -t trixie-backports samba samba-ad-dc \
      samba-ad-provision samba-client winbind \
    # Samba's Python modules; the SADM agent reads the local database with them
      python3-samba \
    # Optional Let's Encrypt certificate; lego in Debian lacks Cloudflare
 && apt-get install -y certbot python3-certbot-dns-cloudflare openssl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

VOLUME /var/lib/samba /etc/samba

# The SADM agent: its own Node runtime, the agent and a supervisord program.
# entrypoint.sh starts it only with SADM_AGENT=yes.
COPY --from=sadm-client /opt/sadm-client /opt/sadm-client

COPY *.j2 /root/
COPY supervisord.conf /etc
COPY letsencrypt.conf /etc/supervisor/
COPY --chmod=0755 entrypoint.sh letsencrypt.sh /usr/local/bin/

HEALTHCHECK --interval=5s --timeout=3s --retries=60 \
  CMD ["sh", "-c", "nc -z localhost 445 || exit 1"]

EXPOSE 53 53/udp 88 88/udp 135 137-138/udp 139 389 389/udp 445 464 464/udp 636 3268-3269 49152-65535

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
