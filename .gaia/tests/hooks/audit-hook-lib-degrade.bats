#!/usr/bin/env bats

# The degrade branch under a hook's library resolution has to be reachable.
#
# A hook that arms errexit and resolves its library directory with a command
# substitution takes that substitution's exit status on the assignment. With
# `.claude/hooks/lib/` absent -- a partial /update-gaia, an interrupted
# checkout, a hand-deleted directory -- the inner `cd` fails and errexit ends
# the hook ON the assignment, so the `[ -n "$_lib_dir" ]` branch written
# directly below it never runs, in exactly the case it was written for
# (gaia-react/gaia#1590).
#
# The member set is DERIVED from the hooks rather than restated here, so a hook
# that later grows the same resolution is covered without editing this file.
# A member arms errexit, installs no ERR trap, and resolves a `lib`
# subdirectory of its own on-disk location.
#
# A derivation that comes back SHORT is worse than one that comes back empty:
# the empty read trips a non-empty guard, while a short read leaves every
# assertion satisfied over a shrunken set whose name still says "every". The
# member predicate above matches one spelling, and the same defect can be
# written others (`${BASH_SOURCE[0]%/*}`, or a two-step resolve into a `lib`
# child on the following line). So a second, deliberately loose candidate
# predicate runs beside it, and every candidate it names has to be either a
# member or a NAMED exclusion. A hook that is neither fails this suite instead
# of quietly leaving the driven set.
#
# The loose predicate takes any hook that arms errexit, installs no ERR trap,
# and carries both a `$(cd` and a `BASH_SOURCE` anywhere in its text. It reads
# the file rather than a line, so the two-line spelling escapes neither half.
# It filters the ERR-trap family mechanically, for a checked reason: that trap sends the failing assignment to the same silent exit 0 the
# degrade branch would have reached (each such branch ends `|| true` and is
# followed by a `type ... || exit 0`), so the branch is unreachable with no
# change in outcome. That is a shape difference, not a defect, and driving it
# here would assert an obligation those hooks do not carry.
#
# What is left is not machine-derivable and is enumerated by hand below, with a
# warrant per entry, in NOT_MEMBERS.
#
# Each member is driven from a copy in a directory holding no `lib` sibling,
# which is what BASH_SOURCE-based resolution reads, against a control copy
# beside a real `lib`. Same argv, same stdin: an absent library must not change
# the hook's verdict at this point, because both paths reach the same
# downstream precondition.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOKS_DIR="$REPO_ROOT/.claude/hooks"
  CONTROL=$(mktemp -d -t lib-degrade-control-XXXXXX)
  DEGRADED=$(mktemp -d -t lib-degrade-absent-XXXXXX)
  cp "$HOOKS_DIR"/*.sh "$CONTROL/"
  cp -R "$HOOKS_DIR/lib" "$CONTROL/lib"
  cp "$HOOKS_DIR"/*.sh "$DEGRADED/"

  # Members are executed, and one of them commits once its preconditions pass,
  # so refuse rather than driving gate hooks against a real repository. Whether
  # `mktemp -t` can land here at all is platform-dependent: GNU mktemp honors
  # `TMPDIR`, so a `TMPDIR` under a work tree reaches this on the Linux CI
  # runners, while the BSD mktemp macOS ships ignores `TMPDIR` for `-t` and
  # always uses the per-user confstr directory. The guard costs one git call
  # and does not depend on knowing which one is running.
  if git -C "$CONTROL" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'temp dir %s is inside a git work tree; refusing to drive hooks there\n' \
      "$CONTROL" >&2
    return 1
  fi
}

teardown() {
  rm -rf "$CONTROL" "$DEGRADED"
}

# The member set, derived from the hooks themselves. Prints one basename per
# line.
lib_degrade_members() {
  local f
  for f in "$HOOKS_DIR"/*.sh; do
    grep -qF '="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib"' "$f" || continue
    grep -qE '^[[:space:]]*set -[a-z]*e' "$f" || continue
    grep -qE '^[[:space:]]*trap .* ERR' "$f" && continue
    basename "$f"
  done
}

# Hooks the loose predicate below names that are deliberately not members. One
# entry per line, `<basename> <reason>`; the reason is the warrant, and a hook
# arriving here without one is what the reconciliation test refuses.
# Every entry shares one warrant, stated per line so a reader sees which
# directory each one resolves: none of them resolves a `lib` CHILD, which is the
# subdirectory that can genuinely be absent. A hook's own directory was read to
# run it, and an ancestor of that directory contains it, so both exist by
# construction and neither substitution has a reachable failure to degrade from.
#
# That warrant is RE-CHECKED rather than trusted. An exclusion matched on its
# basename alone would be permanent: a listed hook that later grows a lib-child
# resolution would keep its entry, stay out of the driven set, and carry a
# warrant beside its name that has quietly become false. So the reconciliation
# below also asserts each excluded hook still cds nowhere into a `lib`, and an
# entry whose warrant stops holding fails the suite instead of shielding it.
NOT_MEMBERS="\
block-main-destructive-git.sh resolves an ancestor (../..), not a lib child
block-rm-rf.sh resolves an ancestor (../..), not a lib child
block-selfheal-paths.sh resolves its own directory, not a lib child
block-serena-cross-tree-activation.sh resolves an ancestor (../..), not a lib child
block-worktree-path-mismatch.sh resolves an ancestor (../..), not a lib child"

# The loose candidate set: any hook that arms errexit, installs no ERR trap, and
# whose text carries both a `$(cd` command substitution and a `BASH_SOURCE`
# reference. The two predicates are FILE-level and independent on purpose. A
# single line-level grep requiring both together reads only the one-line
# spelling, and the two-line form (`_self="${BASH_SOURCE[0]%/*}"`, then
# `_lib_dir="$(cd "$_self/lib" ...)"`) matches neither of its lines, so exactly
# the re-spelling this reconciliation exists to catch would escape it.
#
# The reach this does claim, and no more: a hook that resolves its own location
# and cds somewhere from it, however those two are spelled and however far
# apart they sit. A hook that outsources the resolve to a helper it sources is
# still outside it.
lib_degrade_candidates() {
  local f
  for f in "$HOOKS_DIR"/*.sh; do
    grep -qE '\$\(cd ' "$f" || continue
    grep -qF 'BASH_SOURCE' "$f" || continue
    grep -qE '^[[:space:]]*set -[a-z]*e' "$f" || continue
    grep -qE '^[[:space:]]*trap .* ERR' "$f" && continue
    basename "$f"
  done
}

@test "the derivation names at least one hook" {
  # A per-element claim over an empty set is true and means nothing, so the
  # derivation reports an empty read as a failure rather than as a pass.
  run lib_degrade_members
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "every loose candidate is a member or a named exclusion" {
  local candidate members
  members=$(lib_degrade_members)
  while read -r candidate; do
    [ -n "$candidate" ] || continue
    grep -qxF -- "$candidate" <<<"$members" && continue

    # Compare field 1 as a literal. A basename interpolated into a pattern is
    # read as one, and `.` before `sh` would then match any character.
    if awk -v name="$candidate" '$1 == name { hit = 1 } END { exit !hit }' \
         <<<"$NOT_MEMBERS"; then
      # The exclusion holds only while its warrant does: no cd into a lib child.
      if grep -qE '\$\(cd [^)]*/lib' "$HOOKS_DIR/$candidate"; then
        printf 'hook %s is excluded as resolving no lib child, but now cds into one\n' \
          "$candidate" >&2
        return 1
      fi
      continue
    fi

    printf 'hook %s resolves from BASH_SOURCE under errexit with no ERR trap, but is neither a driven member nor a named exclusion\n' \
      "$candidate" >&2
    return 1
  done < <(lib_degrade_candidates)
}

@test "every derived hook reaches its own reporting path with lib absent" {
  local hook control_rc degraded_out degraded_rc
  while read -r hook; do
    [ -n "$hook" ] || continue

    # `x=$(...)` takes the substitution's status, and bats runs each body under
    # errexit, so a hook that exits non-zero would abort the test HERE and the
    # assertions below would never report. Capture the status on the failure
    # arm instead; `|| true` would discard the very number being compared.
    control_rc=0
    (cd "$CONTROL" && bash "./$hook" </dev/null >/dev/null 2>&1) || control_rc=$?
    degraded_rc=0
    degraded_out=$(cd "$DEGRADED" && bash "./$hook" </dev/null 2>&1) || degraded_rc=$?

    # The hook ran its own code rather than dying on the assignment. Before the
    # fix the degraded run produced nothing at all.
    if [ -z "$degraded_out" ]; then
      printf 'hook %s produced no output with lib absent\n' "$hook" >&2
      return 1
    fi

    # An absent library did not change the verdict.
    if [ "$degraded_rc" -ne "$control_rc" ]; then
      printf 'hook %s: rc %s with lib, %s without\n' \
        "$hook" "$control_rc" "$degraded_rc" >&2
      return 1
    fi
  done < <(lib_degrade_members)
}

@test "mutation control: restoring the unguarded assignment goes silent" {
  # Samples ONE member on purpose. This control exists to prove the assertion
  # above is not vacuous, and one member establishes that; mutating every
  # member buys the same signal at N times the cost. Coverage is per element
  # in the test above.
  local hook
  hook=$(lib_degrade_members | head -n 1)
  [ -n "$hook" ]

  # Strip the guard the fix added, restoring the pre-fix shape.
  sed -i.bak 's/^\(_lib_dir="\$(cd .*pwd)"\) || true$/\1/' "$DEGRADED/$hook"
  rm -f "$DEGRADED/$hook.bak"
  grep -qE '^_lib_dir="\$\(cd .*pwd\)"$' "$DEGRADED/$hook"

  run bash -c "cd '$DEGRADED' && bash './$hook' </dev/null 2>&1"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
