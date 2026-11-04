#!/bin/sh
set -eu

START_MARKER="# >>> synctk autostart >>>"
END_MARKER="# <<< synctk autostart <<<"
for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc_file" ] || continue
    temporary=$(mktemp "${rc_file}.synctk.XXXXXX")
    awk -v start="$START_MARKER" -v end="$END_MARKER" '
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$rc_file" > "$temporary"
    cat "$temporary" > "$rc_file"
    rm -f "$temporary"
done

UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/synctk.service"
if [ -f "$UNIT_FILE" ] && command -v systemctl >/dev/null 2>&1 &&
    systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user disable --now synctk.service
fi

PID_FILE="$HOME/.synctk/client.pid"
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    case "$pid" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$pid" 2>/dev/null && [ -r "/proc/$pid/cmdline" ] &&
                tr '\000' ' ' < "/proc/$pid/cmdline" | grep -Fq "/client.py"; then
                kill "$pid"
            fi
            ;;
    esac
    rm -f "$PID_FILE"
fi

echo "SyncTK has been stopped and automatic startup disabled."
