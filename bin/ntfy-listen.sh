#!/usr/bin/env bash
# Long-polls the ntfy input topic and routes messages.
# Routes:
#   "q: <text>"  or  "? <text>"  -> quick Q&A; runs claude --print, sends answer to output topic.
#   "<project>|<prompt>"          -> append to tasks/queue.txt as a task.
#   anything else                 -> queue as "?|<text>" (autonomous picks the project).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/limits.conf"

LOG="$ROOT/logs/ntfy-listen.log"
mkdir -p "$ROOT/logs" "$ROOT/state"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

ack() {
    local title="$1" body="$2"
    "$ROOT/bin/notify.sh" low "$title" "$body" >/dev/null 2>&1 || true
}

handle_qa() {
    local question="$1"
    log "Q&A: $question"
    ack "Q&A received" "${question:0:120}"

    # Inject context so questions like "how many tasks" or "what's in the queue" actually work.
    local queue_count done_count failed_count current_task active_branch
    queue_count=$(grep -cv '^\s*\(#\|$\)' "$ROOT/tasks/queue.txt" 2>/dev/null || echo 0)
    done_count=$(wc -l < "$ROOT/tasks/done.log" 2>/dev/null || echo 0)
    failed_count=$(wc -l < "$ROOT/tasks/failed.log" 2>/dev/null || echo 0)
    current_task=$(grep -v '^\s*\(#\|$\)' "$ROOT/tasks/queue.txt" 2>/dev/null | head -1 | cut -d'|' -f1)
    active_branch=$(systemctl --user is-active claude-autonomous.service 2>/dev/null)

    local context
    context="You are answering Lucas's question over ntfy push notification. Reply in <=3500 chars, plain text, no markdown headers. Be terse — fragments OK. Caveman style if it saves chars.

Live system snapshot:
- Autonomous daemon: $active_branch
- Queue: $queue_count tasks remaining
- Completed: $done_count, Failed: $failed_count
- Currently running: ${current_task:-idle}
- Queue file: $ROOT/tasks/queue.txt
- Done log: $ROOT/tasks/done.log
- Repo: /home/projects/claude-autonomous (github.com/Lucasldab/claude-autonomous)
- Other projects live under /home/projects/

If the question asks about queue/tasks/runs/state, read the files above. Otherwise answer normally.

Question: $question"

    local answer rc
    answer=$(timeout 180 claude \
        --print \
        --dangerously-skip-permissions \
        --max-turns "${QA_MAX_TURNS:-5}" \
        --model "$CLAUDE_MODEL" \
        --output-format text \
        --add-dir "$ROOT" \
        "$context" </dev/null 2>&1)
    rc=$?

    # Truncate to fit ntfy body
    local trimmed="${answer:0:${QA_MAX_REPLY_BYTES:-3500}}"
    [ "${#answer}" -gt "${QA_MAX_REPLY_BYTES:-3500}" ] && trimmed="$trimmed
[…truncated]"

    if [ "$rc" = "0" ]; then
        "$ROOT/bin/notify.sh" default "Q&A reply" "$trimmed" >/dev/null 2>&1 || true
    else
        "$ROOT/bin/notify.sh" high "Q&A failed (rc=$rc)" "${trimmed:0:500}" >/dev/null 2>&1 || true
    fi
    log "Q&A done rc=$rc len=${#answer}"
}

handle_task() {
    local task="$1"
    # Append to queue (after the comment block, but simplest = append at end)
    printf '%s\n' "$task" >> "$ROOT/tasks/queue.txt"
    log "queued: $task"
    ack "Task queued" "${task:0:120}"

    # Best-effort commit + push so remote auditor and runner see it
    (
        cd "$ROOT"
        git add tasks/queue.txt 2>/dev/null && \
        git commit -q -m "queue: phone-added task" 2>/dev/null && \
        git push -q 2>/dev/null
    ) || true
}

route() {
    local msg="$1"
    # Trim trailing whitespace / trailing newline
    msg="${msg%$'\n'}"
    msg="${msg%"${msg##*[![:space:]]}"}"
    [ -z "$msg" ] && return

    case "$msg" in
        'q:'*|'Q:'*)    handle_qa "${msg#*:}" ;;
        '?'*)           handle_qa "${msg#?}" ;;
        *'|'*)          handle_task "$msg" ;;
        *)              handle_task "?|$msg" ;;
    esac
}

log "listener started (pid $$) topic=$NTFY_INPUT_TOPIC"
trap 'log "listener exiting"; exit 0' TERM INT

# Long-poll loop with reconnect-on-disconnect
while true; do
    # ntfy /json endpoint streams one JSON object per line
    curl -sN --max-time 0 "${NTFY_SERVER:-https://ntfy.sh}/$NTFY_INPUT_TOPIC/json" \
    | while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Each line is a JSON object: {"id":"...","time":...,"event":"message","topic":"...","message":"..."}
        ev=$(printf '%s' "$line" | jq -r '.event // empty' 2>/dev/null)
        [ "$ev" != "message" ] && continue
        msg=$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)
        [ -z "$msg" ] && continue
        route "$msg"
    done
    log "stream ended — reconnecting in 5s"
    sleep 5
done
