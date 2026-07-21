#!/bin/sh
# preremove — best-effort stop/disable on real removal only.
# deb passes "remove"/"purge"/"upgrade" as $1; rpm passes a count ($1==0 on the
# final removal, >=1 during an upgrade). Only act on a genuine removal so an
# upgrade does not disable the service.
set -e

is_removal=0
case "$1" in
    remove|purge)
        is_removal=1
        ;;
    0)
        # rpm: last version being removed
        is_removal=1
        ;;
esac

if [ "${is_removal}" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet arr_janitor 2>/dev/null \
       || systemctl is-enabled --quiet arr_janitor 2>/dev/null; then
        systemctl disable --now arr_janitor >/dev/null 2>&1 || true
    fi
fi

exit 0
