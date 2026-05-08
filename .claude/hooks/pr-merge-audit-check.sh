#!/bin/bash
# PreToolUse Bash hook: BLOCK `gh pr merge` until a code-review-audit marker
# exists for the current HEAD SHA at .gaia/local/audit/<sha>.ok.
#
# The marker is the load-bearing handshake between the audit agent and this
# hook. Its presence proves the audit ran against the exact commit being
# merged and that the agent saw no Critical Issues and no unresolved Important
# Issues. The agent writes it at the end of a clean review (see
# .claude/agents/code-review-audit.md, "Audit marker (gate handshake)").
#
# Without a marker, the hook denies the gh pr merge call. To unblock:
#   1. Spawn the code-review-audit agent on the current branch.
#   2. Address any findings; commit and push.
#   3. Re-spawn the agent on the new HEAD; let it write the marker.
#   4. Retry gh pr merge.
#
# See wiki/concepts/PR Merge Workflow.md for the full contract.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Note: avoid naming this `command` — it would shadow bash's `command` builtin
# and make any later `command -v ...` calls in this script silently misbehave.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match `gh pr merge` only when it appears as an actual shell invocation —
# either at the very start of the command (after optional whitespace) or
# immediately after a shell separator (&&, ;, ||, |, newline). This avoids
# false positives on heredoc body text and quoted strings (e.g. commit
# messages that reference the command in prose). Use bash =~ for whole-string
# regex semantics; grep operates line-by-line and would match heredoc body
# lines. The newline alternative covers multi-statement scripts where each
# command is on its own line.
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  : # match at command start
elif [[ "$cmd" =~ $sep_re ]]; then
  : # match after a shell separator (incl. newline)
else
  exit 0
fi

# Resolve HEAD SHA. If we cannot (no git, detached state we can't read),
# fall back to permissive: this hook only enforces in repos where git answers.
sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$sha" ]; then
  exit 0
fi

marker=".gaia/local/audit/${sha}.ok"
if [ -f "$marker" ]; then
  exit 0
fi

reason="PR merge gate: no code-review-audit marker for HEAD ${sha:0:12}.

Expected: ${marker}

To unblock:
  1. Spawn the code-review-audit agent on the current branch.
  2. Address any Critical/Important findings; commit and push.
  3. Re-spawn the agent on the new HEAD; the agent writes the marker
     when it confirms the working tree is clean.
  4. Retry gh pr merge.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: gh pr view <N> --json state — do NOT retry
the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

# --arg safely escapes $reason; never interpolate dynamic values directly into
# the JSON template string.
jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'

exit 0
