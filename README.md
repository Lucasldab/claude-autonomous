# claude-autonomous

Self-running Claude Code: detects approaching limits, checkpoints cleanly, resumes on next wake.

## Pieces

| Component | Path |
|---|---|
| Runner | `bin/runner.sh` |
| Checkpoint | `bin/checkpoint.sh` |
| Budget tracker | `bin/budget.sh` |
| Task queue | `tasks/queue.txt` |
| Per-project state | `state/<project>.md` |
| Limits config | `config/limits.conf` |
| Skill | `~/.claude/skills/auto-checkpoint/SKILL.md` |
| Service | `~/.config/systemd/user/claude-autonomous.service` |
| Timer | `~/.config/systemd/user/claude-autonomous.timer` |

## Install

```bash
systemctl --user daemon-reload
systemctl --user enable --now claude-autonomous.timer
systemctl --user list-timers claude-autonomous.timer
```

## Add work

Edit `tasks/queue.txt`. One task per line:

```
<project-name-or-abs-path>|<prompt>
```

Example:

```
readingViewer|Audit pan-clamping in src/. Add unit tests. Open PR.
nocturne|Review pin-cycle for races when Syncthing is mid-sync.
```

The runner picks the **top** non-comment line, runs it, removes it on completion (success → `tasks/done.log`, failure → `tasks/failed.log`).

## How limit detection works

Three layers, defense-in-depth:

1. **Skill (`auto-checkpoint`)** — Claude itself watches `/context`, wall-clock, and failure streaks. When any threshold trips, it writes resume notes, commits WIP on a feature branch, and exits cleanly. Loaded via the skill discovery system, triggered by description-match in the runner prompt.
2. **Runner timeout** — `timeout $MAX_SESSION_SECONDS` (default 4hr) hard-kills runaway sessions. The Stop hook still fires.
3. **Budget gate** — `bin/budget.sh` logs token usage from the headless JSON output and refuses to start the next run if the rolling 7-day sum exceeds `WEEKLY_TOKEN_CAP_M`.

## Manual controls

```bash
# Run once now, ignoring away-hours window
FORCE=1 /home/projects/claude-autonomous/bin/runner.sh

# Check weekly usage
bin/budget.sh sum

# Tail live runner log
tail -f logs/runner.log

# See what the timer's doing
journalctl --user -u claude-autonomous -f

# Disable temporarily
systemctl --user stop claude-autonomous.timer

# Re-enable
systemctl --user start claude-autonomous.timer
```

## Safety

- Runs with `--dangerously-skip-permissions` so Claude can fix things without prompting. The user-global `~/.claude/settings.json` `deny` list still blocks `.env`, `*.key`, `*.pem`, credentials.
- Branch policy `feature-only` (default): if Claude starts on `main`/`master` the runner force-switches to `autonomous/<timestamp>` before invoking Claude.
- Push and PR creation are gated by `ALLOW_PUSH` / `ALLOW_PR` in `config/limits.conf`. PRs are opened as drafts.
- Single-instance lock via `flock` — overlapping runs cannot happen.
- Away-hours window prevents the runner from competing with you for the API quota during the day.

## Tuning

Edit `config/limits.conf`. No script changes needed. Key knobs:

- `MAX_SESSION_SECONDS` — wall-clock cap per run.
- `MAX_TURNS` — hard turn cap (`claude --max-turns`).
- `WEEKLY_TOKEN_CAP_M` — millions of tokens / 7-day rolling cap.
- `AWAY_HOUR_START` / `AWAY_HOUR_END` — when the timer is allowed to fire.
- `BRANCH_POLICY` — `feature-only` or `allow-main`.
- `CLAUDE_MODEL` — model alias for headless runs.

## Caveats

- Token usage is **estimated** from the JSON output's `usage` field; the weekly cap is a soft bound, not a contract with Anthropic. The 5hr Pro/Max session window and weekly limit are enforced by Anthropic — if you hit them mid-run, Claude's API will return errors and the run exits with non-zero. The Stop hook still fires and state still saves.
- Headless mode does not have access to the interactive `/context` slash command's exact percentage. The skill instructs Claude to call `/context` (which works in headless via the `--print` mode if invoked as a tool); if it fails, the wall-clock and failure-streak triggers still apply.
- Drafts PRs only on rc=0. Failed runs leave the branch pushed but no PR — review manually.
