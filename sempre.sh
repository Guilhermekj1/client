#!/bin/sh
set -eu

CLIENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=$(command -v python3)
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/synctk.service"

if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "systemd user session is unavailable; cannot configure automatic startup." >&2
    exit 1
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=SyncTK folder synchronization client
After=network-online.target

[Service]
Type=simple
ExecStart=$PYTHON $CLIENT_DIR/client.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
if [ -n "${SYNCTK_TOKEN:-}" ]; then
    systemctl --user import-environment SYNCTK_TOKEN
fi
systemctl --user enable --now synctk.service
echo "SyncTK will start automatically at each login."
