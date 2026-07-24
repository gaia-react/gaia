#!/usr/bin/env bats

# Tests for .claude/hooks/post-audit-status.sh's argument surface.
#
# The helper posts a GAIA-Audit commit status, so most of its body needs `gh`
# present and authenticated and a real repo to talk to. This suite covers the
# part that runs before any of that and decides which tree the rest of the run
# will read: the option parse, and the marker-first precondition it must not
# disturb.
#
# The `--root` option exists because the ambient cwd is not the audited tree
# under linked-worktree dispatch. There the cwd is the MAIN checkout while the
# reviewed content sits elsewhere, so a cwd-derived root resolves the wrong
# head, the wrong digest, and the wrong dispatched member set. The tests below
# pin that the flag is consumed as an option, never mistaken for the marker
# path, and that a malformed invocation fails loudly rather than falling back
# to a root the caller did not choose.

# shellcheck disable=SC2317
# SC2317 (command appears unreachable) is a structural false positive on every
# @test block: bats invokes each test body through its own runner, which the
# static analyzer cannot see. The directive is file-wide because the false
# positive is intrinsic to the bats structure, not to any single test.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/post-audit-status.sh
  ROOT=$(mktemp -d -t post-audit-status-root-XXXXXX)
}

teardown() {
  [ -n "${ROOT:-}" ] && rm -rf "$ROOT" || true
  return 0
}

# --- The option parse ---

@test "no arguments: errors with usage naming the root option" {
  run "$HOOK_ABS"

  [ "$status" -eq 2 ]
  grep -qF -- '--root' <<<"$output"
  grep -qF -- 'marker-path' <<<"$output"
}

@test "--root with no value: errors rather than swallowing the marker path" {
  run "$HOOK_ABS" --root

  [ "$status" -eq 2 ]
  grep -qF -- '--root requires a path' <<<"$output"
}

@test "an unrecognized option: errors" {
  run "$HOOK_ABS" --bogus /tmp/marker.ok

  [ "$status" -eq 2 ]
  grep -qF -- 'unknown option: --bogus' <<<"$output"
}

# --- The marker stays positional after the option ---
#
# These assert on the decline reason for a marker that EXISTS, which is what
# makes them discriminating. A parse that mistakes `--root` itself for the
# marker path declines "marker absent" instead, so the two reasons tell a
# consumed option apart from a swallowed one; an absent-marker fixture would
# read the same either way and prove nothing.

@test "--root <path>: the marker is still read from the positional argument" {
  : > "$ROOT/deadbeef.code-audit-maintainer-shell.ok"
  run "$HOOK_ABS" --root "$ROOT" "$ROOT/deadbeef.code-audit-maintainer-shell.ok"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: marker not a valid clearance" ]
}

@test "--root=<path>: the equals form is consumed the same way" {
  : > "$ROOT/deadbeef.code-audit-maintainer-shell.ok"
  run "$HOOK_ABS" "--root=$ROOT" "$ROOT/deadbeef.code-audit-maintainer-shell.ok"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: marker not a valid clearance" ]
}

@test "no --root: an absent marker still declines on the ambient checkout" {
  run "$HOOK_ABS" "$ROOT/absent-marker.ok"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: marker absent" ]
}
