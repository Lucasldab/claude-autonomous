#!/usr/bin/env bash
# Notification dispatcher. Sends to ntfy.sh (phone) and notify-send (desktop).
# Usage:
#   notify.sh <priority> <title> <body> [click-url]
# Priority: low | default | high | urgent
# Designed to be safe to call from any script — never blocks the caller, never errors out.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/limits.conf" 2>/dev/null || true

PRIORITY="${1:-default}"
TITLE="${2:-claude-autonomous}"
BODY="${3:-}"
URL="${4:-}"

# Map ntfy priority to notify-send urgency
case "$PRIORITY" in
    low)     NS_URG=low;      NTFY_PRI=2 ;;
    high)    NS_URG=normal;   NTFY_PRI=4 ;;
    urgent)  NS_URG=critical; NTFY_PRI=5 ;;
    *)       NS_URG=normal;   NTFY_PRI=3 ;;
esac

# Phone via ntfy.sh — runs in background, fail-silent
if [ -n "${NTFY_TOPIC:-}" ]; then
    {
        HEADERS=(
            -H "Title: $TITLE"
            -H "Priority: $NTFY_PRI"
            -H "Tags: robot"
        )
        [ -n "$URL" ] && HEADERS+=(-H "Click: $URL")
        curl -fsS --max-time 10 \
            "${HEADERS[@]}" \
            -d "$BODY" \
            "${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC" \
            >/dev/null 2>&1 &
    } 2>/dev/null
fi

# Desktop via notify-send — needs a user dbus session
if [ "${DESKTOP_NOTIFY:-0}" = "1" ] && command -v notify-send >/dev/null 2>&1; then
    # Locate an active dbus session (works when called from systemd --user)
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        DBUS_FILE="$XDG_RUNTIME_DIR/bus"
        [ -S "$DBUS_FILE" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$DBUS_FILE"
    fi
    notify-send -u "$NS_URG" -a "claude-autonomous" "$TITLE" "$BODY" 2>/dev/null || true
fi

# Always log
mkdir -p "$ROOT/logs"
printf '[%s] %s | %s | %s\n' "$(date -u +%FT%TZ)" "$PRIORITY" "$TITLE" "$BODY" >> "$ROOT/logs/notify.log"

exit 0
