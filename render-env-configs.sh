#!/bin/sh
# render-env-configs -- shared renderer used by entrypoint.sh (at boot) and
# reload-env (for hot-reload). Reads /etc/asterisk/.env (bind-mounted from
# the host's .env), validates the required values, and renders the three
# .template files in /etc/asterisk/ into their final .conf names.
#
# The envsubst whitelist restricts substitution to exactly the .env vars
# we expect, so any stray ${VAR} in a template that happens to match an
# Asterisk dialplan variable name doesn't get clobbered.

set -e

ENV_FILE=/etc/asterisk/.env

# .env must be a regular file. Docker bind-mounts auto-create an empty
# DIRECTORY at the mount point if the host file is missing -- catch that
# and emit a clear message.
if [ ! -f "${ENV_FILE}" ]; then
    cat >&2 <<EOF
[render-env-configs] FATAL: ${ENV_FILE} is missing or not a regular file.

  On the host (next to docker-compose.yml):
      cp .env.example .env
      vi .env                      # fill in real values
      docker compose up -d --force-recreate

  (If docker auto-created an empty directory at .env from a prior failed
  start, remove it first:  rm -rf .env  then re-create from .env.example.)
EOF
    exit 1
fi

# Load values. `set -a` exports each assignment so envsubst inherits them.
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

# Fail fast if any required value is empty or unset.
: "${TELNYX_USERNAME:?required value missing in .env}"
: "${TELNYX_PASSWORD:?required value missing in .env}"
: "${TELNYX_DID:?required value missing in .env}"
: "${PUBLIC_ADDRESS:?required value missing in .env}"
: "${EXT_100_PASSWORD:?required value missing in .env}"
: "${EXT_101_PASSWORD:?required value missing in .env}"

VAR_WHITELIST='${TELNYX_USERNAME} ${TELNYX_PASSWORD} ${TELNYX_DID} ${PUBLIC_ADDRESS} ${EXT_100_PASSWORD} ${EXT_101_PASSWORD}'

for tmpl in pjsip_auth.conf pjsip_env.conf extensions_globals.conf; do
    src="/etc/asterisk/${tmpl}.template"
    dst="/etc/asterisk/${tmpl}"
    if [ ! -f "${src}" ]; then
        echo "[render-env-configs] WARNING: ${src} missing -- skipping ${tmpl}" >&2
        continue
    fi
    envsubst "${VAR_WHITELIST}" < "${src}" > "${dst}"
    echo "[render-env-configs] rendered ${dst}"
done

# Tighten perms on the rendered auth file (it holds passwords).
chmod 640 /etc/asterisk/pjsip_auth.conf 2>/dev/null || true
