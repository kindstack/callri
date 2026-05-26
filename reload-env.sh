#!/bin/sh
# reload-env -- pick up changes to .env without restarting the container.
#
# Usage (from the host):
#     docker exec asterisk reload-env
#
# What it does:
#   1. Re-renders pjsip_auth.conf, pjsip_env.conf, extensions_globals.conf
#      from the live .env (bind-mounted into the container).
#   2. Asks Asterisk to gracefully reload its config (active calls survive).
#
# Why this works without --force-recreate: .env is bind-mounted at
# /etc/asterisk/.env so the container always sees the host's current
# values. Re-rendering + `core reload` is all that's needed.

set -e

/usr/local/bin/render-env-configs

# `core reload` re-reads every module's config from disk. Cheaper alternatives
# exist (`module reload res_pjsip.so` + `dialplan reload`) but `core reload`
# is safe, simple, and graceful (active calls are not torn down).
asterisk -rx 'core reload'

echo "[reload-env] rendered and reloaded -- changes are live"
