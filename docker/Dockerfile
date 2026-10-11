FROM debian:trixie

ARG DEBIAN_FRONTEND=noninteractive

ENV ADMIN_PASSWORD="" \
    ALLOW_DNS_UPDATES=secure \
    BIND_HOST_IP=127.0.0.1 \
    DNS_FORWARDER="" \
    DOMAIN_ACTION="" \
    DOMAIN_MASTER=no \
    INTERFACES="" \
    LOG_LEVEL=1 \
    MODEL=standard \
    NETBIOS_NAME="" \
    PEER_SERVER="" \
    REALM=home.lan \
    SERVER_STRING="Domain Controller" \
    TZ="" \
    WINBIND_USE_DEFAULT_DOMAIN=yes \
    WORKGROUP=HOME

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
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

VOLUME /var/lib/samba /etc/samba

COPY *.j2 /root/
COPY supervisord.conf /etc
COPY --chmod=0755 entrypoint.sh /usr/local/bin/

HEALTHCHECK --interval=5s --timeout=3s --retries=60 CMD nc -z localhost 445 || exit 1

EXPOSE 53 53/udp 88 88/udp 135 137-138/udp 139 389 389/udp 445 464 464/udp 636 3268-3269 49152-65535

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
