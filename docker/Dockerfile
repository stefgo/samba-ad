# Debian release of the base image and of the backports Samba comes from
ARG DEBIAN_RELEASE=trixie
# Tag of the SADM agent copied into the image. sadm-client publishes no
# releases yet, so this follows its main branch.
ARG SADM_CLIENT_TAG=main

FROM ghcr.io/stefgo/sadm-client:${SADM_CLIENT_TAG} AS sadm-client

FROM debian:${DEBIAN_RELEASE}

ARG DEBIAN_RELEASE
ARG DEBIAN_FRONTEND=noninteractive
# Version and commit of this image, shown at start and by diagnose
ARG IMAGE_VERSION=local
ARG IMAGE_REVISION=

# Unpinned on purpose: every build takes the current Debian and Samba
# packages. Recommends stay, Samba and BIND rely on some of them.
# hadolint ignore=DL3008,DL3015
RUN echo "deb http://deb.debian.org/debian ${DEBIAN_RELEASE}-backports main" \
      > /etc/apt/sources.list.d/backports.list \
 && apt-get update \
 && apt-get upgrade -y \
    # supervisord, Kerberos, BIND, and the tools of the scripts (Jinja for
    # the templates of smb.conf and named.conf)
 && apt-get install -y supervisor krb5-config krb5-user bind9 bind9-dnsutils \
      netcat-traditional iproute2 python3-jinja2 \
    # Samba with its Python modules (the SADM agent and the scripts use them)
 && apt-get install -y -t "${DEBIAN_RELEASE}-backports" samba samba-ad-dc \
      samba-ad-provision samba-client winbind python3-samba \
    # Optional Let's Encrypt certificate; lego in Debian lacks Cloudflare
 && apt-get install -y certbot python3-certbot-dns-cloudflare openssl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

ENV SAMBA_AD_VERSION=${IMAGE_VERSION} \
    SAMBA_AD_REVISION=${IMAGE_REVISION} \
    SADM_CLIENT_CONFIG=/etc/sadm-client/config.yaml

VOLUME /etc/samba /var/lib/samba

# The SADM agent: its own Node runtime, the agent and a supervisord program.
# entrypoint.sh starts it only with SADM_AGENT=yes.
COPY --from=sadm-client /opt/sadm-client /opt/sadm-client

COPY templates/ supervisor/letsencrypt.conf /usr/local/share/samba-ad/
COPY supervisor/supervisord.conf /etc/supervisor/supervisord.conf
COPY --chmod=0755 lib/ /usr/local/lib/samba-ad/
COPY --chmod=0755 bin/ /usr/local/bin/

HEALTHCHECK --start-period=120s --start-interval=5s --interval=30s --timeout=10s --retries=3 \
  CMD ["healthcheck"]

# Documentation only: the container uses the network of the host
EXPOSE 53 53/udp 88 88/udp 135 137-138/udp 139 389 389/udp 445 464 464/udp 636 3268-3269 49152-65535

ENTRYPOINT ["entrypoint.sh"]
CMD ["start"]
