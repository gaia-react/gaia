#!/bin/bash
# PreToolUse Bash hook: BLOCK `gh pr merge` until proof of a passing
# code-review-audit exists for the current HEAD. Two signals are accepted:
#
#   1. Local marker file at .gaia/local/audit/<sha>.ok — written by the
#      audit agent at the end of a clean local review.
#
#   2. GAIA-Audit trailer on HEAD's commit message, when the trailer's
#      tree-sha matches HEAD's current tree. Stamped by CI's audit run via
#      .claude/hooks/audit-stamp-trailer.sh and pushed back to the PR
#      branch. Same tree means the audit reviewed the exact content being
#      merged, regardless of which SHA carries the trailer commit.
#
# Either signal proves the audit ran against this content and the agent saw
# no Critical Issues and no unresolved Important Issues. Without one, the
# hook denies the gh pr merge call. To unblock:
#   1. Spawn the code-review-audit agent on the current branch (or rely on
#      CI to stamp the trailer — when CI's audit can run; it skips when
#      the PR modifies the audit workflow file itself).
#   2. Address any findings; commit and push.
#   3. Re-spawn the agent on the new HEAD; let it write the marker
#      or wait for CI's trailer stamp.
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

# Repo-scope: this gate enforces the home repo's audit contract only. A
# `gh pr merge` aimed at a different repo (e.g. a sibling project merged via
# `cd ../other && gh pr merge` or `gh pr merge -R owner/other`) has no bearing
# on this repo's audit markers — allow it.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
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

# Trailer fallback: accept a GAIA-Audit trailer on HEAD when its tree-sha
# matches HEAD's current tree. The trailer format (per audit-stamp-trailer.sh)
# is "GAIA-Audit: <version> <tree-sha>" — two space-separated fields after the
# colon. Tree-sha equality is the load-bearing check: identical trees mean
# identical content, so an audit on a different commit-sha but the same tree
# is auditing the same code being merged.
trailer_line=$(git log -1 --format='%B' HEAD 2>/dev/null \
  | git interpret-trailers --parse 2>/dev/null \
  | grep -E '^GAIA-Audit:' \
  | head -1)
trailer_status="missing"
if [ -n "$trailer_line" ]; then
  trailer_tree=$(printf '%s' "$trailer_line" | awk '{print $NF}')
  head_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)
  if [ -n "$trailer_tree" ] && [ -n "$head_tree" ] && [ "$trailer_tree" = "$head_tree" ]; then
    exit 0
  fi
  trailer_status="present but tree-sha mismatch (audit was for a different tree)"
fi

reason="PR merge gate: no code-review-audit signal for HEAD ${sha:0:12}.

Neither accepted signal is present:
  - Local marker:  ${marker} (missing)
  - Commit trailer: ${trailer_status}

To unblock:
  1. Spawn the code-review-audit agent locally, OR push to the PR branch
     and wait for CI's audit to stamp the trailer (CI skips when the PR
     modifies the audit workflow file itself — in that case only the
     local audit will satisfy the gate).
  2. Address any Critical/Important findings; commit and push.
  3. Re-spawn the agent on the new HEAD; let it write the marker.
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
