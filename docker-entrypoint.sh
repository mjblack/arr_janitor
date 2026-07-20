#!/bin/sh
# ArrJanitor container entrypoint.
#
# Runs as root only to make the (possibly root-owned) bind-mounted /data volume
# writable by the app's user, then drops privileges via gosu and execs the app.
#
# PUID/PGID default to 1000:1000 (the typical host user); override them to match
# your host user so the DB files are owned by you and the ./data bind mount stays
# writable. /config is normally mounted read-only and is left untouched.
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

mkdir -p /data
# Fix ownership of the data volume (e.g. a root-owned ./data created by the
# docker daemon on first `docker compose up`). Tolerate failure so a read-only or
# already-correct mount doesn't abort startup.
chown -R "${PUID}:${PGID}" /data 2>/dev/null || true

# Drop from root to PUID:PGID and run arr_janitor with the CMD arguments.
exec gosu "${PUID}:${PGID}" arr_janitor "$@"
