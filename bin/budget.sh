#!/usr/bin/env bash
# Weekly token-budget tracker. Appends usage on each run; reports rolling 7-day sum.
# Usage:
#   budget.sh log <tokens>        # append usage entry
#   budget.sh check <cap-millions> # exit 0 if under cap, 1 if over

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$ROOT/state/budget.log"
mkdir -p "$ROOT/state"
touch "$LOG"

cmd="${1:-}"
case "$cmd" in
    log)
        tokens="${2:-0}"
        printf '%s\t%s\n' "$(date -u +%s)" "$tokens" >> "$LOG"
        ;;
    check)
        cap_m="${2:-40}"
        cap=$((cap_m * 1000000))
        cutoff=$(($(date -u +%s) - 7*86400))
        sum=$(awk -v c="$cutoff" '$1>=c {s+=$2} END{print s+0}' "$LOG")
        echo "Weekly tokens: $sum / cap $cap"
        if [ "$sum" -gt "$cap" ]; then
            exit 1
        fi
        ;;
    sum)
        cutoff=$(($(date -u +%s) - 7*86400))
        awk -v c="$cutoff" '$1>=c {s+=$2} END{print s+0}' "$LOG"
        ;;
    *)
        echo "usage: $0 {log <tokens>|check <cap-m>|sum}" >&2
        exit 2
        ;;
esac
