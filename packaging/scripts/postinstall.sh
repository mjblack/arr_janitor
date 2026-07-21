#!/bin/sh
# postinstall — runs on both deb (configure) and rpm (install/upgrade).
# Creates the dedicated system user/group, ensures the managed directories
# exist with the right ownership, and registers the systemd unit. It does NOT
# enable or start the service: the operator must edit the config first.
set -e

USER_NAME=arr_janitor
GROUP_NAME=arr_janitor
STATE_DIR=/var/lib/arr_janitor
CONF_DIR=/etc/arr_janitor

# --- system group + user (idempotent) ---------------------------------------
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

# --- managed directories (idempotent) ---------------------------------------
if [ ! -d "${CONF_DIR}" ]; then
    mkdir -p "${CONF_DIR}" || true
fi
chown root:"${GROUP_NAME}" "${CONF_DIR}" 2>/dev/null || true
chmod 0750 "${CONF_DIR}" 2>/dev/null || true

if [ ! -d "${STATE_DIR}" ]; then
    mkdir -p "${STATE_DIR}" || true
fi
chown "${USER_NAME}":"${GROUP_NAME}" "${STATE_DIR}" 2>/dev/null || true
chmod 0750 "${STATE_DIR}" 2>/dev/null || true

# --- register the unit (do not enable/start) --------------------------------
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

cat <<'EOF'

arr_janitor is installed but NOT enabled.

Next steps:
  1. Copy the example config and edit it:
       cp /etc/arr_janitor/config.yaml.example /etc/arr_janitor/config.yaml
       $EDITOR /etc/arr_janitor/config.yaml
  2. Enable and start the service:
       systemctl enable --now arr_janitor

EOF

exit 0
