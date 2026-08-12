#!/usr/bin/env bash
# lint-hook-array-guard.sh: flag unguarded bare "${arr[@]}" / "${arr[*]}"
# expansions under `set -u` across the framework's own bash -- the hook bodies
# in .claude/hooks, every script under .gaia/scripts, and the test bash under
# .gaia/tests. Exit 1 with a file:line report on any hit, exit 0 when clean. Run
# it directly from the repo root: `bash .gaia/scripts/lint-hook-array-guard.sh`.
# gaia:maintainer-only:start
#
# Enforced twice. The sibling bats suite
# .gaia/scripts/tests/lint-hook-array-guard.bats runs in the `Audit CI Tests`
# scripts shard, armed by a change under .claude/hooks/** or .gaia/scripts/**;
# it fails when this scan finds a hit and self-tests the detector against a
# known-bad fixture. `Shell Lint` arms on any tracked *.sh and runs
# .gaia/tests/shell-lint.sh, which folds this scan in as a pass, so a change
# confined to .gaia/tests still gates on it. Also runnable directly:
# `bats .gaia/scripts/tests/lint-hook-array-guard.bats`.
# gaia:maintainer-only:end
#
# Why: on bash 3.2.57 (stock macOS /bin/bash) a bare "${arr[@]}" expansion of
# an EMPTY array aborts with `arr[@]: unbound variable` under `set -u`; bash
# 4.4+ does not. A hook that aborts mid-body exits before it can emit its deny
# JSON, so a guard can fail OPEN. The bats suites run under Homebrew bash 5 and
# are blind to this entire class, so no test gate catches it. A static grep
# does, on every bash version.
#
# Fix either bare expansion the check flags:
#   [ "${#arr[@]}" -eq 0 ] || some_command "${arr[@]}"     # count-guard
#   some_command ${arr[@]+"${arr[@]}"}                     # offset-guard
#
# Reference fix: .claude/hooks/block-env-read.sh (the guarded process_segment).

set -euo pipefail

# Scan surface: the hook scripts, plus every shipped .gaia/scripts script and
# every .gaia/tests script (both recursive). All three run under `set -u` and
# expand arrays, so the empty-array abort class is identical in each; the guard
# catches it wherever the bash lives. .gaia/tests is release-excluded and never
# reaches an adopter, but a maintainer runs it on the same stock macOS
# /bin/bash 3.2.57 the shipped scripts abort on, so the class bites there too:
# the sharder .gaia/tests/bats-shards.sh took the abort in place of its own
# documented fail-closed exit, and its bash-5 guard suite saw nothing.
# `find` (not a `**` glob) keeps the recursive walk portable to bash
# 3.2, which has no globstar. Collected into one array with a read loop rather
# than mapfile (bash 4+). Paths stay cwd-relative so the printed file:line is
# repo-relative when the linter runs from the repo root.
scan_files=()
for f in .claude/hooks/*.sh; do
  scan_files+=("$f")
done
while IFS= read -r f; do
  scan_files+=("$f")
done < <(find .gaia/scripts .gaia/tests -type f -name '*.sh' 2>/dev/null | LC_ALL=C sort)

scan_file() {
  local f="$1"
  # Only files that actually run under set -u can hit the empty-array abort.
  grep -Eq 'set +-[a-zA-Z]*u|set +-o +nounset' "$f" || return 0

  # Flag double-quoted bare array expansions, minus the two guarded forms:
  #   - offset-guard on the same line: ${name[@]+ ... }
  #   - count-guard on the same line:  ${#name[@]}  (the inline `[ ... ] || ...` shape)
  # Full-line comments are skipped. Cross-line guards (a count check on an
  # earlier line) are NOT understood and read as false positives; so does a
  # provably-non-empty array (e.g. one filled right after a `[ -n "$x" ]`
  # guard). Verify each hit before "fixing" it. Unquoted ${arr[@]} has the
  # same hazard but is not matched here; add it if your hooks use it.
  awk -v file="$f" '
    /^[[:space:]]*#/ { next }
    {
      rest = $0
      while (match(rest, /"\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}"/)) {
        name = substr(rest, RSTART, RLENGTH)
        sub(/^"\$\{/, "", name)
        sub(/\[[@*]\]\}"$/, "", name)
        guarded = 0
        if (index($0, "${" name "[@]+") || index($0, "${" name "[*]+")) guarded = 1
        if (index($0, "${#" name "[@]}") || index($0, "${#" name "[*]}")) guarded = 1
        if (!guarded)
          printf "%s:%d: unguarded \"${%s[@]}\" under set -u\n", file, NR, name
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$f"
}

report=""
for f in ${scan_files[@]+"${scan_files[@]}"}; do
  [ -f "$f" ] || continue
  hits=$(scan_file "$f")
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  echo "Guard each: [ \"\${#arr[@]}\" -eq 0 ] || cmd \"\${arr[@]}\"  |  cmd \${arr[@]+\"\${arr[@]}\"}" >&2
  exit 1
fi

echo "lint-hook-array-guard: clean" >&2
exit 0

# --------------------------- False positives ---------------------------
# The awk scan is single-line: it cannot see a count-guard on an earlier line
# or reason that an array is provably non-empty (e.g. filled right after a
# `[ -n "$x" ]` guard), so either reads as a hit. When a flagged expansion is
# genuinely safe, resolve it by applying the same offset-guard the fix uses,
# `cmd ${arr[@]+"${arr[@]}"}`, so the gate stays zero-exception rather than
# carrying an inline suppression. The scan surface is `.claude/hooks/*.sh` plus
# every `.gaia/scripts/**/*.sh` and `.gaia/tests/**/*.sh` (recursive); many of
# the expansions it flags sit behind a cross-line count-guard, or over an array
# filled from a literal that cannot be empty, and carry the offset-guard for
# exactly this reason.
