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

    # Inject ALL relevant state into the prompt directly — no file reading needed.
    # This keeps Q&A to a single turn and avoids burning the budget on exploration.
    local queue_count done_count failed_count current_task active_state
    local queue_contents recent_done recent_pr
    queue_count=$(grep -cv '^\s*\(#\|$\)' "$ROOT/tasks/queue.txt" 2>/dev/null || echo 0)
    done_count=$(wc -l < "$ROOT/tasks/done.log" 2>/dev/null || echo 0)
    failed_count=$(wc -l < "$ROOT/tasks/failed.log" 2>/dev/null || echo 0)
    current_task=$(grep -v '^\s*\(#\|$\)' "$ROOT/tasks/queue.txt" 2>/dev/null | head -1)
    active_state=$(systemctl --user is-active claude-autonomous.service 2>/dev/null)
    queue_contents=$(grep -v '^\s*\(#\|$\)' "$ROOT/tasks/queue.txt" 2>/dev/null | nl -ba | head -30)
    recent_done=$(tail -5 "$ROOT/tasks/done.log" 2>/dev/null | cut -f1-2)
    recent_pr=$(ls -t "$ROOT/runs/"*.md 2>/dev/null | head -3 | xargs -I{} grep -h "^- PR:" {} 2>/dev/null | head -3)

    local context
    context="You are answering Lucas over phone push notification. Reply must be <=3500 chars, plain text, no markdown headers. Be terse. Caveman ok. Single turn — do NOT read files; everything you need is below.

=== Live snapshot ===
Daemon: $active_state
Queue: $queue_count tasks remaining
Completed: $done_count, Failed: $failed_count
Currently running: ${current_task:-idle}

=== Queue contents (project|prompt) ===
$queue_contents

=== Recent done ===
$recent_done

=== Recent PRs ===
$recent_pr

=== Question ===
$question

Reply now in 1 turn. Do not read files."

    local answer rc
    answer=$(timeout 90 claude \
        --print \
        --dangerously-skip-permissions \
        --max-turns 1 \
        --model "$CLAUDE_MODEL" \
        --output-format text \
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
    printf '%s\n' "$task" >> "$ROOT/tasks/queue.txt"
    log "queued: $task"
    ack "Task queued" "${task:0:120}"

    (
        cd "$ROOT"
        git add tasks/queue.txt 2>/dev/null && \
        git commit -q -m "queue: phone-added task" 2>/dev/null && \
        git push -q 2>/dev/null
    ) || true
}

handle_directive() {
    local text="$1"
    local fname
    fname="$ROOT/directives/$(date -u +%Y%m%d-%H%M%S).md"
    mkdir -p "$ROOT/directives"
    printf '# Directive (added %s via phone)\n\n%s\n' "$(date -u +%FT%TZ)" "$text" > "$fname"
    log "directive saved: $fname"
    ack "Directive saved" "Will inject into all future task prompts: ${text:0:100}"

    (
        cd "$ROOT"
        git add "$fname" 2>/dev/null && \
        git commit -q -m "directive: phone-added" 2>/dev/null && \
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
        *)              handle_directive "$msg" ;;
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
