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
# The signal covers the test's comment-free content, so a comment reword
# leaves it unchanged and a matching line still counts. Stale-signal lines (a
# line written before a later edit to what the test executes) carry the old
# signal and so never match the recomputed current signal -> rejected, exactly
# like the RED gate's stale-signal invalidation.
#
# See wiki/decisions/Worthiness Presence Gate.md for the full contract.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literal below satisfies, live in .claude/hooks/lib/jq-availability.sh.
# No errexit bracket around the source, unlike the armed hooks that run under
# `set -e`: this one deliberately does not, per the header above.
#
# The literal is `gh`, read off this gate's own arming predicate
# (`gate_verb_frag` below, `gh[[:space:]]+pr[[:space:]]+merge`): every call this
# gate binds invokes `gh`, so the ABSENCE of `gh` from the command proves the
# call sits outside the remit and it is allowed, exactly as a parsed non-merge
# is. Presence is not proof of membership -- an ordinary command carrying `gh`
# inside a word satisfies it too -- and that over-deny is the safe direction.
# What it cannot reach is a spelling the shell assembles (`g\h pr merge`), which
# the arm's own header already names as the accepted residual.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: worthiness-presence-check.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the worthiness presence gate' "$input" tool_input 'gh'

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Avoid the name `command`: it would shadow bash's `command` builtin and break
# later `command -v ...` guards.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Arm the gate when this tool call carries a `gh pr merge`, through the shared
# arming decision (.claude/hooks/lib/verb-arming.sh): the same raw start/sep
# match this hook always paid, re-tested against a same-length view that masks
# a heredoc body proven to be data, plus the first-command tokenizer arm, which
# this hook lacked before, so a quoted verb (`gh pr "merge" <n>`) now arms it
# too. See that library's own header for the full three-pass contract; residual
# 1 still applies at this site: a quoted string carrying a separator before the
# verb still arms the hook, fail-closed, with no safe narrowing.
#
# Loaded from this hook's OWN on-disk location, never cwd: the bats suites run
# this hook by absolute path from a sandbox cwd with no .claude/, so a
# cwd-relative source would miss the lib and flip the arming answer.
#
# This runs BEFORE arming, ahead of even knowing whether the tool call is a
# merge, so an unloadable library denies every Bash tool call rather than
# merge attempts alone.
_va_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
_va_ok=0
if [ -n "$_va_lib_dir" ] && [ -f "$_va_lib_dir/verb-arming.sh" ]; then
  # shellcheck source=/dev/null
  if . "$_va_lib_dir/verb-arming.sh" && type gaia_verb_armed >/dev/null 2>&1; then
    _va_ok=1
  fi
fi
if [ "$_va_ok" -ne 1 ]; then
  jq -n --arg r "Worthiness presence gate: cannot load the shared verb-arming decision (.claude/hooks/lib/verb-arming.sh must exist, be readable, and define gaia_verb_armed). This check runs before the gate knows whether the tool call is a gh pr merge at all, so it denies every Bash tool call rather than merge attempts alone. Restore .claude/hooks/lib/verb-arming.sh (it ships with the framework; a missing or corrupted checkout is the usual cause) and retry." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

gate_verb_frag='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if gaia_verb_armed "$gate_verb_frag" 'gh pr merge' "$cmd"; then
  : # armed
else
  exit 0
fi

# Repo-scope: a `gh pr merge` aimed at a different repo (`-R owner/other`, or
# `cd ../other && gh pr merge`) has no bearing on this repo's worthiness ledger,
# so allow it. Fail-closed (enforce) on any ambiguity.
#
# Every library below is rooted at this file's own directory, reusing the value
# resolved for the verb-arming load above, and never at the process working
# directory. A bare `.claude/hooks/lib/...` test is false from anywhere under
# the repository root, and the fail-open degrades that follow each load are
# written for a BROKEN library: they cannot tell that case from a moved working
# directory, so a bare test would let one `cd` disarm this merge gate silently.
[ -n "$_va_lib_dir" ] && [ -f "$_va_lib_dir/repo-scope.sh" ] && . "$_va_lib_dir/repo-scope.sh"
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Shared RED-ledger lib: the signal-helper wrapper and repo-relative
# normalization. The worthiness ledger writer uses the SAME helper, so signals
# byte-match. Without it we cannot recompute identity, so fail-open.
[ -n "$_va_lib_dir" ] && [ -f "$_va_lib_dir/red-ledger.sh" ] && . "$_va_lib_dir/red-ledger.sh"
type red_ledger_repo_rel >/dev/null 2>&1 || exit 0
type red_ledger_signals >/dev/null 2>&1 || exit 0
type red_ledger_signal_script >/dev/null 2>&1 || exit 0

# Shared worthiness-ledger lib: the one definition of where a tree's
# worthiness verdicts live, also called by the ledger writer
# (.gaia/scripts/audit-ledger/append-worthiness.mjs) so the two never hand-
# build the path independently. Without it we cannot locate the ledger, so
# fail-open.
[ -n "$_va_lib_dir" ] && [ -f "$_va_lib_dir/worthiness-ledger.sh" ] && . "$_va_lib_dir/worthiness-ledger.sh"
type worthiness_ledger_path >/dev/null 2>&1 || exit 0

command -v git >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0

# This hook only enforces where git answers (a real work tree at pwd).
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Script-rooted for the reason the library loads above are: the absence test on
# the next line is an outright `exit 0`, so a cwd below the repository root
# would retire this whole gate rather than report anything.
_gaia_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
classifier_script="$_gaia_root/.gaia/scripts/classifier/classify-determinism.mjs"
[ -f "$classifier_script" ] || exit 0

# The shared main-root resolver, sourced from this hook's own checkout via
# BASH_SOURCE (never process cwd): the worthiness ledger is per-tree state,
# so its root is the ACTING tree, not wherever this hook process happens to
# sit. Derived from the root resolved just above rather than resolving it a
# second time, so the two cannot answer differently.
gaia_scripts="$_gaia_root/.gaia/scripts"
# shellcheck source=/dev/null
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0

# The acting agent's working directory: the payload cwd when it is absolute
# and resolves to a checkout, this hook's process cwd otherwise. "Resolves to
# a checkout" is the resolver's own question, so it is asked by calling it
# rather than by a raw git call this hook writes itself. Payload cwd is
# measured, not contracted, and only established on PreToolUse, so the
# fallback is mandatory.
payload_cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
source_cwd="$PWD"
if [[ "$payload_cwd" == /* ]] && gaia_resolve_tree_root "$payload_cwd" >/dev/null 2>&1; then
  source_cwd="$payload_cwd"
fi
# The command's own target outranks both. A home verdict covers this
# REPOSITORY, and every linked worktree of it is this repository, so a leading
# `cd <worktree> &&` ahead of the merge means the merge acts on a checkout that
# is not this hook's, while the payload cwd is only where the agent was
# standing. The merge-base diff and the per-tree ledger below both belong to
# that checkout. The repo-scope verdict publishes the `cd` target only once it
# resolved as this repository, so an unresolvable one never reaches here.
if [ -n "${GAIA_REPO_SCOPE_LEAD_CD:-}" ] \
   && gaia_resolve_tree_root "$GAIA_REPO_SCOPE_LEAD_CD" >/dev/null 2>&1; then
  source_cwd="$GAIA_REPO_SCOPE_LEAD_CD"
fi
tree_root="$(gaia_resolve_tree_root "$source_cwd" 2>/dev/null)" || exit 0

# Worthiness ledger location (sibling to the RED ledger), anchored on and
# keyed to this tree's root via the shared resolver. A missing ledger means
# zero matches, which denies for the clean case below.
ledger="$(worthiness_ledger_path "$tree_root")" || exit 0

# ---------------------------------------------------------------------------
# Resolve the PR base, the default branch this work forks from, in the ACTING
# tree: the branch being merged is that checkout's HEAD, so a base resolved
# anywhere else scopes the diff to another branch's changes. Prefer the
# remote's advertised default; fall back to main. The merge base scopes the diff
# to THIS PR's changes, not unrelated drift already on the base branch. Mirrors
# pr-merge-audit-check.sh's check_out_of_scope_pr. Fail-open: an unresolved base
# or an empty diff means nothing in scope for this gate.
# ---------------------------------------------------------------------------
default_branch=$(git -C "$tree_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^refs/remotes/origin/@@')
[ -n "$default_branch" ] || default_branch="main"

base=$(git -C "$tree_root" merge-base HEAD "origin/${default_branch}" 2>/dev/null \
  || git -C "$tree_root" merge-base HEAD "${default_branch}" 2>/dev/null \
  || true)
[ -n "$base" ] || exit 0

# `-z` because the emergent-surface case patterns below match a repo-relative
# path literally: under git's default core.quotePath a path carrying non-ASCII
# or control bytes comes back wrapped in literal double quotes, matches none of
# them, and the gate passes on the input it exists to hold. The `tr` restores
# the newlines the read loop below splits on.
changed=$(git -C "$tree_root" diff --name-only -z "${base}...HEAD" 2>/dev/null | tr '\0' '\n' || true)
[ -n "$changed" ] || exit 0

# Echo "emergent" only when the classifier affirmatively classifies the given
# repo-relative path emergent; echo nothing otherwise (non-zero exit, unparseable
# JSON, or a strict verdict). Mirrors red-verify-commit-check.sh.
classify_emergent() {
  local rel="$1"
  local out
  # Run from the ACTING TREE, not the process working directory. `$rel` stays
  # repo-relative because the classifier's own path rules read it, but it must
  # not be resolved against a working directory nobody chose: the file read then
  # fails and the verdict stops describing the file. The `cd` is inside a
  # command substitution, so it never persists into the rest of this hook.
  out=$( cd "$tree_root" && node "$classifier_script" "$rel" 2>/dev/null ) || return 0
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
  # gone, there is nothing in scope for it. Tested against the ACTING TREE, not
  # the process working directory: `$rel` is repo-relative, so from a
  # subdirectory this answers "deleted" for every file that exists, and the
  # `continue` empties the offender scan into a clean pass.
  [ -f "$tree_root/$rel" ] || continue

  # Authoritative emergent membership: the determinism classifier. A `.ts` test
  # under app/components/** that the classifier proves deterministic is RED-gated,
  # not worthiness-gated; skip it. A classifier failure echoes nothing (fail-open:
  # the file is not treated as emergent, so it is not demanded here; the RED gate
  # owns the deterministic surface).
  [ -n "$(classify_emergent "$rel")" ] || continue

  # Current tests: helper over the working-tree file content on disk. Parse
  # failure (mid-edit syntax error) -> skip this file (fail-open).
  current_ndjson=""
  # From the acting tree, for the reason the classifier call above gives: this
  # helper reads the file from disk at the repo-relative path, so from a
  # subdirectory it finds nothing, and "no signals" is a `continue` -- the file
  # leaves the scan and the merge clears with no verdict demanded.
  current_ndjson=$( cd "$tree_root" && red_ledger_signals "$rel" 2>/dev/null ) || { continue; }
  # No emitted tests (only dynamic-title tests, or a no-tests file): nothing in
  # scope for this file.
  [ -n "$current_ndjson" ] || continue

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    full=$(printf '%s' "$line" | jq -r '.fullName // empty' 2>/dev/null || true)
    sig=$(printf '%s' "$line" | jq -r '.signal // empty' 2>/dev/null || true)
    [ -n "$full" ] && [ -n "$sig" ] || continue

    # Require >=1 ledger line with schema 1, this file, this fullName, and this
    # CURRENT signal. A matching line at a stale signal (the test's executed
    # content was edited after its verdict; a comment reword does not change the
    # signal) does not count -> stale-signal rejection. A missing ledger file
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

These emergent tests changed in this PR, but no worthiness verdict was recorded for their current content. The line proves only that the test-identity extractor ran over the current bytes, not that judgement was applied; the human PR rollup carries that. The signal covers the test's comment-free content, so rewording a comment leaves the line intact, but a change to what the test executes invalidates the line (the signal changes), so a fresh verdict must be recorded for the current body."
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
