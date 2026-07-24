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
  [ -n "${FAKEBIN:-}" ] && rm -rf "$FAKEBIN" || true
  [ -n "${OUTSIDE:-}" ] && rm -rf "$OUTSIDE" || true
  return 0
}

# Helper: a real git repo at $ROOT holding a hand-built, well-formed clearance.
# `clearance_acceptable` compares the body's digest/member/provenance against
# the filename; it does not recompute the digest, so a consistent body is a
# valid clearance and the run proceeds past the marker gate to the gh calls.
DIGEST=0000000000000000000000000000000000000000000000000000000000000abc

seed_root_repo() {
  git -C "$ROOT" init --quiet --initial-branch=main
  git -C "$ROOT" config user.email "test@example.com"
  git -C "$ROOT" config user.name "Test"
  git -C "$ROOT" config commit.gpgsign false
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '1.2.3\n' > "$ROOT/.gaia/VERSION"
  echo ".gaia/local/" > "$ROOT/.gitignore"
  git -C "$ROOT" add .gaia/VERSION .gitignore
  git -C "$ROOT" commit --quiet -m "init"
  MARKER="$ROOT/.gaia/local/audit/${DIGEST}.code-audit-maintainer-shell.ok"
  printf '{"digest":"%s","member":"code-audit-maintainer-shell","provenance":"earned"}\n' \
    "$DIGEST" > "$MARKER"
}

# Helper: a `gh` on PATH that records the directory it was invoked from and
# then fails, so the run stops right after the recording.
install_recording_gh() {
  FAKEBIN=$(mktemp -d -t post-audit-status-bin-XXXXXX)
  cat > "$FAKEBIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "auth" ]; then exit 0; fi
pwd > "$GH_CWD_LOG"
exit 1
STUB
  chmod +x "$FAKEBIN/gh"
  export GH_CWD_LOG="$FAKEBIN/cwd.txt"
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

# An EMPTY value parses, so a silent fallback to the ambient checkout would read
# the wrong repo while the caller believes it named a root.

@test "--root with an empty value: errors instead of falling back to the cwd" {
  run "$HOOK_ABS" --root "" "$ROOT/marker.ok"

  [ "$status" -eq 2 ]
  grep -qF -- '--root requires a path' <<<"$output"
}

@test "--root= with an empty value: errors too" {
  run "$HOOK_ABS" "--root=" "$ROOT/marker.ok"

  [ "$status" -eq 2 ]
  grep -qF -- '--root requires a path' <<<"$output"
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

# --- --root decides which repo gh reads ---
#
# The option parse above is only half the contract. `gh` resolves both the repo
# and the PR from its own working directory, so a call left on the ambient cwd
# reads whatever branch the main checkout holds: under worktree dispatch that
# is a different PR, and a status can land on a head this run never audited.
# These assert the invocation directory itself, which the parse tests cannot.

@test "--root: gh is invoked from the named root, not the ambient cwd" {
  seed_root_repo
  install_recording_gh
  OUTSIDE=$(mktemp -d -t post-audit-status-outside-XXXXXX)

  cd "$OUTSIDE"
  PATH="$FAKEBIN:$PATH" run "$HOOK_ABS" --root "$ROOT" "$MARKER"

  [ "$status" -eq 0 ]
  [ -f "$GH_CWD_LOG" ]
  [ "$(cd "$ROOT" && pwd -P)" = "$(cd "$(cat "$GH_CWD_LOG")" && pwd -P)" ]
}

@test "--root naming a path that is not a directory: declines" {
  seed_root_repo
  install_recording_gh

  PATH="$FAKEBIN:$PATH" run "$HOOK_ABS" --root "$ROOT/.gaia/VERSION" "$MARKER"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: root not a directory" ]
}
