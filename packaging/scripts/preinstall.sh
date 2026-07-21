#!/bin/sh
# preinstall — create the dedicated system group/user BEFORE files are laid
# down, so the packaged directories owned by arr_janitor:arr_janitor can have
# their ownership applied cleanly at unpack time. Idempotent.
set -e

USER_NAME=arr_janitor
GROUP_NAME=arr_janitor
STATE_DIR=/var/lib/arr_janitor

if ! getent group "${GROUP_NAME}" >/dev/null 2>&1; then
    groupadd --system "${GROUP_NAME}" || true
fi

if ! getent passwd "${USER_NAME}" >/dev/null 2>&1; then
    if [ -x /usr/sbin/nologin ]; then
        NOLOGIN=/usr/sbin/nologin
    elif [ -x /sbin/nologin ]; then
        NOLOGIN=/sbin/nologin
    else
        NOLOGIN=/bin/false
    fi
    useradd --system --gid "${GROUP_NAME}" \
        --home-dir "${STATE_DIR}" \
        --shell "${NOLOGIN}" \
        "${USER_NAME}" || true
fi

exit 0
