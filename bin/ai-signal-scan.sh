#!/usr/bin/env bash
# Scan a branch on a GitHub repo for AI/automation signals.
# Usage: ai-signal-scan.sh <owner/repo> <branch>
# Output: prints "CLEAN" or "DIRTY: <details>" and exits 0 always.

set -uo pipefail

REPO="${1:?repo required}"
BRANCH="${2:?branch required}"

PATTERN='autonomous|[Cc]laude(?! Code)|[Cc]laude Code|[Aa]nthropic|🤖|Co-Authored-By:.*[Cc]laude|Generated with.*[Cc]laude|AI assistant|AI-generated|AI-written|automated'

# Pull base diff content + commit messages for the branch
diff_url="repos/$REPO/compare/main...$BRANCH"
data=$(gh api "$diff_url" 2>/dev/null)
[ -z "$data" ] && { echo "DIRTY: branch not found or compare failed"; exit 0; }

hits=""

# Branch name itself
if echo "$BRANCH" | grep -qiE 'autonomous|claude|anthropic|bot|agent'; then
    hits="${hits}branch-name "
fi

# Commit messages
if echo "$data" | jq -r '.commits[].commit.message' 2>/dev/null | grep -qiE 'autonomous|claude|anthropic|🤖|Co-Authored-By|Generated with'; then
    hits="${hits}commit-msg "
fi

# File contents (the patch field has the diff)
if echo "$data" | jq -r '.files[]?.patch // ""' 2>/dev/null | grep -qiE 'autonomous|claude|anthropic|🤖|Co-Authored-By|Generated with'; then
    hits="${hits}file-content "
fi

# Filenames
if echo "$data" | jq -r '.files[]?.filename' 2>/dev/null | grep -qiE 'autonomous|claude|anthropic'; then
    hits="${hits}filename "
fi

if [ -z "$hits" ]; then
    echo "CLEAN"
else
    echo "DIRTY: $hits"
fi
