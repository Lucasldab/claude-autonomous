#!/usr/bin/env bash
# Called as a Stop hook OR directly by runner. Commits WIP on a feature branch
# and writes a state file Claude can resume from.
#
# Stop hook input is JSON on stdin: {session_id, transcript_path, cwd, ...}
# Direct call: checkpoint.sh <project-dir> [reason]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT/state"
mkdir -p "$STATE_DIR"

# Detect invocation mode
if [ -t 0 ] || [ -n "${1:-}" ]; then
    PROJECT_DIR="${1:-$PWD}"
    REASON="${2:-manual-checkpoint}"
    SESSION_ID="manual-$(date +%s)"
    TRANSCRIPT=""
else
    INPUT=$(cat)
    SESSION_ID=$(jq -r '.session_id // empty' <<< "$INPUT" 2>/dev/null || echo "unknown")
    PROJECT_DIR=$(jq -r '.cwd // empty' <<< "$INPUT" 2>/dev/null || echo "$PWD")
    TRANSCRIPT=$(jq -r '.transcript_path // empty' <<< "$INPUT" 2>/dev/null || echo "")
    REASON="stop-hook"
fi

[ -z "$PROJECT_DIR" ] && PROJECT_DIR="$PWD"
cd "$PROJECT_DIR" || exit 0

PROJECT_NAME=$(basename "$PROJECT_DIR")
STATE_FILE="$STATE_DIR/${PROJECT_NAME}.md"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Estimate tokens from transcript size (rough: 4 bytes/token)
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    BYTES=$(stat -c%s "$TRANSCRIPT" 2>/dev/null || echo 0)
    TOKENS=$((BYTES / 4))
    "$ROOT/bin/budget.sh" log "$TOKENS" >/dev/null 2>&1 || true
fi

# Commit WIP if inside a git repo with changes
if git rev-parse --git-dir >/dev/null 2>&1; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
        # Refuse to commit on main during autonomous run — switch to wip branch
        WIP_BRANCH="autonomous/wip-$(date +%Y%m%d-%H%M)"
        git checkout -b "$WIP_BRANCH" 2>/dev/null || true
        BRANCH="$WIP_BRANCH"
    fi

    if [ -n "$(git status --porcelain)" ]; then
        git add -A
        git commit -q -m "wip: autonomous checkpoint ($REASON)

Session: $SESSION_ID
Branch: $BRANCH
Time: $TS" || true
    fi
fi

# Write resumable state file
cat > "$STATE_FILE" <<EOF
# Autonomous state — $PROJECT_NAME

- Last checkpoint: $TS
- Reason: $REASON
- Session ID: $SESSION_ID
- Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo n/a)
- HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo n/a)

## Resume notes

(Claude writes its own resume notes here via the auto-checkpoint skill before exiting.)
EOF

echo "checkpoint: $PROJECT_NAME @ $TS ($REASON)" >> "$ROOT/logs/checkpoint.log"
exit 0
