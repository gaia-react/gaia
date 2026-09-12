#!/usr/bin/env bash
# PreToolUse Bash hook: DENY `git commit` when a new-at-HEAD test that now
# passes has no observed failing run (RED) on record matching its current
# content. This is the "deny the consequential action" half of mechanical TDD
# RED-verification: the sibling capture hook (capture-red-observations.sh)
# records REDs at test-run time; this hook enforces them at commit. It mirrors
# pr-merge-audit-check.sh: a PreToolUse Bash deny gating the least-reversible
# action on a recorded marker keyed to content.
#
# The check is a LEDGER LOOKUP + a SIGNAL RECOMPUTE. It never re-runs tests;
# husky's `test:lint-staged` remains the GREEN confirmation. For each staged
# test file that is new/modified at HEAD, it computes the set of CURRENT tests
# (working-tree content) and the set that existed at HEAD, then demands a
# matching valid RED only for tests whose fullName is NEW at HEAD. Edits,
# renames, and refactors of tests already present at HEAD are out of scope and
# never demand a fresh RED.
#
# Scope is driven entirely by the signal helper's emitted current-test set.
# Tests with dynamic titles (template-literal/computed names, test.each rows
# templated with substitutions) emit NO signal from the helper, so they never
# appear in the current-test set and are therefore EXEMPT by construction: an
# uncomputable identity yields no RED demand, matching the SPEC's fail-open
# posture for uncomputable identity and its "edits/refactors never demand a
# RED" spirit. A new dynamic-title test passing on first run is not blocked.
#
# Type-only tests are EXEMPT for a distinct, principled reason: the helper tags
# each test kind=type-only when its assertions are all type-level (expectTypeOf
# /assertType, or a `@ts-expect-error` proof) with no runtime expectation. Such
# a test has no runtime failure mode, so there is no runtime red-green for this
# gate to verify; the `tsc` Quality Gate step enforces it instead. This is the
# correctly-keyed exemption (no runtime assertion), as opposed to the
# dynamic-title carve-out above, which is keyed to uncomputable identity.
#
# Emergent-subject tests are EXEMPT too: the RED demand is scoped to the
# DETERMINISTIC surface via the determinism classifier
# (.gaia/scripts/classifier/classify-determinism.mjs). A test whose subject is
# clock-/entropy-/I-O-bound or tree-dependent (component interaction, async,
# layout, E2E) has no stable failing-then-passing run to observe, so demanding a
# RED produces theater. Such a file is skipped; the deterministic surface still
# demands its RED. See the carve-out block below for the binding and its
# err-EMERGENT, non-tightening fail-open.
#
# Fail-open vs fail-closed (threat model: a cooperative-but-fallible agent):
#   - git / jq / node unavailable  -> exit 0 (allow). Sibling-hook posture.
#   - a staged test file the helper cannot parse (mid-edit syntax error)
#     -> that file is skipped, never denied (husky's GREEN gate and the
#        agent's own run surface the syntax error). Fail-open.
#   - the determinism classifier unavailable or erroring -> the carve-out
#     does NOT fire; the file falls back to the pre-carve RED demand. This keeps
#     the deterministic path intact and never relaxes the gate on uncertainty.
#   - the deny path is fail-closed ONLY for the clean case: a parseable
#     new-at-HEAD passing test with no matching valid RED in the ledger that the
#     classifier does not label emergent.
#
# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null) so a
# transient failure can never crash the hook into a default-allow that skips
# the gate for the clean case, nor a default-deny that blocks honest work.
set -uo pipefail

input=$(cat)

# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literal below satisfies, live in .claude/hooks/lib/jq-availability.sh.
# No errexit bracket around the source, unlike the armed hooks that run under
# `set -e`: this one deliberately does not, per the header above.
#
# The literal is `git`, read off this gate's own command-position scan below,
# which requires the segment's command word to be `git` AND the segment to carry
# a `commit` token. Either is a necessary condition, and naming the command word
# alone is the narrower refusal, the same choice block-no-verify.sh makes
# against the same predicate. Its ABSENCE proves the call is not a commit and it
# is allowed; presence is not proof of membership, and that over-deny is the
# safe direction. What it cannot reach is a spelling the shell assembles
# (`g\it commit`), which the arm's own header already names as the accepted
# residual.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: red-verify-commit-check.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the RED-verify commit gate' "$input" tool_input 'git'

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Avoid the name `command`: it would shadow bash's `command` builtin and break
# later `command -v ...` guards.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# ---------------------------------------------------------------------------
# Command-position match for `git commit`. Reuse the anchored-segment technique
# from block-no-verify.sh / pr-merge-audit-check.sh: split on pipeline
# separators so every segment begins at a command word, strip leading env-var
# assignments to expose it, and act only when that word is `git` AND the
# segment carries a `commit` subcommand token. This avoids false positives on
# `git commit` inside a quoted message, heredoc, or grep pattern.
# ---------------------------------------------------------------------------

# Fast path: short-circuit when `git` is not an invoked command word anywhere.
[[ "$cmd" =~ (^|[[:space:]&;|()])git([[:space:]]|$) ]] || exit 0

# The directory a segment's `git -C <dir>` names, read only from BETWEEN `git`
# and the subcommand word. Past the subcommand the flag belongs to the
# subcommand and names no directory: `git commit -C <commit>` reuses that
# commit's message, so reading it as a directory aims every read below at a
# path named for a commit, where git answers nothing and the whole check drops
# out into a silent pass. Git applies multiple global `-C` cumulatively with
# the LAST winning, so the walk keeps the last rather than stopping at the
# first. Echoes nothing when the segment carries none.
#
# Honest limit: the words are split on whitespace, never read as the shell
# would expand them, so a `-C` whose path is quoted with a space in it, or
# carries an unexpanded variable or `~`, is not recovered. That leaves the
# directory empty, which falls back to the payload cwd below -- the tree this
# gate already read -- rather than to a wrong one.
git_segment_c() {
  local -a w
  local i=0 n t out="" seen_git=0
  read -ra w <<<"$1"
  n=${#w[@]}
  while [ "$i" -lt "$n" ]; do
    t="${w[$i]}"
    if [ "$seen_git" -eq 1 ]; then
      case "$t" in
        -C) out="${w[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
        -c | --git-dir | --work-tree | --namespace) i=$((i + 2)); continue ;;
        -*) ;;
        *) break ;;
      esac
    elif [ "$t" = git ]; then
      seen_git=1
    fi
    i=$((i + 1))
  done
  case "$out" in
    \"*\") out="${out#\"}"; out="${out%\"}" ;;
    \'*\') out="${out#\'}"; out="${out%\'}" ;;
  esac
  printf '%s' "$out"
}

saw_commit=0
commit_c=""
while IFS= read -r seg; do
  # Command word = first token after leading whitespace + env-var assignments.
  seg_cmd=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  [[ "$seg_cmd" =~ ^git([[:space:]]|$) ]] || continue
  if [[ "$seg" =~ (^|[[:space:]])commit([[:space:]]|$) ]]; then
    saw_commit=1
    commit_c=$(git_segment_c "$seg_cmd")
  fi
done < <(printf '%s\n' "$cmd" | tr '|&;()' '\n')

[ "$saw_commit" -eq 1 ] || exit 0

# ---------------------------------------------------------------------------
# Repo-scope guard: a `git -C ../other commit` targets a different repo whose
# RED ledger is not ours, so allow it. Fail-closed (enforce) on any ambiguity.
#
# This hook's libraries are rooted at its own on-disk location, the way the
# main-root resolver below already is, and never at the process working
# directory. A bare `.claude/hooks/lib/...` test is false from anywhere under
# the repository root, and the fail-open degrades below are written for a
# BROKEN library: they cannot tell that case from a moved working directory, so
# a bare test would let a single `cd` disarm this gate with no diagnostic.
# ---------------------------------------------------------------------------
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _lib_dir=''
[ -n "$_lib_dir" ] && [ -f "$_lib_dir/repo-scope.sh" ] && . "$_lib_dir/repo-scope.sh"
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# ---------------------------------------------------------------------------
# The checkout this commit acts on. A home verdict covers this REPOSITORY, and
# every linked worktree of it is this repository, so a home command can still
# be aimed at a checkout that is not this hook's: `git -C <worktree> commit`,
# or a leading `cd <worktree> &&`. The staged set, the HEAD blob, and the
# per-tree ledger below all belong to that checkout, so each is read from it
# rather than from wherever this process happens to sit.
#
# The precedence is the one block-main-destructive-git.sh's branch_dir uses:
# the segment's own `-C`, else the leading `cd` the repo-scope verdict
# publishes, else the payload cwd the resolver validates further down. That
# verdict publishes the `cd` target only once it resolved as this repository,
# so an unresolvable one never reaches here.
# ---------------------------------------------------------------------------
payload_cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
cmd_dir="${commit_c:-${GAIA_REPO_SCOPE_LEAD_CD:-}}"
# A relative target resolves against the acting agent's own directory, the way
# the payload cwd itself is read, never against this process's, which nobody
# chose.
case "$cmd_dir" in
  '' | /*) ;;
  *)
    if [[ "$payload_cwd" == /* ]]; then
      cmd_dir="$payload_cwd/$cmd_dir"
    else
      cmd_dir="$PWD/$cmd_dir"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Shared RED-ledger lib: ledger path, repo-relative normalization, and the
# signal-helper wrapper. Without it we cannot compute identity, so fail-open.
# ---------------------------------------------------------------------------
[ -n "$_lib_dir" ] && [ -f "$_lib_dir/red-ledger.sh" ] && . "$_lib_dir/red-ledger.sh"
type red_ledger_path >/dev/null 2>&1 || exit 0
type red_ledger_signals >/dev/null 2>&1 || exit 0
type red_ledger_signal_script >/dev/null 2>&1 || exit 0

command -v git >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0

# This hook only enforces where git answers (a real work tree at pwd).
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The shared main-root resolver, sourced from this hook's own checkout via
# BASH_SOURCE (never process cwd): the RED ledger is per-tree state, so its
# root is the ACTING tree, not wherever this hook process happens to sit.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0

# The acting agent's working directory: the payload cwd when it is absolute
# and resolves to a checkout, this hook's process cwd otherwise. "Resolves to
# a checkout" is the resolver's own question, so it is asked by calling it
# rather than by a raw git call this hook writes itself. Payload cwd is
# measured, not contracted, and only established on PreToolUse, so the
# fallback is mandatory.
source_cwd="$PWD"
if [[ "$payload_cwd" == /* ]] && gaia_resolve_tree_root "$payload_cwd" >/dev/null 2>&1; then
  source_cwd="$payload_cwd"
fi
# The command's own target outranks both: that is the checkout the commit lands
# in, while the payload cwd is only where the agent was standing when it ran
# the command. A target the resolver cannot answer for is left behind rather
# than enforced against, which keeps the reads on the directory this gate would
# have read anyway.
if [ -n "$cmd_dir" ] && gaia_resolve_tree_root "$cmd_dir" >/dev/null 2>&1; then
  source_cwd="$cmd_dir"
fi
tree_root="$(gaia_resolve_tree_root "$source_cwd" 2>/dev/null)" || exit 0

# ---------------------------------------------------------------------------
# Staged test files new/modified at HEAD in the ACTING tree, filtered to the
# vitest include glob (app/**/*.test.ts|tsx, confirmed against vitest.config.ts:
# './app/**/*.test.{ts,tsx}').
# A pure deletion/rename-away cannot add a new passing test, so --diff-filter=ACM.
#
# `-z` is what makes the glob filter below reachable at all: without it git
# C-quotes a path carrying a non-ASCII byte, so `app/café.test.ts` arrives as
# `"app/caf\303\251.test.ts"`, matches no `app/*` case, and the gate exits
# having verified nothing. The records are translated back to newlines because
# the consumer reads them from a here-doc; a path holding a literal newline is
# the separate, far rarer class .gaia/scripts/lint-git-path-quoting.sh declares
# out of its scope.
# ---------------------------------------------------------------------------
staged=$(git -C "$tree_root" diff --cached --name-only -z --diff-filter=ACM 2>/dev/null | tr '\0' '\n' || true)
[ -n "$staged" ] || exit 0

ledger=$(red_ledger_path "$tree_root") || exit 0
signal_script=$(red_ledger_signal_script)

# ---------------------------------------------------------------------------
# Determinism carve-out: the RED demand is scoped to the DETERMINISTIC surface.
# A test whose subject is emergent (clock-/entropy-/I-O-bound or tree-dependent:
# component interaction, async, layout, E2E) has no stable failing-then-passing
# run to observe, so forcing a RED onto it produces theater. Such a test commits
# with NO RED demand; the deterministic surface (pure utils, service parsers,
# spec-derivable hooks) still demands and gets a natural RED.
#
# Binding: classify the TEST FILE ITSELF with the determinism classifier
# (.gaia/scripts/classifier/classify-determinism.mjs). The classifier already
# carries every emergent signal this gate cares about and is biased err-EMERGENT:
#   - a `.tsx` test under app/components/** (component interaction) and a
#     .playwright/** E2E test fall outside its STRICT candidate path -> emergent;
#   - a test calling the a11y helpers (expectNoA11yViolations / runAxe) -> emergent;
#   - a test reading the clock/entropy/I-O in its own body -> emergent.
# The classifier's internal err-EMERGENT bias supplies the "treat as emergent
# when we cannot prove the subject deterministic" posture: anything it cannot
# confidently prove deterministic it returns emergent, and an emergent verdict
# relaxes the RED demand for that file.
#
# Fail-open / non-tightening: when the classifier is unavailable or errors, the
# gate falls back to its pre-carve behavior (demand the RED) so the deterministic
# path is never broken and the existing fail-open posture is preserved exactly.
# The carve-out RELAXES the demand only on an AFFIRMATIVE emergent verdict; it
# never tightens it.
# Rooted through the same script-derived scripts directory the main-root load
# above resolves, never a bare cwd-relative literal: the absence test below
# feeds a fail-open that demands the RED, so a cwd below the repository root
# would silently retire the emergent carve-out rather than report anything.
classifier_script="$gaia_scripts/classifier/classify-determinism.mjs"

# Echo "emergent" only when the classifier affirmatively classifies the given
# repo-relative test path emergent; echo nothing otherwise (missing helper,
# non-zero exit, unparseable JSON, or a strict verdict). A non-empty (emergent)
# answer relaxes the RED demand for that file.
test_subject_is_emergent() {
  local rel="$1"
  [ -f "$classifier_script" ] || return 0
  local out
  # Run from the ACTING TREE, not the process working directory. `$rel` is
  # repo-relative and stays that way, because the classifier's own path rules
  # read it (a .tsx under app/components/**, a spec under .playwright/**), so
  # handing it an absolute path would change its verdict. What it must not do is
  # resolve that path against a working directory nobody chose: the file read
  # then fails, the classifier's deliberate err-EMERGENT bias returns emergent,
  # and an emergent verdict RETIRES the RED demand for the file. That is a
  # silent disarm of this gate from any subdirectory, in the same direction as
  # a missing library. The `cd` is inside a command substitution, so it never
  # persists into the rest of this hook.
  out=$( cd "$tree_root" && node "$classifier_script" "$rel" 2>/dev/null ) || return 0
  [ -n "$out" ] || return 0
  printf '%s' "$out" \
    | jq -r 'select((.classification // "") == "emergent") | "emergent"' \
        2>/dev/null \
    | head -1
}

# Collect offenders as "file\tfullName" lines.
offenders=""

while IFS= read -r path; do
  [ -n "$path" ] || continue
  # vitest include glob is './app/**/*.test.{ts,tsx}' (vitest.config.ts). In a
  # case statement `*` already spans slashes, so `app/*.test.ts` matches any
  # depth under app/. Match the app/ prefix AND a .test.ts/.tsx suffix.
  case "$path" in
    app/*.test.ts | app/*.test.tsx) ;;
    *) continue ;;
  esac

  rel=$(red_ledger_repo_rel "$path")

  # Carve-out: an emergent-subject test commits without a RED demand. Skip the
  # whole file when the classifier affirmatively labels it emergent; the
  # deterministic surface falls through to the RED check unchanged.
  [ -n "$(test_subject_is_emergent "$rel")" ] && continue

  # Current tests: helper over the working-tree (staged) file content on disk.
  # Parse failure (mid-edit syntax error) -> skip this file (fail-open).
  current_ndjson=""
  # From the acting tree, for the reason the classifier call above gives: this
  # helper reads the staged file from disk at the repo-relative path, so from a
  # subdirectory it finds nothing, and "no signals" is a `continue` -- the file
  # leaves the offender scan and the commit passes ungated.
  current_ndjson=$( cd "$tree_root" && red_ledger_signals "$rel" 2>/dev/null ) || { continue; }
  # No emitted tests (empty file, only dynamic-title tests, or no-tests file):
  # nothing in scope for this file.
  [ -n "$current_ndjson" ] || continue

  # HEAD tests: feed the HEAD blob (`git show HEAD:<path>`) through the helper
  # via --stdin. The shared red_ledger_signals reads from disk only, so call the
  # helper script directly here with --stdin to parse HEAD content rather than
  # the staged working-tree file. A new-at-HEAD file yields empty HEAD content
  # -> every current test is new. If HEAD content is unparseable we cannot prove
  # a test pre-existed; treat the HEAD set as empty (conservative: more tests
  # look new), but a genuinely new file is the common case on this path.
  head_src=$(git -C "$tree_root" show "HEAD:$rel" 2>/dev/null || true)
  head_fullnames=""
  if [ -n "$head_src" ]; then
    # From the acting tree, like the two reads above: $signal_script is the bare
    # repo-relative literal red_ledger_signal_script returns, so from a
    # subdirectory node cannot find it, `|| true` swallows the failure, and
    # head_fullnames stays empty. Empty means "nothing pre-existed at HEAD", so
    # every current test reads as new-at-HEAD and an ordinary edit to a test
    # that has always been there is denied for want of a RED it never owed.
    head_ndjson=$( cd "$tree_root" && printf '%s' "$head_src" \
      | node "$signal_script" "$rel" --stdin 2>/dev/null || true)
    if [ -n "$head_ndjson" ]; then
      head_fullnames=$(printf '%s\n' "$head_ndjson" \
        | jq -r '.fullName // empty' 2>/dev/null || true)
    fi
  fi

  # For each CURRENT test, decide new-at-HEAD, then require a matching RED.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    full=$(printf '%s' "$line" | jq -r '.fullName // empty' 2>/dev/null || true)
    sig=$(printf '%s' "$line" | jq -r '.signal // empty' 2>/dev/null || true)
    kind=$(printf '%s' "$line" | jq -r '.kind // empty' 2>/dev/null || true)
    [ -n "$full" ] && [ -n "$sig" ] || continue

    # Type-only test (all assertions type-level, no runtime expectation): it
    # has no runtime failure mode, so there is no runtime red-green for this
    # gate to demand. The `tsc` Quality Gate step enforces its correctness;
    # demanding a runtime RED here would be unsatisfiable. An absent kind (an
    # older signal helper) falls through to runtime enforcement, the safe
    # default.
    [ "$kind" = "type-only" ] && continue

    # New-at-HEAD test? Present-at-HEAD fullNames are out of scope (edits,
    # renames, refactors of an existing test never demand a fresh RED), even
    # when their signal changed.
    if [ -n "$head_fullnames" ] \
       && grep -qxF -- "$full" <<<"$head_fullnames"; then
      continue
    fi

    # In scope: require >=1 ledger line with schema 1, this file, this
    # fullName, and this CURRENT signal. A matching RED at a stale signal
    # (the test's executed content edited after its RED; a comment reword
    # does not change the signal) does not count -> the edit-to-pass hole is
    # closed. A missing ledger file means zero matches -> deny.
    matched=0
    if [ -f "$ledger" ]; then
      matched=$(jq -r --arg f "$rel" --arg n "$full" --arg s "$sig" '
        select((.schema // 0) == 1
          and (.file // "") == $f
          and (.fullName // "") == $n
          and (.signal // "") == $s)
        | "x"' "$ledger" 2>/dev/null \
        | head -1 | grep -c x 2>/dev/null || true)
    fi
    [ -z "$matched" ] && matched=0

    if [ "$matched" -eq 0 ]; then
      offenders="${offenders}${rel}	${full}
"
    fi
  done <<EOF
$current_ndjson
EOF
done <<EOF
$staged
EOF

# ---------------------------------------------------------------------------
# Decision: allow when no offenders; otherwise deny, naming each offender.
# ---------------------------------------------------------------------------
if [ -z "$offenders" ]; then
  exit 0
fi

# Build a human-readable list of "  • file › fullName" lines.
offender_list=$(printf '%s' "$offenders" \
  | while IFS=$'\t' read -r f n; do
      [ -n "$f" ] || continue
      printf '  \xe2\x80\xa2 %s \xe2\x80\xba %s\n' "$f" "$n"
    done)

reason="TDD RED-verification: a new test has no observed failing run (RED) on record at its current content.

$offender_list

These tests are new at HEAD and pass now, but no matching RED was recorded for the current test body. A passing test that was never seen failing first does not prove the test can fail; that is the gap this gate closes.

To unblock:
  1. Run \`pnpm test --run\` and confirm the test FAILS (RED) before the change that makes it pass.
  2. Then make the change that turns it green and commit.

A RED is bound to the test's comment-free content: rewording a comment inside a test leaves the signal unchanged and the RED still counts, but any change to what the test executes invalidates that RED, so a fresh failing run must be observed for the current body. Edits, renames, and refactors of tests already present at HEAD are out of scope and never demand a RED."

# --arg safely escapes $reason; never interpolate dynamic values into the JSON.
jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'

exit 0
