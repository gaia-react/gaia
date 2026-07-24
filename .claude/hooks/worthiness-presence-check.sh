#!/usr/bin/env bash
# PreToolUse Bash hook: DENY `gh pr merge` when an emergent test the PR changed
# has no worthiness-ledger line matching its CURRENT content. This is the
# merge-time half of the worthiness audit: the evaluator
# (.claude/agents/worthiness-evaluator.md) judges each emergent test and the tdd
# skill appends one ledger line per judged test
# (.gaia/scripts/audit-ledger/append-worthiness.mjs); this hook enforces at merge
# that such a line exists for the content being merged. It sits ALONGSIDE
# pr-merge-audit-check.sh: both gate `gh pr merge` and deny independently.
#
# WHAT THIS PROVES (and what it does NOT). The check is a LEDGER LOOKUP + a
# SIGNAL RECOMPUTE; it never re-runs tests and never re-runs the evaluator. A
# present, signal-matching ledger line proves only that the test-identity
# extractor RAN over the test's current content and a verdict was recorded
# against that exact content. It does NOT prove a human (or an LLM) applied
# judgement: a scripted rubber-stamp (run extract-test-signals.mjs, append a
# `keep` for every emitted signal) mints every matching line at near-zero cost
# and is the cost-minimizing path through this gate. The judgement guarantee
# rests on the human PR rollup, NOT on the mere presence of a line. The gate
# checks PRESENCE + signal match ONLY; it never reads the keep/fix/delete verdict
# at all (that keeps the verdict advisory).
#
# This gate does NOT re-check static test-honesty lint. That invariant is owned,
# once, by its own gate: the Quality Gate at commit (eslint --max-warnings=0) and
# CI lint at PR. A file carrying a honesty-lint error cannot be committed or
# merged, so re-checking it here would double-gate an invariant another system
# already enforces ruthlessly. The worthiness gate owns presence; lint owns
# honesty.
#
# SCOPE. The gate scopes to the EMERGENT test files THIS PR changed (git diff
# against the merge base with the default branch), not the whole repo's emergent
# tests. Emergent membership is decided by the determinism classifier
# (.gaia/scripts/classifier/classify-determinism.mjs): a changed test file whose
# classifier verdict is `emergent` is in scope; a `.ts` test under
# app/components/** that the classifier proves deterministic is RED-gated, not
# worthiness-gated, and is excluded. When ZERO emergent test files changed, the
# gate is a NO-OP and allows the merge.
#
# COST/LATENCY. The recompute is O(emergent test files changed in the PR): each
# in-scope file is fed through the signal helper once. Wall-clock therefore
# scales with the emergent test count; this axis is not made sub-linear.
#
# Fail-open vs fail-closed (threat model: a cooperative-but-fallible agent):
#   - jq / git / node / the RED-ledger lib / the classifier unavailable -> exit 0
#     (allow). Sibling-hook posture; the gate enforces only where its tooling
#     answers.
#   - a changed emergent test file the signal helper cannot parse (mid-edit
#     syntax error) -> that file is skipped, never denied. Fail-open.
#   - the deny path is fail-closed ONLY for the clean case: a parseable in-scope
#     emergent test whose CURRENT signal has no matching worthiness-ledger line.
#
# Stale-signal lines (a line written before a later test edit) carry the old
# signal and so never match the recomputed current signal -> rejected, exactly
# like the RED gate's stale-signal invalidation.
#
# See wiki/decisions/Worthiness Presence Gate.md for the full contract.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Avoid the name `command`: it would shadow bash's `command` builtin and break
# later `command -v ...` guards.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match `gh pr merge` only when it appears as an actual shell invocation, either
# at the very start of the command or immediately after a shell separator. This
# avoids false positives on heredoc body text and quoted strings. Mirrors
# pr-merge-audit-check.sh exactly.
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  : # match at command start
elif [[ "$cmd" =~ $sep_re ]]; then
  : # match after a shell separator (incl. newline)
else
  exit 0
fi

# Repo-scope: a `gh pr merge` aimed at a different repo (`-R owner/other`, or
# `cd ../other && gh pr merge`) has no bearing on this repo's worthiness ledger,
# so allow it. Fail-closed (enforce) on any ambiguity.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Shared RED-ledger lib: the signal-helper wrapper and repo-relative
# normalization. The worthiness ledger writer uses the SAME helper, so signals
# byte-match. Without it we cannot recompute identity, so fail-open.
[ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh
type red_ledger_repo_rel >/dev/null 2>&1 || exit 0
type red_ledger_signals >/dev/null 2>&1 || exit 0
type red_ledger_signal_script >/dev/null 2>&1 || exit 0

command -v git >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0

# This hook only enforces where git answers (a real work tree at pwd).
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

classifier_script=".gaia/scripts/classifier/classify-determinism.mjs"
[ -f "$classifier_script" ] || exit 0

# The shared main-root resolver, sourced from this hook's own checkout via
# BASH_SOURCE (never process cwd): the worthiness ledger is per-tree state,
# so its root is the ACTING tree, not wherever this hook process happens to
# sit.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0

# The acting agent's working directory: the payload cwd when it is absolute
# and resolves to a checkout, this hook's process cwd otherwise (mirrors
# block-worktree-path-mismatch.sh's own payload-cwd idiom). Payload cwd is
# measured, not contracted, and only established on PreToolUse, so the
# fallback is mandatory.
payload_cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
source_cwd="$PWD"
if [[ "$payload_cwd" == /* ]] && git -C "$payload_cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
  source_cwd="$payload_cwd"
fi
tree_root="$(gaia_resolve_tree_root "$source_cwd" 2>/dev/null)" || exit 0

# Worthiness ledger location (sibling to the RED ledger), anchored on this
# tree's root. A missing ledger means zero matches, which denies for the
# clean case below.
ledger="$tree_root/.gaia/local/worthiness-ledger/worthiness.jsonl"

# ---------------------------------------------------------------------------
# Resolve the PR base, the default branch this work forks from. Prefer the
# remote's advertised default; fall back to main. The merge base scopes the diff
# to THIS PR's changes, not unrelated drift already on the base branch. Mirrors
# pr-merge-audit-check.sh's check_out_of_scope_pr. Fail-open: an unresolved base
# or an empty diff means nothing in scope for this gate.
# ---------------------------------------------------------------------------
default_branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^refs/remotes/origin/@@')
[ -n "$default_branch" ] || default_branch="main"

base=$(git merge-base HEAD "origin/${default_branch}" 2>/dev/null \
  || git merge-base HEAD "${default_branch}" 2>/dev/null \
  || true)
[ -n "$base" ] || exit 0

changed=$(git diff --name-only "${base}...HEAD" 2>/dev/null || true)
[ -n "$changed" ] || exit 0

# Echo "emergent" only when the classifier affirmatively classifies the given
# repo-relative path emergent; echo nothing otherwise (non-zero exit, unparseable
# JSON, or a strict verdict). Mirrors red-verify-commit-check.sh.
classify_emergent() {
  local rel="$1"
  local out
  out=$(node "$classifier_script" "$rel" 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  printf '%s' "$out" \
    | jq -r 'select((.classification // "") == "emergent") | "emergent"' \
        2>/dev/null \
    | head -1
}

# Collect missing-line offenders as "file\tfullName" lines.
offenders=""

while IFS= read -r path; do
  [ -n "$path" ] || continue

  # Emergent surface only: app/components/** or .playwright/**. The signal helper
  # only emits for test files (.test.ts/.test.tsx and playwright .spec.ts); a
  # non-test file under these paths emits nothing and drops out below.
  case "$path" in
    app/components/*.test.ts | app/components/*.test.tsx) ;;
    .playwright/*.spec.ts | .playwright/*.spec.tsx) ;;
    .playwright/*.test.ts | .playwright/*.test.tsx) ;;
    *) continue ;;
  esac

  rel=$(red_ledger_repo_rel "$path")

  # A pure deletion leaves no working-tree file to recompute from; if the file is
  # gone, there is nothing in scope for it.
  [ -f "$rel" ] || continue

  # Authoritative emergent membership: the determinism classifier. A `.ts` test
  # under app/components/** that the classifier proves deterministic is RED-gated,
  # not worthiness-gated; skip it. A classifier failure echoes nothing (fail-open:
  # the file is not treated as emergent, so it is not demanded here; the RED gate
  # owns the deterministic surface).
  [ -n "$(classify_emergent "$rel")" ] || continue

  # Current tests: helper over the working-tree file content on disk. Parse
  # failure (mid-edit syntax error) -> skip this file (fail-open).
  current_ndjson=""
  current_ndjson=$(red_ledger_signals "$rel" 2>/dev/null) || { continue; }
  # No emitted tests (only dynamic-title tests, or a no-tests file): nothing in
  # scope for this file.
  [ -n "$current_ndjson" ] || continue

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    full=$(printf '%s' "$line" | jq -r '.fullName // empty' 2>/dev/null || true)
    sig=$(printf '%s' "$line" | jq -r '.signal // empty' 2>/dev/null || true)
    [ -n "$full" ] && [ -n "$sig" ] || continue

    # Require >=1 ledger line with schema 1, this file, this fullName, and this
    # CURRENT signal. A matching line at a stale signal (the test was edited after
    # its verdict) does not count -> stale-signal rejection. A missing ledger file
    # means zero matches -> deny. Presence is the whole decision; the
    # keep/fix/delete verdict stays advisory and is never read here.
    matched=""
    if [ -f "$ledger" ]; then
      matched=$(jq -r --arg f "$rel" --arg n "$full" --arg s "$sig" '
        select((.schema // 0) == 1
          and (.file // "") == $f
          and (.fullName // "") == $n
          and (.signal // "") == $s)
        | "1"' "$ledger" 2>/dev/null \
        | head -1 || true)
    fi

    if [ -z "$matched" ]; then
      offenders="${offenders}${rel}	${full}
"
    fi
  done <<EOF
$current_ndjson
EOF
done <<EOF
$changed
EOF

# ---------------------------------------------------------------------------
# Decision: allow when no offenders; otherwise deny.
# ---------------------------------------------------------------------------
if [ -z "$offenders" ]; then
  exit 0
fi

reason="Worthiness presence gate: an emergent test this PR changed has no matching worthiness-ledger line at its current content."

if [ -n "$offenders" ]; then
  missing_list=$(printf '%s' "$offenders" \
    | while IFS=$'\t' read -r f n; do
        [ -n "$f" ] || continue
        printf '  \xe2\x80\xa2 %s \xe2\x80\xba %s\n' "$f" "$n"
      done)
  reason="${reason}

No worthiness-ledger line matches the current signal for:

${missing_list}

These emergent tests changed in this PR, but no worthiness verdict was recorded for their current content. The line proves only that the test-identity extractor ran over the current bytes, not that judgement was applied; the human PR rollup carries that. Editing a test after its verdict invalidates the line (the signal changes), so a fresh verdict must be recorded for the current body."
fi

reason="${reason}

To unblock:
  1. Run the worthiness evaluator on the changed emergent tests (the tdd skill dispatches it), or invoke the ledger writer per judged test:
       node .gaia/scripts/audit-ledger/append-worthiness.mjs <file> <fullName> <verdict> [artifact]
  2. Retry gh pr merge.

See wiki/decisions/Worthiness Presence Gate.md for the full contract."

# --arg safely escapes $reason; never interpolate dynamic values into the JSON.
jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'

exit 0
