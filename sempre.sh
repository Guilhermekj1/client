#!/bin/sh
set -eu

CLIENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=$(command -v python3)
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/synctk.service"
STATE_DIR="$HOME/.synctk"
PID_FILE="$STATE_DIR/client.pid"
LOG_FILE="$STATE_DIR/client.log"
START_LOCK="$STATE_DIR/start.lock"
START_MARKER="# >>> synctk autostart >>>"
END_MARKER="# <<< synctk autostart <<<"

start_client() {
    mkdir -p "$STATE_DIR"
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        case "$pid" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$pid" 2>/dev/null && [ -r "/proc/$pid/cmdline" ] &&
                    tr '\000' ' ' < "/proc/$pid/cmdline" | grep -Fq "$CLIENT_DIR/client.py"; then
                    return 0
                fi
                ;;
        esac
        rm -f "$PID_FILE"
    fi

    if ! mkdir "$START_LOCK" 2>/dev/null; then
        attempts=0
        while [ "$attempts" -lt 20 ] && [ -d "$START_LOCK" ]; do
            sleep 0.1
            attempts=$((attempts + 1))
        done
        if [ -f "$PID_FILE" ]; then
            pid=$(cat "$PID_FILE")
            case "$pid" in
                ''|*[!0-9]*) ;;
                *)
                    if kill -0 "$pid" 2>/dev/null && [ -r "/proc/$pid/cmdline" ] &&
                        tr '\000' ' ' < "/proc/$pid/cmdline" | grep -Fq "$CLIENT_DIR/client.py"; then
                        return 0
                    fi
                    ;;
            esac
        fi
        mkdir "$START_LOCK" 2>/dev/null || return 0
    fi
    trap 'rmdir "$START_LOCK" 2>/dev/null || true' EXIT HUP INT TERM

    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        case "$pid" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$pid" 2>/dev/null && [ -r "/proc/$pid/cmdline" ] &&
                    tr '\000' ' ' < "/proc/$pid/cmdline" | grep -Fq "$CLIENT_DIR/client.py"; then
                    return 0
                fi
                ;;
        esac
    fi

    nohup "$PYTHON" "$CLIENT_DIR/client.py" >> "$LOG_FILE" 2>&1 </dev/null &
    pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"
}

if [ "${1:-}" = "--start" ]; then
    start_client
    exit 0
fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
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
    exit 0
fi

quoted_script=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$CLIENT_DIR/sempre.sh")
for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc_file" ] || : > "$rc_file"
    temporary=$(mktemp "${rc_file}.synctk.XXXXXX")
    awk -v start="$START_MARKER" -v end="$END_MARKER" '
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$rc_file" > "$temporary"
    printf '\n%s\ncase $- in *i*) sh %s --start >/dev/null 2>&1 ;; esac\n%s\n' \
        "$START_MARKER" "$quoted_script" "$END_MARKER" >> "$temporary"
    cat "$temporary" > "$rc_file"
    rm -f "$temporary"
done

start_client
echo "Systemd user session unavailable; configured SyncTK to start in new Bash/Zsh sessions and started it now."
