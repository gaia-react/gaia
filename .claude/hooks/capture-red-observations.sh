#!/usr/bin/env bash
# PostToolUse Bash hook: OBSERVE-AND-RECORD half of the RED-verification gate.
#
# When the agent runs a one-shot vitest run (`pnpm test --run [scope]`), this
# hook re-invokes vitest with the json reporter on the same scope, reads the
# per-test results, and appends every GENUINELY-FAILING test to the
# RED-observation ledger (.gaia/local/red-ledger/<tree_key>/observations.jsonl;
# <tree_key> identifies the working tree, printed by
# `bash .gaia/scripts/main-root-lib.sh --tree-key`). The companion check hook
# (red-verify-commit-check.sh) later reads that ledger to decide whether a
# `git commit` introducing a now-passing new test may land.
#
# This hook ONLY observes. It never emits a deny and ALWAYS exits 0; a missing
# capture only means the check may later deny, which is the safe direction. It
# mirrors the merge-audit gate's split of "observe and record" from "deny the
# consequential action." The one thing it does say out loud is an unusable
# package registry or descriptor (SPEC-092 C5): it records nothing and emits a
# PostToolUse `{"decision":"block","reason":...}` so the session sees why, rather
# than going quiet while the commit gate later denies for want of a RED.
#
# Package scope (SPEC-092): the test run may name a package three ways, and the
# hook recognizes all of them. `pnpm test --run frontend/app/x.test.ts` from the
# repo root (the root proxy script), `pnpm -C frontend test --run app/x.test.ts`
# or `pnpm --filter <name> test --run app/x.test.ts` from anywhere, and
# `pnpm test --run app/x.test.ts` from inside the package directory. Each scope
# path is resolved to the package that owns it (the registry's longest-prefix
# owner), the json re-run happens in that package's directory with the
# package-relative scope, and the ledger key stays REPO-relative
# (`frontend/app/x.test.ts`), the key red-verify-commit-check.sh computes for
# the staged path.
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

command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$command" ] || exit 0

# --- scope match: a `(pnpm|npm) [run] test … --run …` invocation --------------
# ANCHORED detection: walk pipeline segments, strip leading env-var prefixes,
# and act only when `pnpm`/`npm` is the segment's command word AND `test` is
# the script position (after any `-C <dir>`, `--dir <dir>`, `--filter <name>`, or
# `-F <name>` option), requiring the POSITIVE `--run` case scoped to that same
# segment (a bare run without `--run` is simply not captured here, and a
# `--run` naming no test path is skipped below with a diagnostic;
# red-verify-commit-check.sh names `pnpm test --run <test-file>` as the
# recovery when its gate denies for a missing RED observation). Command TEXT
# that merely mentions the phrase (a commit message, a `--body` string) is
# not an invocation, so a
# spurious full-suite vitest re-run never fires on prose. `test:ci` /
# `test:lint-staged` carry a `test:` token, not a bare `test`, so the
# `test([[:space:]]|$)` boundary skips them.
# $test_segment is the matched invocation with its env prefix stripped; the scope
# parse below reads it (not the whole command) so only that call's args count.
test_segment=""
while IFS= read -r segment; do
  segment_command=$(printf '%s' "$segment" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  [[ "$segment_command" =~ ^(pnpm|npm)[[:space:]]+(((-C|--dir|--filter|-F)[[:space:]]+[^[:space:]]+|(--dir|--filter)=[^[:space:]]+)[[:space:]]+)*(run[[:space:]]+)?test([[:space:]]|$) ]] || continue
  [[ "$segment_command" =~ (^|[[:space:]])--run([[:space:]]|$) ]] || continue
  test_segment="$segment_command"
  break
done < <(printf '%s\n' "$command" | tr '|&;()' '\n')
[ -n "$test_segment" ] || exit 0

# --- source the shared lib (ledger path, repo-rel, signal helper) -------------
# Rooted at this file's own directory, the same way the main-root load below is
# and never at the process working directory: a bare test is false from anywhere
# under the repository root, and the `type` degrade below cannot distinguish a
# moved working directory from a missing library, so a `cd` alone would stop
# this hook recording RED observations at all.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=''
[ -n "$_library_directory" ] && [ -f "$_library_directory/red-ledger.sh" ] && . "$_library_directory/red-ledger.sh"
type red_ledger_path >/dev/null 2>&1 || exit 0

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
# measured, not contracted, and only established on PreToolUse/PostToolUse,
# so the fallback is mandatory.
payload_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || echo "")
source_cwd="$PWD"
if [[ "$payload_cwd" == /* ]] && gaia_resolve_tree_root "$payload_cwd" >/dev/null 2>&1; then
  source_cwd="$payload_cwd"
fi
tree_root="$(gaia_resolve_tree_root "$source_cwd" 2>/dev/null)" || exit 0

ledger=$(red_ledger_path "$tree_root") || exit 0
ledger_directory=$(dirname "$ledger")
temporary_directory="${ledger_directory}/.tmp"

# --- package registry: which package owns the scope --------------------------
# Loaded from the ACTING tree through the library rooted at this hook's own
# location. An unusable registry or descriptor (or a library that will not load)
# records nothing and tells the session why, instead of exiting silently.
block_with_reason() {
  jq -n --arg r "$1" '{decision: "block", reason: $r}' 2>/dev/null || true
  exit 0
}
[ -n "$_library_directory" ] && [ -f "$_library_directory/gaia-packages.sh" ] && . "$_library_directory/gaia-packages.sh"
if ! type gaia_packages_load >/dev/null 2>&1; then
  block_with_reason "RED capture: cannot load .claude/hooks/lib/gaia-packages.sh, so no RED was recorded for this test run. Next step: restore .claude/hooks/lib/gaia-packages.sh from the GAIA release and re-run the test."
fi
packages_status=0
gaia_packages_load "$tree_root" || packages_status=$?
if [ "$packages_status" -ne 0 ]; then
  block_with_reason "RED capture recorded nothing: ${GAIA_PACKAGES_ERROR}"
fi

# The `-C`, `--dir`, `--filter`, and `-F` options the matched invocation carries
# before its `test` script word. Walks the tokens up to `test`; a quoted value
# with a space is not modeled, like the rest of this hook's parsing.
option_directory=''
option_filter=''
read -ra segment_tokens <<<"$test_segment"
token_index=1
while [ "$token_index" -lt "${#segment_tokens[@]}" ]; do
  token="${segment_tokens[$token_index]}"
  case "$token" in
    test) break ;;
    -C | --dir)
      token_index=$((token_index + 1))
      option_directory="${segment_tokens[$token_index]:-}"
      ;;
    --dir=*) option_directory="${token#--dir=}" ;;
    --filter | -F)
      token_index=$((token_index + 1))
      option_filter="${segment_tokens[$token_index]:-}"
      ;;
    --filter=*) option_filter="${token#--filter=}" ;;
  esac
  token_index=$((token_index + 1))
done

# The directory the scope paths are written relative to: the `-C`/`--dir`
# directory, the `--filter` package's directory, else the agent's own working
# directory. Physical, so it compares against $tree_root (also physical).
scope_base="$source_cwd"
if [ -n "$option_directory" ]; then
  case "$option_directory" in
    /*) scope_base="$option_directory" ;;
    *) scope_base="$source_cwd/$option_directory" ;;
  esac
elif [ -n "$option_filter" ]; then
  filter_path=$(gaia_package_dir "$option_filter") || filter_path=''
  if [ -z "$filter_path" ]; then
    jq -n --arg c "RED capture skipped: the --filter name '$option_filter' is not a registered package in .gaia/packages.json, so no RED was recorded. Run the test with pnpm -C <package dir> test --run <test-file>, or pnpm test --run <repo-relative test-file> from the repo root." \
      '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}' 2>/dev/null || true
    exit 0
  fi
  if [ "$filter_path" = . ]; then
    scope_base="$tree_root"
  else
    scope_base="$tree_root/$filter_path"
  fi
fi
scope_base=$(cd "$scope_base" 2>/dev/null && pwd -P) || scope_base="$source_cwd"

# --- obtain structured json: canned override, or a scoped vitest re-run -------
json_file=""
cleanup_json=0

if [ -n "${RED_CAPTURE_JSON_OVERRIDE:-}" ] && [ -f "${RED_CAPTURE_JSON_OVERRIDE}" ]; then
  json_file="${RED_CAPTURE_JSON_OVERRIDE}"
else
  # Parse the matched invocation ($test_segment) for a scope arg (a path/dir/pattern)
  # so the json re-run is bounded to the same files the agent targeted. Take the
  # tokens AFTER the `test` token, dropping recognizable flags/options.
  scope=$(printf '%s\n' "$test_segment" | awk '
    {
      seen = 0
      redir = 0
      for (i = 1; i <= NF; i++) {
        if (!seen) { if ($i == "test") seen = 1; continue }
        tok = $i
        # A shell redirection reaches the walk in two shapes: attached to its
        # target in one token (1>out.log, 2>/dev/null, <input, <<EOF, …), or
        # split by whitespace into the bare operator and a separate target
        # token (`2>` then `err.log`). The attached shape is caught below by
        # the `[<>]` filter; the spaced shape needs the operator recognized
        # on its own so the target that follows it (which carries no angle
        # bracket) is skipped too, rather than read as a scope path. `redir`
        # tracks that: set when the current token is bare-operator-shaped,
        # consumed on the very next token.
        #
        # The `|&;()` split above severs a `&`-carrying redirection (2>&1)
        # mid-token: it splits at the `&`, so only the operator head (2>)
        # reaches this segment and the rest becomes an orphan segment on its
        # own line, never matched into $test_segment. That head still lands here
        # as a token, but it is caught by the bare-operator arm just below
        # (which arms `redir`), not by the `[<>]` filter. Arming `redir` on
        # it is harmless: the split guarantees the head is the last token on
        # this line, so there is no following token for the armed lookahead
        # to wrongly consume.
        if (redir) { redir = 0; continue }
        if (tok ~ /^[0-9]*[<>]+$/) { redir = 1; continue }
        if (tok ~ /^-/) continue                 # flags: --run, --reporter, -t, …
        if (tok == "run" || tok == "exec") continue
        if (tok ~ /=/) continue                  # --opt=value already caught by ^-, but be safe
        # A test-scope path or glob never legitimately contains `<` or `>`,
        # so excluding any attached-form token that does is a safe,
        # shape-based filter.
        if (tok ~ /[<>]/) continue
        print tok
      }
    }')

  # No scope parsed: SKIP the capture (re-run no tests) rather than re-running
  # the whole vitest suite. A full-suite re-run on every unscoped `test --run`
  # is an unbounded worst-case wall-clock cost. The skip is announced, not
  # silent: a developer who watched a test fail on an unscoped run would
  # otherwise meet the commit check's denial later with nothing tying it to this
  # run. A scoped invocation is unaffected: $scope carries the path/pattern and
  # the re-run below stays bounded to it. Emptiness is tested on a
  # whitespace-stripped copy so $scope itself keeps its word-split tokens.
  # additionalContext rather than a printf: on PostToolUse, Claude Code sends
  # plain stdout and stderr to its debug log only, so a printed line would be as
  # silent as the bare exit.
  if [ -z "$(printf '%s' "$scope" | tr -d '[:space:]')" ]; then
    jq -n --arg c "RED capture skipped: this test run named no test file, so no failing (RED) result was recorded for the RED-verification commit gate. An unscoped run is not captured, because re-running the whole suite on every run is an unbounded cost. If a new test failed here and you need its RED on record, re-run it with a test path: pnpm test --run <test-file>" \
      '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}' 2>/dev/null || true
    exit 0
  fi

  # Resolve every scope token against the scope base. A token that lands inside
  # a registered package is rewritten package-relative and decides the re-run
  # directory (the package that owns the first such token); a token that lands
  # nowhere (a bare filter pattern) is kept as written. Nothing resolves: the
  # re-run stays in the scope base, as it always did.
  run_directory="$scope_base"
  run_scope=""
  resolved_package_path=""
  resolved_tokens=""
  # Globbing off: a scope like app/**/*.test.ts is vitest's to expand, not the shell's.
  set -f
  for scope_token in $scope; do
    scope_clean="$scope_token"
    while [ "${scope_clean#./}" != "$scope_clean" ]; do
      scope_clean="${scope_clean#./}"
    done
    case "$scope_clean" in
      /*) scope_absolute="$scope_clean" ;;
      *) scope_absolute="$scope_base/$scope_clean" ;;
    esac
    scope_repo_relative=""
    case "$scope_absolute" in
      "$tree_root"/*) scope_repo_relative="${scope_absolute#"$tree_root"/}" ;;
    esac
    owner_name=""
    [ -n "$scope_repo_relative" ] && owner_name=$(gaia_package_for_path "$scope_repo_relative")
    if [ -n "$owner_name" ]; then
      owner_path=$(gaia_package_dir "$owner_name")
      if [ -z "$resolved_package_path" ]; then
        resolved_package_path="$owner_path"
      fi
      if [ "$owner_path" = "$resolved_package_path" ]; then
        if [ "$owner_path" = . ]; then
          resolved_tokens="${resolved_tokens}${scope_repo_relative}
"
        else
          resolved_tokens="${resolved_tokens}${scope_repo_relative#"$owner_path"/}
"
        fi
        continue
      fi
    fi
    resolved_tokens="${resolved_tokens}${scope_token}
"
  done
  if [ -n "$resolved_package_path" ]; then
    if [ "$resolved_package_path" = . ]; then
      run_directory="$tree_root"
    else
      run_directory="$tree_root/$resolved_package_path"
    fi
  fi
  run_scope=$(printf '%s' "$resolved_tokens" | tr '\n' ' ')

  mkdir -p "$temporary_directory" 2>/dev/null || true
  # BSD mktemp (macOS) only substitutes a TRAILING run of X's; an embedded
  # "-XXXXXX.json" template is read as the literal filename, so a second
  # concurrent call collides with the first and fails outright (mkstemp
  # failed ... File exists), which would silently disable capture until the
  # leftover file is removed by hand. The trailing-X form randomizes on both
  # BSD and GNU mktemp. vitest's own reporter is selected by --reporter=json,
  # not by the outputFile extension, so dropping .json here is safe.
  json_file=$(mktemp "${temporary_directory}/vitest-json-XXXXXX" 2>/dev/null || echo "")
  [ -n "$json_file" ] || exit 0
  cleanup_json=1

  # Re-invoke vitest directly (not `pnpm test`) with the json reporter, in the
  # owning package's directory with the package-relative scope. `pnpm -C <dir>
  # exec vitest` avoids the project `test` script and passes json cleanly; this
  # is a hook subprocess, not a Bash-tool call, so no PreToolUse hook intercepts
  # it.
  # shellcheck disable=SC2086 # $run_scope is an intentional word-split arg list.
  pnpm -C "$run_directory" exec vitest --run --reporter=json --outputFile="$json_file" $run_scope \
    >/dev/null 2>&1 || true
  set +f

  # If vitest produced no parseable json (binary missing, etc.), bail silently.
  if [ ! -s "$json_file" ] || ! jq -e . "$json_file" >/dev/null 2>&1; then
    [ "$cleanup_json" -eq 1 ] && rm -f "$json_file" 2>/dev/null || true
    exit 0
  fi
fi

# --- parse per-test failures, attach signals, append to the ledger ------------
mkdir -p "$ledger_directory" 2>/dev/null || true
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

    # Repo-relative against the ACTING tree's physical root first (vitest reports
    # an absolute path, and the package re-run may sit in a subdirectory); the
    # shared normalizer covers an already-relative name.
    case "$raw_file" in
      "$tree_root"/*) relative_file="${raw_file#"$tree_root"/}" ;;
      *) relative_file=$(red_ledger_repo_relative_path "$raw_file") ;;
    esac
    [ -n "$relative_file" ] || continue

    # Recompute the file's {fullName → signal} map once and reuse it.
    if [ "$relative_file" != "$cached_file" ]; then
      cached_file="$relative_file"
      # From the ACTING TREE, not the process working directory. This helper
      # reads the test file from disk at a repo-relative path and returns 0 with
      # no output when it cannot see it, so from a subdirectory `cached_signals`
      # is empty and the `continue` below appends no ledger line at all.
      #
      # That is load-bearing beyond this hook: this is the FEEDER for the
      # RED-before-GREEN commit gate, which now enforces from a subdirectory.
      # A feeder that silently records nothing there would leave that gate
      # denying every new test with no way to satisfy it.
      cached_signals=$( cd "$tree_root" && red_ledger_signals "$relative_file" 2>/dev/null || echo "")
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
      --arg file "$relative_file" \
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
