#!/usr/bin/env bash
# PostToolUse Bash hook: OBSERVE-AND-RECORD half of the RED-verification gate.
#
# When the agent runs a one-shot vitest run (`pnpm test --run [scope]`), this
# hook re-invokes vitest with the json reporter on the same scope, reads the
# per-test results, and appends every GENUINELY-FAILING test to the
# RED-observation ledger (.gaia/local/red-ledger/observations.jsonl). The
# companion check hook (red-verify-commit-check.sh) later reads that ledger to
# decide whether a `git commit` introducing a now-passing new test may land.
#
# This hook ONLY observes. It never blocks, never emits a deny, and ALWAYS
# exits 0, a missing capture only means the check may later deny, which is the
# safe direction. It mirrors the merge-audit gate's split of "observe and
# record" from "deny the consequential action."
#
# Valid RED = a per-test `assertionResults[].status == "failed"`. A file-level
# collection/compile error (file status "failed", empty assertionResults,
# non-empty message, no test body ran) is NOT a valid RED and is skipped.
#
# Test seam: set RED_CAPTURE_JSON_OVERRIDE to an existing json file to feed
# canned vitest output and skip the real vitest re-run (used by the bats suite
# so it stays fast and offline). Production never sets it.
#
# -e is intentionally omitted: every fallible command is individually guarded so
# the hook can never abort before its unconditional exit 0.
set -uo pipefail

# --- guards: jq present, this is a Bash tool call -----------------------------
input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$cmd" ] || exit 0

# --- scope match: a `(pnpm|npm) [run] test … --run …` invocation --------------
# Reuse block-bare-test.sh's ANCHORED detection: walk pipeline segments, strip
# leading env-var prefixes, and act only when `pnpm`/`npm` is the segment's
# command word AND `test` is the script position, requiring the POSITIVE
# `--run` case scoped to that same segment (a bare run is blocked upstream by
# block-bare-test.sh and never reaches a passing PostToolUse). Command TEXT that
# merely mentions the phrase (a commit message, a `--body` string) is not an
# invocation, so a spurious full-suite vitest re-run never fires on prose.
# `test:ci` / `test:lint-staged` carry a `test:` token, not a bare `test`, so
# the `test([[:space:]]|$)` boundary skips them, aligned with the bare-test hook.
# $test_seg is the matched invocation with its env prefix stripped; the scope
# parse below reads it (not the whole command) so only that call's args count.
test_seg=""
while IFS= read -r seg; do
  seg_cmd=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  [[ "$seg_cmd" =~ ^(pnpm|npm)[[:space:]]+(run[[:space:]]+)?test([[:space:]]|$) ]] || continue
  [[ "$seg_cmd" =~ (^|[[:space:]])--run([[:space:]]|$) ]] || continue
  test_seg="$seg_cmd"
  break
done < <(printf '%s\n' "$cmd" | tr '|&;()' '\n')
[ -n "$test_seg" ] || exit 0

# --- source the shared lib (ledger path, repo-rel, signal helper) -------------
[ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh
type red_ledger_path >/dev/null 2>&1 || exit 0

# The shared main-root resolver, sourced from this hook's own checkout via
# BASH_SOURCE (never process cwd): the RED ledger is per-tree state, so its
# root is the ACTING tree, not wherever this hook process happens to sit.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0

# The acting agent's working directory: the payload cwd when it is absolute
# and resolves to a checkout, this hook's process cwd otherwise (mirrors
# block-worktree-path-mismatch.sh's own payload-cwd idiom). Payload cwd is
# measured, not contracted, and only established on PreToolUse/PostToolUse,
# so the fallback is mandatory.
payload_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || echo "")
source_cwd="$PWD"
if [[ "$payload_cwd" == /* ]] && git -C "$payload_cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
  source_cwd="$payload_cwd"
fi
tree_root="$(gaia_resolve_tree_root "$source_cwd" 2>/dev/null)" || exit 0

ledger=$(red_ledger_path "$tree_root") || exit 0
ledger_dir=$(dirname "$ledger")
tmp_dir="${ledger_dir}/.tmp"

# --- obtain structured json: canned override, or a scoped vitest re-run -------
json_file=""
cleanup_json=0

if [ -n "${RED_CAPTURE_JSON_OVERRIDE:-}" ] && [ -f "${RED_CAPTURE_JSON_OVERRIDE}" ]; then
  json_file="${RED_CAPTURE_JSON_OVERRIDE}"
else
  # Parse the matched invocation ($test_seg) for a scope arg (a path/dir/pattern)
  # so the json re-run is bounded to the same files the agent targeted. Take the
  # tokens AFTER the `test` token, dropping recognizable flags/options.
  scope=$(printf '%s\n' "$test_seg" | awk '
    {
      seen = 0
      for (i = 1; i <= NF; i++) {
        if (!seen) { if ($i == "test") seen = 1; continue }
        tok = $i
        if (tok ~ /^-/) continue                 # flags: --run, --reporter, -t, …
        if (tok == "run" || tok == "exec") continue
        if (tok ~ /=/) continue                  # --opt=value already caught by ^-, but be safe
        print tok
      }
    }')

  # No scope parsed: SKIP the capture (re-run no tests) rather than re-running
  # the whole vitest suite. A full-suite re-run on every unscoped `test --run`
  # is an unbounded worst-case wall-clock cost. Skipping does not break the
  # design: a missing capture only means the commit check may later deny, which
  # is the safe direction (the same posture as the override-absent and
  # parse-failure paths). A scoped invocation is unaffected: $scope carries the
  # path/pattern and the re-run below stays bounded to it. Emptiness is tested on
  # a whitespace-stripped copy so $scope itself keeps its word-split tokens.
  [ -n "$(printf '%s' "$scope" | tr -d '[:space:]')" ] || exit 0

  mkdir -p "$tmp_dir" 2>/dev/null || true
  json_file=$(mktemp "${tmp_dir}/vitest-XXXXXX.json" 2>/dev/null || echo "")
  [ -n "$json_file" ] || exit 0
  cleanup_json=1

  # Re-invoke vitest directly (not `pnpm test`) with the json reporter. Using
  # `pnpm exec vitest` avoids the project `test` script, passes json cleanly,
  # and dodges block-bare-test.sh (different command word), and this is a hook
  # subprocess, not a Bash-tool call, so no PreToolUse hook intercepts it.
  # shellcheck disable=SC2086 # $scope is an intentional word-split arg list.
  pnpm exec vitest --run --reporter=json --outputFile="$json_file" $scope \
    >/dev/null 2>&1 || true

  # If vitest produced no parseable json (binary missing, etc.), bail silently.
  if [ ! -s "$json_file" ] || ! jq -e . "$json_file" >/dev/null 2>&1; then
    [ "$cleanup_json" -eq 1 ] && rm -f "$json_file" 2>/dev/null || true
    exit 0
  fi
fi

# --- parse per-test failures, attach signals, append to the ledger ------------
mkdir -p "$ledger_dir" 2>/dev/null || true
observed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

# Walk each file (testResults[]). Emit a TSV line "file<TAB>fullName<TAB>kind"
# per genuinely-failing per-test result. Collection-error files (status failed,
# zero assertionResults, non-empty message, no test body ran) yield nothing.
# failureKind is informational: a missing-implementation runtime error
# (TypeError/ReferenceError/is not a function/is not defined) → "runtime",
# otherwise "assertion".
failures=$(jq -r '
  .testResults[]?
  | . as $f
  | select((.assertionResults | length) > 0)
  | .name as $name
  | .assertionResults[]
  | select(.status == "failed")
  | ([ ($name // ""),
       (.fullName // ""),
       ( (.failureMessages // [] | join(" "))
         | if test("TypeError|ReferenceError|is not a function|is not defined")
           then "runtime" else "assertion" end )
     ] | @tsv)
' "$json_file" 2>/dev/null || echo "")

if [ -n "$failures" ]; then
  # Cache signal lookups per file so each file is parsed once.
  cached_file=""
  cached_signals=""
  while IFS=$'\t' read -r raw_file full_name kind; do
    [ -n "$raw_file" ] || continue
    [ -n "$full_name" ] || continue

    rel_file=$(red_ledger_repo_rel "$raw_file")
    [ -n "$rel_file" ] || continue

    # Recompute the file's {fullName → signal} map once and reuse it.
    if [ "$rel_file" != "$cached_file" ]; then
      cached_file="$rel_file"
      cached_signals=$(red_ledger_signals "$rel_file" 2>/dev/null || echo "")
    fi
    [ -n "$cached_signals" ] || continue

    # Match the failing fullName to the helper's signal output. Exact-match the
    # fullName field; skip (fail-open) when no signal is found, never invent one.
    signal=$(printf '%s\n' "$cached_signals" | jq -r --arg fn "$full_name" \
      'select(.fullName == $fn) | .signal' 2>/dev/null | head -n1)
    [ -n "$signal" ] || continue

    # Build the ledger line safely with jq -n --arg (never string-concat json).
    jq -c -n \
      --argjson schema 1 \
      --arg file "$rel_file" \
      --arg fullName "$full_name" \
      --arg signal "$signal" \
      --arg failureKind "$kind" \
      --arg observedAt "$observed_at" \
      '{schema: $schema, file: $file, fullName: $fullName, signal: $signal, failureKind: $failureKind, observedAt: $observedAt}' \
      >> "$ledger" 2>/dev/null || true
  done <<< "$failures"
fi

# --- cleanup; never block --------------------------------------------------
[ "$cleanup_json" -eq 1 ] && rm -f "$json_file" 2>/dev/null || true

exit 0
