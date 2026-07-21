#!/bin/sh
# postremove — reload systemd after the unit file is gone. On a deb "purge",
# optionally remove leftover config/state. State data under /var/lib is left
# intact on a plain remove (and on rpm) so upgrades/reinstalls keep the DB.
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

# deb only: full purge removes local config. Data in /var/lib/arr_janitor and
# the system user are intentionally left behind even on purge to avoid data loss.
if [ "$1" = "purge" ]; then
    rm -f /etc/arr_janitor/config.yaml.example 2>/dev/null || true
    rmdir /etc/arr_janitor 2>/dev/null || true
fi

exit 0
