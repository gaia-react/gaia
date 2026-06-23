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
# rests on the human PR rollup and the D-8 cross-check below, NOT on the mere
# presence of a line. The gate checks PRESENCE + signal match ONLY; it never
# reads the keep/fix/delete verdict for the presence decision (that keeps the
# verdict advisory).
#
# D-8 CROSS-CHECK (the one place a verdict is read). A `keep` ledger line on a
# file that still carries an UNRESOLVED D-8 lint-honesty error is a PROVABLE
# rubber-stamp: the static honesty lint already flags the file, so a `keep`
# contradicts a machine-checkable signal. When the D-8 rules are enforced (they
# ship in @gaia-react/lint under the `*/no-mock-internal`,
# `*/no-literal-tautology`, `*/no-call-through-only`,
# `*/no-server-import-from-consumer` rule ids) and an in-scope file with a `keep`
# line reports one of those errors, the merge is denied. The cross-check degrades
# gracefully: when ESLint is absent, the rules are not installed, or no D-8 error
# exists, it is silent and the gate passes.
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
#     emergent test whose CURRENT signal has no matching worthiness-ledger line
#     (or a `keep` line on a file with an unresolved D-8 error).
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

# Worthiness ledger location (sibling to the RED ledger). A missing ledger means
# zero matches, which denies for the clean case below.
ledger=".gaia/local/audit-ledger/worthiness.jsonl"

# The frozen D-8 honesty rule-id suffixes. The namespace prefix is the lint
# maintainer's to set, so match on the suffix after the slash.
d8_rule_suffixes='no-mock-internal no-literal-tautology no-call-through-only no-server-import-from-consumer'

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

# Collect missing-line offenders as "file\tfullName" lines, and D-8 offenders as
# "file\truleId" lines.
offenders=""
d8_offenders=""

# Track which in-scope files carry at least one keep line, for the D-8 cross-check.
keep_files=""

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

  file_has_keep=0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    full=$(printf '%s' "$line" | jq -r '.fullName // empty' 2>/dev/null || true)
    sig=$(printf '%s' "$line" | jq -r '.signal // empty' 2>/dev/null || true)
    [ -n "$full" ] && [ -n "$sig" ] || continue

    # Require >=1 ledger line with schema 1, this file, this fullName, and this
    # CURRENT signal. A matching line at a stale signal (the test was edited after
    # its verdict) does not count -> stale-signal rejection. A missing ledger file
    # means zero matches -> deny. Capture the verdict only to drive the D-8
    # cross-check; the presence decision never reads it.
    matched_verdict=""
    if [ -f "$ledger" ]; then
      matched_verdict=$(jq -r --arg f "$rel" --arg n "$full" --arg s "$sig" '
        select((.schema // 0) == 1
          and (.file // "") == $f
          and (.fullName // "") == $n
          and (.signal // "") == $s)
        | (.verdict // "")' "$ledger" 2>/dev/null \
        | head -1 || true)
    fi

    if [ -z "$matched_verdict" ]; then
      offenders="${offenders}${rel}	${full}
"
    elif [ "$matched_verdict" = "keep" ]; then
      file_has_keep=1
    fi
  done <<EOF
$current_ndjson
EOF

  [ "$file_has_keep" -eq 1 ] && keep_files="${keep_files}${rel}
"
done <<EOF
$changed
EOF

# ---------------------------------------------------------------------------
# D-8 cross-check. For each in-scope file carrying at least one `keep` line, ask
# ESLint (JSON output) whether the file still reports an unresolved D-8 honesty
# error. A `keep` on a file the static honesty lint flags is a provable
# rubber-stamp. Degrades gracefully: no ESLint, rules not installed, or no D-8
# error -> silent.
# ---------------------------------------------------------------------------
if [ -n "$keep_files" ] && command -v pnpm >/dev/null 2>&1; then
  while IFS= read -r kf; do
    [ -n "$kf" ] || continue
    # Run ESLint over the single file, JSON format. Any failure (no eslint, no
    # config, the file outside the lint glob) yields no parseable output, so the
    # cross-check stays silent for that file.
    eslint_json=$(pnpm exec eslint --no-error-on-unmatched-pattern \
      --format json "$kf" 2>/dev/null || true)
    [ -n "$eslint_json" ] || continue

    # Extract every error-severity (severity 2) ruleId whose suffix after the
    # last slash is one of the frozen D-8 rule ids. A null ruleId (a parse crash)
    # is ignored.
    hit_rules=$(printf '%s' "$eslint_json" | jq -r '
      .[].messages[]?
      | select((.severity // 0) == 2)
      | (.ruleId // "")
      | select(. != "")' 2>/dev/null || true)
    [ -n "$hit_rules" ] || continue

    while IFS= read -r rid; do
      [ -n "$rid" ] || continue
      suffix="${rid##*/}"
      for d8 in $d8_rule_suffixes; do
        if [ "$suffix" = "$d8" ]; then
          d8_offenders="${d8_offenders}${kf}	${rid}
"
          break
        fi
      done
    done <<EOF
$hit_rules
EOF
  done <<EOF
$keep_files
EOF
fi

# ---------------------------------------------------------------------------
# Decision: allow when no offenders of either kind; otherwise deny.
# ---------------------------------------------------------------------------
if [ -z "$offenders" ] && [ -z "$d8_offenders" ]; then
  exit 0
fi

reason="Worthiness presence gate: an emergent test this PR changed has no matching worthiness-ledger line at its current content (or a \`keep\` contradicts a static honesty error)."

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

if [ -n "$d8_offenders" ]; then
  d8_list=$(printf '%s' "$d8_offenders" \
    | while IFS=$'\t' read -r f r; do
        [ -n "$f" ] || continue
        printf '  \xe2\x80\xa2 %s (%s)\n' "$f" "$r"
      done)
  reason="${reason}

A \`keep\` verdict contradicts an unresolved D-8 static honesty error on:

${d8_list}

A keep on a file the honesty lint flags is a provable rubber-stamp. Resolve the lint error, then re-record the verdict for the fixed content."
fi

reason="${reason}

To unblock:
  1. Run the worthiness evaluator on the changed emergent tests (the tdd skill dispatches it), or invoke the ledger writer per judged test:
       node .gaia/scripts/audit-ledger/append-worthiness.mjs <file> <fullName> <verdict> [artifact]
  2. Resolve any D-8 honesty errors named above, then re-record the verdict for the fixed content.
  3. Retry gh pr merge.

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
