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
# The loose predicate takes a hook that arms errexit, installs no ERR trap, and
# opens a command substitution with a `cd` anywhere in its text. It reads the
# file rather than a line, so a resolve split across two lines escapes neither
# half, and it says nothing about WHAT the hook cds to: the location can be
# spelled `${BASH_SOURCE[0]}`, `$0`, or a variable set forty lines earlier, and
# the hook is a candidate either way.
#
# Neither of those two terms is a claim about every way a shell can reach the
# state it names. "Arms errexit" means what `lib_degrade_errexit_armed` below
# reads, and that reader's own header states which spellings it takes. "Opens a
# command substitution with a `cd`" means literally `$(cd`, optional space
# allowed, which is where this defect has to live: the branch goes unreachable
# only when the assignment can take a FAILING status, and a plain parameter
# expansion (`${BASH_SOURCE[0]%/*}/lib`) cannot fail that way, so it is out of
# scope rather than missed. Two shapes ARE outside the reach rather than out of
# scope: a substitution whose `cd` is not its first word, and a resolve
# outsourced to a helper the hook sources.
#
# It filters the ERR-trap family mechanically, for a checked reason: that trap
# sends the failing assignment to the same silent exit 0 the degrade branch
# would have reached (each such branch ends `|| true` and is followed by a
# `type ... || exit 0`), so the branch is unreachable with no change in
# outcome. That is a shape difference, not a defect, and driving it here would
# assert an obligation those hooks do not carry.
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

# Armed-and-untrapped, the half both derivations below share. It is ONE reader
# rather than a copy in each, because the two sat four lines apart and a
# widening of the arming spelling could land in one and leave nothing red: that
# is the short-read hazard this file's own header warns about, one level up in
# the predicate feeding it.
#
# Armed reads the two spellings this repo's own errexit lints accept
# (`.gaia/scripts/lint-errexit-source-guard.sh`, `lint-errexit-status-read.sh`):
# an `e` inside a short option bundle (`set -e`, `set -euo pipefail`), or an
# explicit `set -o errexit`. Either may sit at any position on the line, ahead
# of any `#`, so a trailing comment naming `-e` does not arm. `set +e` suspends
# rather than arms and is not read as arming.
#
# What it reads is literally a `-<letters>` token containing an `e`, so it does
# not model `--` ending option parsing: `set -- "$@" -meta` reads as armed. No
# hook spells that, and the direction is fail-closed if one ever does. An
# over-armed hook joins the candidate set and then owes a member match or a
# NOT_MEMBERS warrant, so the cost of the over-read is a red, never a miss.
lib_degrade_errexit_armed() {
  grep -qE '^[[:space:]]*set[[:space:]]([^#]*[[:space:]])?(-[a-zA-Z]*e[a-zA-Z]*|-o[[:space:]]+errexit)([[:space:]]|;|$)' "$1" || return 1
  grep -qE '^[[:space:]]*trap .* ERR' "$1" && return 1
  return 0
}

# The member set, derived from the hooks themselves. Prints one basename per
# line.
lib_degrade_members() {
  local f
  for f in "$HOOKS_DIR"/*.sh; do
    # shellcheck disable=SC2016  # a literal pattern matching shell syntax in
    # the hook's text; expansion is exactly what must not happen here.
    grep -qF '="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib"' "$f" || continue
    lib_degrade_errexit_armed "$f" || continue
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
# below also re-reads each excluded hook, and an entry whose warrant stops
# holding fails the suite instead of shielding it.
#
# What that re-check reads, exactly: a `$(cd` substitution naming a `lib` child
# ON ONE LINE. It spans the whole substitution rather than stopping at the
# first `)`, because this repo's house spelling nests a substitution inside it
# (`$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)`) and puts the `/lib`
# after that inner close paren, where a non-crossing match cannot reach it.
#
# It is line-level while the candidate term below is file-level, so one shape
# escapes it: a resolve that reaches its lib child through an intermediate
# variable (`_libpath="$_self/lib"` on one line, `$(cd "$_libpath" ...)` on the
# next) satisfies neither this re-check nor the member literal, and would keep
# its exclusion. No hook here spells that, and closing it means a second
# hand-rolled pattern guessing at how far the indirection runs, which is the
# cost this file has already paid twice. It is named rather than closed, and an
# author adding an indirected resolve to a listed hook owes this list an edit.
NOT_MEMBERS="\
block-main-destructive-git.sh resolves an ancestor (../..), not a lib child
block-rm-rf.sh resolves an ancestor (../..), not a lib child
block-selfheal-paths.sh resolves its own directory, not a lib child
block-serena-cross-tree-activation.sh resolves an ancestor (../..), not a lib child
block-worktree-path-mismatch.sh resolves an ancestor (../..), not a lib child"

# The loose candidate set: a hook that `lib_degrade_errexit_armed` reads as
# armed and untrapped, and whose text opens a command substitution with a `cd`
# anywhere. That is ONE text term, not two. It used to also require a literal
# `BASH_SOURCE`, and that conjunct was a short read: a hook resolving its own
# location as `$(cd "$(dirname "$0")/lib" && pwd)` carries the #1590 defect
# exactly, matched neither this predicate nor the member literal, and so left
# the driven set with nothing red. Dropping the conjunct named the identical
# seven hooks on the clean tree, so it was buying no precision to trade away.
#
# The term is FILE-level rather than line-level on purpose, which is what lets
# a resolve split across two lines (`_self="${BASH_SOURCE[0]%/*}"`, then
# `_lib_dir="$(cd "$_self/lib" ...)"`) still land here: neither line carries
# the whole shape, and the file does.
#
# The `[[:space:]]*` is not decoration. `$( cd "$root" && ... )` is in-house
# too, at seven sites across four of these hooks, and a pattern anchored on
# `$(cd` alone cannot see it.
#
# Deliberately looser than the member predicate below it, which has to name one
# exact shape because members get EXECUTED. Everything this catches and that
# one does not is precisely what the reconciliation forces a decision about.
lib_degrade_candidates() {
  local f
  for f in "$HOOKS_DIR"/*.sh; do
    grep -qE '\$\([[:space:]]*cd[[:space:]]' "$f" || continue
    lib_degrade_errexit_armed "$f" || continue
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
  local candidate member members candidates
  members=$(lib_degrade_members)
  candidates=$(lib_degrade_candidates)

  # This test exists to catch a SHORT member derivation, so it must not retire
  # quietly when its OWN derivation goes short instead. The candidate term
  # gates on something the member predicate does not share, so it can narrow or
  # break alone, and every claim below would then be true over nothing. Test 1
  # guards the member derivation; this guards the one driving this loop.
  [ -n "$candidates" ]

  # Looser than the member predicate is the whole point of the candidate set,
  # so a member missing from it means the loose term has narrowed past the set
  # it is supposed to contain. That is the same short read one level over, and
  # the non-empty guard above cannot see it: dropping a member leaves the
  # candidate derivation non-empty.
  while read -r member; do
    [ -n "$member" ] || continue
    grep -qxF -- "$member" <<<"$candidates" && continue
    printf 'member %s is not a candidate, so the loose predicate has narrowed past the driven set it must contain\n' \
      "$member" >&2
    return 1
  done <<<"$members"

  while read -r candidate; do
    [ -n "$candidate" ] || continue
    grep -qxF -- "$candidate" <<<"$members" && continue

    # Compare field 1 as a literal. A basename interpolated into a pattern is
    # read as one, and `.` before `sh` would then match any character.
    if awk -v name="$candidate" '$1 == name { hit = 1 } END { exit !hit }' \
         <<<"$NOT_MEMBERS"; then
      # The exclusion holds only while its warrant does: no cd into a lib child.
      if grep -qE '\$\([[:space:]]*cd[[:space:]].*/lib' "$HOOKS_DIR/$candidate"; then
        printf 'hook %s is excluded as resolving no lib child, but now cds into one\n' \
          "$candidate" >&2
        return 1
      fi
      continue
    fi

    printf 'hook %s opens a cd command substitution under errexit with no ERR trap, but is neither a driven member nor a named exclusion\n' \
      "$candidate" >&2
    return 1
  done <<<"$candidates"
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
  # shellcheck disable=SC2016  # a literal sed program matching shell syntax in
  # the hook's text; expansion is exactly what must not happen here.
  sed -i.bak 's/^\(_lib_dir="\$(cd .*pwd)"\) || true$/\1/' "$DEGRADED/$hook"
  rm -f "$DEGRADED/$hook.bak"
  grep -qE '^_lib_dir="\$\(cd .*pwd\)"$' "$DEGRADED/$hook"

  run bash -c "cd '$DEGRADED' && bash './$hook' </dev/null 2>&1"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
