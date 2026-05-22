#!/bin/bash
# PreToolUse Bash hook: BLOCK `gh pr merge` until proof of a passing
# code-review-audit exists for the current HEAD. Three signals are accepted:
#
#   1. Local marker file at .gaia/local/audit/<sha>.ok — written by the
#      audit agent at the end of a clean local review.
#
#   2. GAIA-Audit trailer on HEAD's commit message, when the trailer's
#      tree-sha matches HEAD's current tree. Written by a local audit run
#      via .claude/hooks/audit-stamp-trailer.sh.
#
#   3. GAIA-Audit GitHub commit status on HEAD, description "<version> <tree>",
#      when both version and tree-sha match. CI stamps this status instead of
#      pushing an empty marker commit (pushing it would re-trigger CI and leave
#      the PR HEAD without check runs). Queried via `gh api` using GH_TOKEN or
#      the ambient gh auth session.
#
# Any signal proves the audit ran against this content and the agent saw
# no Critical Issues and no unresolved Important Issues. Without one, the
# hook denies the gh pr merge call. To unblock:
#   1. Spawn the code-review-audit agent on the current branch, OR push to the
#      PR branch and wait for CI's audit to stamp the GitHub commit status (CI
#      skips when the PR modifies the audit workflow file itself — in that case
#      only the local audit will satisfy the gate).
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

# GitHub commit status fallback: CI stamps a GAIA-Audit commit status instead
# of pushing an empty marker commit (pushing it would re-trigger CI and leave
# the PR HEAD without check runs). Query the API for a matching status on HEAD.
# Description shape: "<version> <40-hex-tree>". Both must match .gaia/VERSION
# and HEAD's tree. Falls through silently on any error (no gh, no token, no
# GITHUB_REPOSITORY, API failure) — the deny path below fires as normal.
check_github_status() {
  command -v gh >/dev/null 2>&1 || return 1

  # Derive repo slug. GITHUB_REPOSITORY is set inside Actions; derive from the
  # origin remote URL for local runs.
  repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then
    origin_url=$(git remote get-url origin 2>/dev/null || true)
    [ -n "$origin_url" ] || return 1
    repo=$(printf '%s' "$origin_url" \
      | sed -E 's|.*github\.com[:/]([^/]+/[^/]+?)(\.git)?$|\1|')
    # sed produces the full URL when no pattern matches — reject it.
    [ "$repo" != "$origin_url" ] || return 1
    case "$repo" in
      */*) ;;  # must contain exactly one slash (owner/name)
      *) return 1 ;;
    esac
  fi

  # Read .gaia/VERSION (same "no stamp without VERSION" invariant as CI).
  cur_version=""
  if [ -f ".gaia/VERSION" ]; then
    cur_version=$(tr -d '\r' < ".gaia/VERSION" | awk 'NF{print; exit}')
    cur_version="${cur_version#"${cur_version%%[![:space:]]*}"}"
    cur_version="${cur_version%"${cur_version##*[![:space:]]}"}"
  fi
  [ -n "$cur_version" ] || return 1

  cur_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)
  [ -n "$cur_tree" ] || return 1

  status_desc=$(gh api \
    "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit")) | first | .description' \
    2>/dev/null || true)

  [ -n "$status_desc" ] && [ "$status_desc" != "null" ] || return 1

  status_version=$(printf '%s' "$status_desc" | awk '{print $1}')
  status_tree=$(printf '%s' "$status_desc" | awk '{print $2}')

  [ -n "$status_version" ] && [ -n "$status_tree" ] || return 1
  [ "$status_version" = "$cur_version" ] || return 1
  [ "$status_tree" = "$cur_tree" ] || return 1

  return 0
}

if check_github_status; then
  exit 0
fi

reason="PR merge gate: no code-review-audit signal for HEAD ${sha:0:12}.

None of the accepted signals is present:
  - Local marker:    ${marker} (missing)
  - Commit trailer:  ${trailer_status}
  - GitHub CI status: absent or version/tree mismatch

To unblock:
  1. Spawn the code-review-audit agent locally, OR push to the PR branch
     and wait for CI's audit to stamp the GitHub commit status (CI skips
     when the PR modifies the audit workflow file itself — in that case
     only the local audit will satisfy the gate).
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
