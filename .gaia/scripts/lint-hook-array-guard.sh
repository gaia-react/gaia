#!/usr/bin/env bash
# lint-hook-array-guard.sh: flag unguarded bare "${arr[@]}" / "${arr[*]}"
# expansions under `set -u` across the framework's own bash -- the hook bodies
# in .claude/hooks, plus every script under the scan roots listed below. Exit 1
# with a file:line report on any hit, exit 0 when clean. Run it directly from
# the repo root: `bash .gaia/scripts/lint-hook-array-guard.sh`.
# gaia:maintainer-only:start
#
# Enforced twice, and only one of the two blocks a merge. The sibling bats suite
# .gaia/scripts/tests/lint-hook-array-guard.bats runs in the `Audit CI Tests`
# scripts shard, a declared-required context; it fails when this scan finds a
# hit and self-tests the detector against a known-bad fixture. That job's `code`
# filter is what arms it, so EVERY root the scan below walks has to be named
# there, by a glob broad enough to cover the whole root; a path the scan reads
# and the filter misses reports green having run this assertion zero times,
# which is the failure this gate exists to prevent, one level up. Adding a root
# to the scan below is therefore always two edits, here and in that filter.
# `Shell Lint` runs the same scan a second way, on any tracked *.sh, through
# .gaia/tests/shell-lint.sh; it is advisory rather than required, so it reports
# a regression without blocking the merge. Also runnable directly:
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

# Scan surface: the hook scripts, plus every script under each scan root
# (recursive). All of them run under `set -u` and expand arrays, so the
# empty-array abort class is identical in each; the guard catches it wherever
# the bash lives. `find` (not a `**` glob) keeps the recursive walk portable to
# bash 3.2, which has no globstar. Collected into one array with a read loop
# rather than mapfile (bash 4+). Paths stay cwd-relative so the printed
# file:line is repo-relative when the linter runs from the repo root.
#
# The roots are a variable rather than literal `find` arguments because the set
# differs between this repo and an adopter's. A root that ships must stay on the
# base assignment; one that does not must be appended inside a maintainer-only
# block, or the release runtime-dependency check reads it as a shipped script
# reaching for a path the bundle does not carry, and fails the staging build.
scan_roots=(.gaia/scripts)
# gaia:maintainer-only:start
# .gaia/tests is release-excluded, so it exists only in the GAIA maintainer
# repo, where a maintainer runs it on the same stock macOS /bin/bash 3.2.57 the
# shipped scripts abort on. Nothing else covers that tree: its own guard suites
# run under bash 5, where the class does not reproduce, so before this scan
# reached it the only thing standing between the class and main was someone
# noticing it in a diff.
scan_roots+=(.gaia/tests)
# gaia:maintainer-only:end
scan_files=()
for f in .claude/hooks/*.sh; do
  scan_files+=("$f")
done
while IFS= read -r f; do
  scan_files+=("$f")
done < <(find ${scan_roots[@]+"${scan_roots[@]}"} -type f -name '*.sh' 2>/dev/null | LC_ALL=C sort)

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
# carrying an inline suppression. Many of the expansions the scan flags sit
# behind a cross-line count-guard, or over an array filled from a literal that
# cannot be empty, and carry the offset-guard for exactly this reason.
