#!/usr/bin/env bash
# Autonomous runner daemon. Runs as a long-lived systemd service:
# Type=simple, no timer needed. Loops forever, processes one queued task at
# a time. Single-instance is enforced by systemd, so no flock is needed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE="$ROOT/tasks/queue.txt"
DONE_LOG="$ROOT/tasks/done.log"
FAILED_LOG="$ROOT/tasks/failed.log"
LOG_DIR="$ROOT/logs"

mkdir -p "$ROOT/tasks" "$ROOT/state" "$LOG_DIR" "$ROOT/runs"
touch "$DONE_LOG" "$FAILED_LOG"

# shellcheck disable=SC1091
source "$ROOT/config/limits.conf"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_DIR/runner.log"; }

# ---------- helpers ----------

in_away_window() {
    [ "${FORCE:-0}" = "1" ] && return 0
    [ "$AWAY_HOUR_START" = "$AWAY_HOUR_END" ] && return 0
    local h
    h=$(date +%H | sed 's/^0//')
    if [ "$AWAY_HOUR_START" -lt "$AWAY_HOUR_END" ]; then
        [ "$h" -ge "$AWAY_HOUR_START" ] && [ "$h" -lt "$AWAY_HOUR_END" ]
    else
        [ "$h" -ge "$AWAY_HOUR_START" ] || [ "$h" -lt "$AWAY_HOUR_END" ]
    fi
}

queue_has_work() {
    grep -qv '^\s*\(#\|$\)' "$QUEUE" 2>/dev/null
}

budget_ok() {
    "$ROOT/bin/budget.sh" check "$WEEKLY_TOKEN_CAP_M" >/dev/null
}

# Seconds to sleep before next poll.
# Outside window: sleep until window opens (or 5min, whichever sooner).
# Window open but queue empty / budget exhausted: 60s.
sleep_duration() {
    if ! in_away_window; then
        echo 300
    else
        echo 60
    fi
}

# ---------- task execution ----------

run_one_task() {
    local task_line line_no task project_part prompt_part project_dir project_name
    local run_id run_log start_ts rc elapsed tokens pr_url branch state_file resume_hint full_prompt summary_file

    task_line=$(grep -nv '^\s*\(#\|$\)' "$QUEUE" | head -1 || true)
    [ -z "$task_line" ] && return 1

    line_no="${task_line%%:*}"
    task="${task_line#*:}"
    project_part="${task%%|*}"
    prompt_part="${task#*|}"

    case "$project_part" in
        /*) project_dir="$project_part" ;;
        *)  project_dir="/home/projects/$project_part" ;;
    esac

    if [ ! -d "$project_dir" ]; then
        log "project missing: $project_dir — moving to failed"
        printf '%s\t%s\tproject-missing\n' "$(date -u +%FT%TZ)" "$task" >> "$FAILED_LOG"
        sed -i "${line_no}d" "$QUEUE"
        return 0
    fi

    project_name=$(basename "$project_dir")
    run_id="$(date -u +%Y%m%d-%H%M%S)-$project_name"
    run_log="$LOG_DIR/$run_id.log"

    log "starting: $project_name — $prompt_part"
    "$ROOT/bin/notify.sh" low "Run starting: $project_name" "$prompt_part" || true

    cd "$project_dir"

    if [ "$BRANCH_POLICY" = "feature-only" ] && git rev-parse --git-dir >/dev/null 2>&1; then
        local cur
        cur=$(git rev-parse --abbrev-ref HEAD)
        if [ "$cur" = "main" ] || [ "$cur" = "master" ]; then
            local br="autonomous/$(date +%Y%m%d-%H%M%S)"
            git checkout -b "$br" -q
            log "switched to feature branch: $br"
        fi
    fi

    state_file="$ROOT/state/${project_name}.md"
    resume_hint=""
    [ -f "$state_file" ] && resume_hint=$'\n\nPrior session state (resume from here):\n'"$(cat "$state_file")"

    full_prompt="You are running fully autonomously without a human supervising. The only valid stop conditions are: (1) you have completed THIS task and opened the PR, (2) you have hit a real limit and must checkpoint (context >=75%, wall-clock >=3.5h, repeated rate-limit errors, or three consecutive tool failures on the same target). 'I am uncertain' and 'Lucas should decide X' are NOT stop conditions — make the call yourself, document the choice in the PR description, and proceed. The runner will queue the next task automatically; you do not need to ration effort.

Task: $prompt_part

Project: $project_dir
Run ID: $run_id
Hard rules:
- Branch policy: $BRANCH_POLICY (you are NOT on main; do not switch to main)
- Push allowed: $ALLOW_PUSH
- PR allowed: $ALLOW_PR
- Max turns: $MAX_TURNS
- Do not read .env / secrets / credentials. Use placeholder values; document required env vars in the PR.
- Use spc <name> (or spc -p <name> for private) if the task requires creating a new GitHub repo.
- If you genuinely cannot proceed without a destructive action (force push, rewrite history, delete data), document that as a blocker in the PR body and finish whatever non-destructive work you can. Do not abandon the task — partial work in a draft PR is preferable to no PR.
- Auto-checkpoint skill: invoke ONLY on real limit conditions above, never on 'task feels done' or 'I'm unsure'.$resume_hint"

    start_ts=$(date +%s)

    set +e
    timeout "$MAX_SESSION_SECONDS" claude \
        --print \
        --dangerously-skip-permissions \
        --max-turns "$MAX_TURNS" \
        --model "$CLAUDE_MODEL" \
        --output-format json \
        "$full_prompt" \
        > "$run_log" 2>&1
    rc=$?
    set -e

    elapsed=$(( $(date +%s) - start_ts ))
    log "claude exited rc=$rc elapsed=${elapsed}s"

    tokens=0
    if [ -f "$run_log" ]; then
        tokens=$(jq -r '(.usage.input_tokens // 0) + (.usage.output_tokens // 0)' "$run_log" 2>/dev/null || echo 0)
        [ "$tokens" -gt 0 ] && "$ROOT/bin/budget.sh" log "$tokens" >/dev/null 2>&1 || true
    fi

    "$ROOT/bin/checkpoint.sh" "$project_dir" "runner-end-rc-$rc" || true

    branch=""
    if [ "$ALLOW_PUSH" = "1" ] && git rev-parse --git-dir >/dev/null 2>&1; then
        branch=$(git rev-parse --abbrev-ref HEAD)
        if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
            if git push -u origin "$branch" 2>>"$run_log"; then
                log "pushed: $branch"
                if [ "$ALLOW_PR" = "1" ] && [ "$rc" = "0" ]; then
                    gh pr create --fill --draft 2>>"$run_log" || log "pr create skipped/failed"
                fi
            fi
        fi
    fi

    if [ "$rc" = "0" ]; then
        printf '%s\t%s\trc=0\trun=%s\n' "$(date -u +%FT%TZ)" "$task" "$run_id" >> "$DONE_LOG"
    else
        printf '%s\t%s\trc=%s\trun=%s\n' "$(date -u +%FT%TZ)" "$task" "$rc" "$run_id" >> "$FAILED_LOG"
    fi
    sed -i "${line_no}d" "$QUEUE"

    pr_url=$(grep -oE 'https://github.com/[^ ]*pull/[0-9]+' "$run_log" 2>/dev/null | head -1 || true)
    if [ "$rc" = "0" ] && [ -n "$pr_url" ]; then
        "$ROOT/bin/notify.sh" default "PR ready: $project_name" "${elapsed}s, ~${tokens} tokens." "$pr_url" || true
    elif [ "$rc" = "0" ]; then
        "$ROOT/bin/notify.sh" low "Run done: $project_name" "rc=0, no PR opened. ${elapsed}s." || true
    elif [ "$rc" = "124" ] || [ "$elapsed" -ge "$MAX_SESSION_SECONDS" ]; then
        "$ROOT/bin/notify.sh" high "Run TIMEOUT: $project_name" "Hit ${MAX_SESSION_SECONDS}s cap. Check logs." || true
    else
        "$ROOT/bin/notify.sh" high "Run FAILED: $project_name" "rc=$rc, ${elapsed}s. May need your input." || true
    fi

    summary_file="$ROOT/runs/$run_id.md"
    {
        echo "# Run $run_id"
        echo
        echo "- Project: \`$project_dir\`"
        echo "- Task: $prompt_part"
        echo "- Exit code: $rc"
        echo "- Elapsed: ${elapsed}s (cap ${MAX_SESSION_SECONDS}s)"
        echo "- Tokens (estimated): $tokens"
        echo "- Branch at end: $(cd "$project_dir" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo n/a)"
        echo "- HEAD: $(cd "$project_dir" && git rev-parse --short HEAD 2>/dev/null || echo n/a)"
        echo "- PR: ${pr_url:-none}"
        echo "- Hit timeout: $([ "$elapsed" -ge "$MAX_SESSION_SECONDS" ] && echo yes || echo no)"
        echo "- Stop reason hint (last 5 log lines):"
        echo
        echo '```'
        tail -5 "$run_log" 2>/dev/null | sed 's/^/  /'
        echo '```'
    } > "$summary_file"

    (
        cd "$ROOT"
        git add "runs/$run_id.md" "state/${project_name}.md" "tasks/queue.txt" "tasks/done.log" "tasks/failed.log" "state/budget.log" 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -q -m "run: $run_id rc=$rc ($project_name)" 2>/dev/null || true
            git push -q 2>/dev/null || true
        fi
    ) || true

    log "done: $project_name rc=$rc"
    return 0
}

# ---------- main loop ----------

log "daemon started (pid $$)"
trap 'log "daemon exiting"; exit 0' TERM INT

EMPTY_NOTIFIED=0  # only ping once per "queue went from non-empty to empty"

while true; do
    if ! in_away_window; then
        sleep "$(sleep_duration)"
        continue
    fi

    if ! budget_ok; then
        # Budget gate — sleep and retry; budget rolls forward in time.
        sleep "$(sleep_duration)"
        continue
    fi

    if ! queue_has_work; then
        if [ "$EMPTY_NOTIFIED" = "0" ]; then
            "$ROOT/bin/notify.sh" default "Claude queue empty" "Add tasks to /home/projects/claude-autonomous/tasks/queue.txt or runner sits idle." "https://github.com/Lucasldab/claude-autonomous/blob/main/tasks/queue.txt" || true
            EMPTY_NOTIFIED=1
        fi
        sleep "$(sleep_duration)"
        continue
    fi

    EMPTY_NOTIFIED=0
    run_one_task || true
    # Small breather between tasks
    sleep 5
done
