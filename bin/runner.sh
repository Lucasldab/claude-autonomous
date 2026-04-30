#!/usr/bin/env bash
# Autonomous runner. Picks the next queued task and runs claude headless on it.
# Designed to be invoked by systemd timer.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE="$ROOT/tasks/queue.txt"
DONE="$ROOT/tasks/done.log"
FAILED="$ROOT/tasks/failed.log"
LOCK="$ROOT/state/runner.lock"
LOG_DIR="$ROOT/logs"

mkdir -p "$ROOT/tasks" "$ROOT/state" "$LOG_DIR"
touch "$DONE" "$FAILED"

# shellcheck disable=SC1091
source "$ROOT/config/limits.conf"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG_DIR/runner.log"; }

# Single-instance lock
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another runner is active — exiting"
    exit 0
fi

# Away-hours gate (skip if FORCE=1)
if [ "${FORCE:-0}" != "1" ] && [ "$AWAY_HOUR_START" != "$AWAY_HOUR_END" ]; then
    H=$(date +%H | sed 's/^0//')
    if [ "$AWAY_HOUR_START" -lt "$AWAY_HOUR_END" ]; then
        in_window=$([ "$H" -ge "$AWAY_HOUR_START" ] && [ "$H" -lt "$AWAY_HOUR_END" ] && echo 1 || echo 0)
    else
        in_window=$([ "$H" -ge "$AWAY_HOUR_START" ] || [ "$H" -lt "$AWAY_HOUR_END" ] && echo 1 || echo 0)
    fi
    if [ "$in_window" != "1" ]; then
        log "outside away-hours window ($AWAY_HOUR_START–$AWAY_HOUR_END) — skipping"
        exit 0
    fi
fi

# Weekly budget gate
if ! "$ROOT/bin/budget.sh" check "$WEEKLY_TOKEN_CAP_M" >/dev/null; then
    log "weekly token cap reached — skipping"
    exit 0
fi

# Pick next task (first non-comment, non-blank line)
TASK_LINE=$(grep -nv '^\s*\(#\|$\)' "$QUEUE" | head -1 || true)
if [ -z "$TASK_LINE" ]; then
    log "queue empty"
    exit 0
fi

LINE_NO="${TASK_LINE%%:*}"
TASK="${TASK_LINE#*:}"
PROJECT_PART="${TASK%%|*}"
PROMPT_PART="${TASK#*|}"

# Resolve project dir
case "$PROJECT_PART" in
    /*) PROJECT_DIR="$PROJECT_PART" ;;
    *)  PROJECT_DIR="/home/projects/$PROJECT_PART" ;;
esac

if [ ! -d "$PROJECT_DIR" ]; then
    log "project missing: $PROJECT_DIR — moving to failed"
    printf '%s\t%s\tproject-missing\n' "$(date -u +%FT%TZ)" "$TASK" >> "$FAILED"
    sed -i "${LINE_NO}d" "$QUEUE"
    exit 1
fi

PROJECT_NAME=$(basename "$PROJECT_DIR")
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$PROJECT_NAME"
RUN_LOG="$LOG_DIR/$RUN_ID.log"

log "starting: $PROJECT_NAME — $PROMPT_PART"
log "log: $RUN_LOG"

cd "$PROJECT_DIR"

# Force feature branch if policy demands
if [ "$BRANCH_POLICY" = "feature-only" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    CUR=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CUR" = "main" ] || [ "$CUR" = "master" ]; then
        BR="autonomous/$(date +%Y%m%d-%H%M%S)"
        git checkout -b "$BR" -q
        log "switched to feature branch: $BR"
    fi
fi

# Resume hint if state file exists
STATE_FILE="$ROOT/state/${PROJECT_NAME}.md"
RESUME_HINT=""
if [ -f "$STATE_FILE" ]; then
    RESUME_HINT=$'\n\nPrior session state (resume from here):\n'"$(cat "$STATE_FILE")"
fi

FULL_PROMPT="You are running fully autonomously without a human. Follow the auto-checkpoint skill rules.

Task: $PROMPT_PART

Project: $PROJECT_DIR
Run ID: $RUN_ID
Hard rules:
- Branch policy: $BRANCH_POLICY (you are NOT on main; do not switch to main)
- Push allowed: $ALLOW_PUSH
- PR allowed: $ALLOW_PR
- Max turns: $MAX_TURNS
- When you sense limits closing in (context >75%, long wall-clock, repeated failures), invoke the auto-checkpoint skill, write resume notes to $STATE_FILE, commit, and exit cleanly.
- Do not read .env / secrets / credentials. Use placeholder values and document what env vars are needed.
- Use the spc command to create a new GitHub repo if the task requires one.$RESUME_HINT"

START_TS=$(date +%s)

# Run claude headless. timeout caps wall-clock as a safety net.
set +e
timeout "$MAX_SESSION_SECONDS" claude \
    --print \
    --dangerously-skip-permissions \
    --max-turns "$MAX_TURNS" \
    --model "$CLAUDE_MODEL" \
    --output-format json \
    "$FULL_PROMPT" \
    > "$RUN_LOG" 2>&1
RC=$?
set -e

ELAPSED=$(( $(date +%s) - START_TS ))
log "claude exited rc=$RC elapsed=${ELAPSED}s"

# Extract token usage from JSON output if present
if [ -f "$RUN_LOG" ]; then
    TOKENS=$(jq -r '.usage.input_tokens + .usage.output_tokens // 0' "$RUN_LOG" 2>/dev/null || echo 0)
    [ -n "$TOKENS" ] && [ "$TOKENS" != "0" ] && "$ROOT/bin/budget.sh" log "$TOKENS" >/dev/null 2>&1 || true
fi

# Final checkpoint
"$ROOT/bin/checkpoint.sh" "$PROJECT_DIR" "runner-end-rc-$RC" || true

# Push + PR if enabled and on a feature branch
if [ "$ALLOW_PUSH" = "1" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    BR=$(git rev-parse --abbrev-ref HEAD)
    if [ "$BR" != "main" ] && [ "$BR" != "master" ]; then
        if git push -u origin "$BR" 2>>"$RUN_LOG"; then
            log "pushed: $BR"
            if [ "$ALLOW_PR" = "1" ] && [ "$RC" = "0" ]; then
                gh pr create --fill --draft 2>>"$RUN_LOG" || log "pr create skipped/failed"
            fi
        fi
    fi
fi

# Move task off queue
if [ "$RC" = "0" ]; then
    printf '%s\t%s\trc=0\trun=%s\n' "$(date -u +%FT%TZ)" "$TASK" "$RUN_ID" >> "$DONE"
else
    printf '%s\t%s\trc=%s\trun=%s\n' "$(date -u +%FT%TZ)" "$TASK" "$RC" "$RUN_ID" >> "$FAILED"
fi
sed -i "${LINE_NO}d" "$QUEUE"

log "done: $PROJECT_NAME rc=$RC"
