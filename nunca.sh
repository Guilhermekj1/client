#!/bin/sh
set -eu

if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "systemd user session is unavailable; cannot disable automatic startup." >&2
    exit 1
fi

systemctl --user disable --now synctk.service
echo "SyncTK automatic startup is disabled."
