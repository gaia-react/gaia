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
# Two families are deliberately NOT members, each for a checked reason:
#
#   - A hook installing `trap 'exit 0' ERR` alongside errexit. The trap sends
#     the failing assignment to the same silent exit 0 its degrade branch would
#     have reached (each such branch ends `|| true` and is followed by a
#     `type ... || exit 0`), so the branch is unreachable with no change in
#     outcome. That is a shape difference, not a defect, and driving it here
#     would assert an obligation these hooks do not carry.
#   - A resolution of the hook's OWN directory rather than a `lib` child
#     (`SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`). The
#     directory the running script was read from exists by construction, so
#     the substitution has no reachable failure to degrade from.
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

@test "the derivation names at least one hook" {
  # A per-element claim over an empty set is true and means nothing, so the
  # derivation reports an empty read as a failure rather than as a pass.
  run lib_degrade_members
  [ "$status" -eq 0 ]
  [ -n "$output" ]
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
