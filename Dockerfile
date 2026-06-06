# Asterisk 18 LTS on Ubuntu 22.04 (jammy) for x86_64 Synology NAS.
#
# Why Ubuntu 22.04 and not 24.04:
#   Ubuntu 24.04 ships glibc 2.39, whose arc4random implementation requires
#   the kernel's getrandom() syscall to be available. Synology DSM 6's
#   Docker seccomp profile blocks/filters that syscall, which causes
#   Asterisk to crash on startup with "Fatal glibc error: cannot get entropy
#   for arc4random". Ubuntu 22.04 (glibc 2.35) falls back to /dev/urandom,
#   so it boots fine on Synology DSM 6.
#
# Asterisk 18 is an LTS release maintained through Oct 2026 -- functionally
# equivalent to Asterisk 20 for our purposes (PJSIP, dial plan, codecs).

FROM ubuntu:22.04

ARG TZ=America/Chicago
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ}

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        asterisk \
        asterisk-modules \
        asterisk-config \
        asterisk-core-sounds-en \
        asterisk-core-sounds-en-g722 \
        asterisk-moh-opsound-g722 \
        ca-certificates \
        gettext-base \
        tzdata && \
    ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/*

# Stash the distro's stock configs so they survive a bind-mount that hides /etc/asterisk
RUN mkdir -p /opt/asterisk-defaults && \
    cp -a /etc/asterisk/. /opt/asterisk-defaults/ && \
    rm -rf /etc/asterisk/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY render-env-configs.sh /usr/local/bin/render-env-configs
COPY reload-env.sh /usr/local/bin/reload-env
COPY verify-nat.sh /usr/local/bin/verify-nat
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/render-env-configs \
             /usr/local/bin/reload-env \
             /usr/local/bin/verify-nat

# SIP signaling (UDP/TCP) + RTP media range (matches rtp.conf)
EXPOSE 5060/udp 5060/tcp 5061/tcp 10000-10100/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["asterisk", "-f", "-vvv", "-T", "-U", "asterisk", "-G", "asterisk"]
