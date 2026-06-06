#!/bin/sh
# verify-nat -- sanity-check the NAT keepalive / pinhole setup at runtime.
#
# Usage (from the host):
#     docker exec asterisk verify-nat
#
# It answers the three questions that actually matter for "why do inbound
# calls drop for minutes after a router blip":
#
#   1. Did Asterisk accept keep_alive_interval? (the CRLF pinhole keepalive)
#   2. Is the outbound registration currently Registered, and how long until
#      it refreshes? (refresh = how fast Telnyx relearns a changed mapping)
#   3. Is the Telnyx trunk qualifying as Reachable/Available right now?
#
# Note: keep_alive_interval sends a bare 2-byte CRLF, NOT a SIP message, so it
# is invisible to `pjsip set logger on`. To literally watch it leave the box
# you need a packet capture (tcpdump is not in the image by default):
#     docker exec asterisk sh -c 'apt-get update >/dev/null 2>&1; \
#         apt-get install -y tcpdump >/dev/null 2>&1; \
#         tcpdump -ni any -A udp and host sip.telnyx.com -c 40'
# You should see your 30s OPTIONS interleaved with tiny ~2-byte frames ~15s
# apart -- those small frames are the CRLF keepalives.

set -e

ast() { asterisk -rx "$1"; }

echo "==> keep_alive_interval (CRLF pinhole keepalive, from [global])"
kai=$(ast 'pjsip show global' | awk -F':' '/keep_alive_interval/{gsub(/ /,"",$2);print $2}')
if [ -z "$kai" ] || [ "$kai" = "0" ]; then
    echo "    keep_alive_interval = ${kai:-<unset>}  *** NOT ACTIVE ***"
    echo "    Expected 15. Check [global] type=global in pjsip.conf and 'core reload'."
else
    echo "    keep_alive_interval = ${kai}s  (OK -- CRLF every ${kai}s)"
fi
echo

echo "==> Outbound registration (drives how fast Telnyx relearns our mapping)"
ast 'pjsip show registrations'
echo

echo "==> Telnyx trunk reachability (qualify health monitor)"
ast 'pjsip show aors'
echo
ast 'pjsip show contacts'
echo

echo "Reading the output:"
echo "  - Registration 'Registered' with a small 'Next refresh' = good; after a"
echo "    NAT change inbound recovers within ~one expiration (configured 120s)."
echo "  - A trunk contact shown as 'NonQual' or 'Unavail' means OPTIONS is not"
echo "    getting a reply -- the trunk is currently unreachable."
