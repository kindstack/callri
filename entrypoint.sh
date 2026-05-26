#!/bin/sh
# Asterisk entrypoint
#  - Fixes ownership on bind-mounted volumes (Synology often mounts as 1026:100)
#  - Seeds /etc/asterisk with stock defaults if the mounted config is empty
#  - Sources .env, validates required values, renders config templates
#  - Then execs Asterisk in the foreground; -U/-G drops privileges to asterisk

set -e

# If /etc/asterisk is empty (first run with an unpopulated bind mount), seed it
if [ -z "$(ls -A /etc/asterisk 2>/dev/null)" ]; then
    echo "[entrypoint] /etc/asterisk empty -- seeding from /opt/asterisk-defaults"
    cp -a /opt/asterisk-defaults/. /etc/asterisk/
fi

# Same idea for the two phone-number whitelists -- the dialplan SHELL grep
# will silently no-op if the file is missing, but we'd prefer a real file.
for wl in outbound_whitelist.txt inbound_whitelist.txt; do
    if [ ! -f "/etc/asterisk/${wl}" ] && [ -f "/etc/asterisk/${wl}.example" ]; then
        echo "[entrypoint] ${wl} missing -- copying from .example"
        cp "/etc/asterisk/${wl}.example" "/etc/asterisk/${wl}"
    fi
done

# Render env-driven configs (pjsip_auth.conf, pjsip_env.conf,
# extensions_globals.conf) from their .template files using .env on the host.
# The renderer is shared with the `reload-env` helper so they stay in sync.
/usr/local/bin/render-env-configs

# Fix ownership so asterisk user can write logs/cdr/voicemail/astdb. Tighten
# perms on the rendered auth file (passwords).
chown -R asterisk:asterisk \
    /etc/asterisk \
    /var/lib/asterisk \
    /var/log/asterisk \
    /var/spool/asterisk \
    /var/run/asterisk 2>/dev/null || true
chmod 640 /etc/asterisk/pjsip_auth.conf 2>/dev/null || true

exec "$@"
