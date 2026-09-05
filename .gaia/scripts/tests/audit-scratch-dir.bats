#!/usr/bin/env bats
#
# Tests for `.gaia/scripts/audit-scratch-dir.sh` -- the per-member mutation
# scratch directory a Code Audit Team member gets instead of improvising a
# name inside the session scratchpad its co-dispatched siblings share.
#
# The property under test throughout is WAVE SAFETY: two members resolving the
# same audit key must never resolve the same directory. That is the whole
# reason the name carries the member half, so the suite asserts it directly
# rather than only asserting the path's shape.
#
# Every test drives the scratch root through $GAIA_AUDIT_SCRATCH_ROOT, so no
# test resolves a real main checkout or writes anywhere under the repo's own
# .gaia/local.
#
# WHICH TREE A CASE RUNS IN is stated here rather than left to be inferred,
# because the subject reads it from the process working directory and this
# file has cases on both sides of that. setup() pins a PLAIN checkout, so a
# case that says nothing about trees gets one, and that is a fixture rather
# than an accident of where bats was launched. A case needing a different
# answer cds there itself and the pin decides nothing for it; the
# `mint/populate asymmetry` block at the foot is where those live, and it
# carries both answers rather than one.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/audit-scratch-dir.bats

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../audit-scratch-dir.sh"
  [ -f "$SCRIPT" ] || skip "audit-scratch-dir.sh missing"

  TMP="$(mktemp -d)"
  export GAIA_AUDIT_SCRATCH_ROOT="$TMP/mutation-scratch"

  # A real git repo on a known branch, so gaia_audit_key resolves a real key
  # rather than falling through to the nokey path in every test.
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b work
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  : >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -qm init

  # Pin the ACTING tree, not only the key's tree. The script takes its KEY
  # tree from the <dir> positional, which defaults to the process working
  # directory, and its ACTING tree from gaia_is_linked_worktree with NO
  # argument, which is that working directory and nothing else. So a case can
  # name the first and nothing but this cd names the second. Left ambient the
  # second is whatever tree bats happened to be launched from, which no case
  # here controls.
  #
  # Unpinned, running the suite from a linked worktree fires the mint's
  # advisory note on stderr; `run` captures "$@" 2>&1, so $output becomes the
  # note lines PLUS the path, and every `[ -d "$output" ]` in the file is then
  # asserting against a multi-line string. That is gaia-react/gaia#1780: the
  # suite was green from a plain checkout and red from a worktree at one
  # commit, and CI only ever runs the first. The mint itself was never at
  # fault -- the directory is on disk in both environments.
  #
  # Deliberately NOT a guard or a skip on the assertions that red: that would
  # leave them unrun in a worktree, which is the same invisibility pointed
  # the other way. A case that cds for itself overrides this pin by doing so,
  # so nothing below has to be exempted from it by hand.
  cd "$REPO" || return 1
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  true
}

# --- path shape --------------------------------------------------------------

@test "the minted path carries the audit key AND the member name" {
  run bash "$SCRIPT" code-audit-frontend deadbeef "$REPO"
  [ "$status" -eq 0 ]
  grep -qF -- "/mutation-scratch/deadbeef.work.code-audit-frontend" <<<"$output"
}

@test "the minted directory exists on disk" {
  run bash "$SCRIPT" code-audit-frontend deadbeef "$REPO"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
}

# --- wave safety: the property the whole file exists for ---------------------

@test "two members sharing one audit key resolve DIFFERENT directories" {
  run bash "$SCRIPT" code-audit-frontend deadbeef "$REPO"
  [ "$status" -eq 0 ]
  local a="$output"
  run bash "$SCRIPT" code-audit-maintainer-shell deadbeef "$REPO"
  [ "$status" -eq 0 ]
  local b="$output"
  [ "$a" != "$b" ]
}

@test "one member's mutation survives a co-dispatched member minting its own dir" {
  local a b
  a="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  printf 'mutated\n' >"$a/tree"
  # The sibling mints (and resets) its own directory in the same wave.
  b="$(bash "$SCRIPT" code-audit-maintainer-shell deadbeef "$REPO")"
  printf 'pristine\n' >"$b/tree"
  # The first member's evidence is untouched: this is the overwrite the
  # improvised-name status quo produced.
  grep -qF -- "mutated" "$a/tree"
}

@test "the same member asking twice in one run gets the same path back" {
  local a b
  a="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  b="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  [ "$a" = "$b" ]
}

@test "re-minting never destroys the asking member's own in-progress tree" {
  # An agent runs its shell commands in separate invocations, so asking a
  # second time to recover the path is ordinary. A destructive mint would
  # lose exactly the evidence this helper exists to protect.
  local a
  a="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  printf 'half-mutated\n' >"$a/tree"
  bash "$SCRIPT" code-audit-frontend deadbeef "$REPO" >/dev/null
  [ -d "$a" ]
  grep -qF -- "half-mutated" "$a/tree"
}

@test "release then mint is how a member gets a fresh baseline" {
  local a
  a="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  printf 'stale\n' >"$a/leftover"
  bash "$SCRIPT" --release code-audit-frontend deadbeef "$REPO"
  bash "$SCRIPT" code-audit-frontend deadbeef "$REPO" >/dev/null
  [ -e "$a/leftover" ] && return 1
  [ -d "$a" ]
}

# --- key resolution ----------------------------------------------------------

@test "two branches on the same base sha resolve different directories" {
  local a b
  a="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  git -C "$REPO" checkout -q -b other
  b="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  [ "$a" != "$b" ]
}

@test "an unresolvable audit key degrades to nokey rather than declining" {
  # No base sha: gaia_audit_key returns 1, and the member still needs a dir.
  run bash "$SCRIPT" code-audit-frontend "" "$REPO"
  [ "$status" -eq 0 ]
  grep -qF -- "/mutation-scratch/nokey.code-audit-frontend" <<<"$output"
  [ -d "$output" ]
}

@test "the nokey path still separates two members" {
  local a b
  a="$(bash "$SCRIPT" code-audit-frontend "" "$REPO")"
  b="$(bash "$SCRIPT" code-audit-maintainer-shell "" "$REPO")"
  [ "$a" != "$b" ]
}

# --- containment -------------------------------------------------------------

@test "a member name containing path separators cannot escape the scratch root" {
  run bash "$SCRIPT" "../../../escaped" deadbeef "$REPO"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  # Assert containment against the RESOLVED parent, never against the printed
  # string. A substring match on the printed path admits a fully-escaped
  # result: `<root>/deadbeef.work.` is still a substring of
  # `<root>/deadbeef.work.../../../escaped`, and that path's basename holds no
  # `..` either, so both of those checks stay green with the slug removed and
  # the directory landing outside the root. `pwd -P` is what collapses the
  # traversal, so this is the only form that can see the escape.
  local parent root_real
  parent="$(cd "$(dirname "$output")" && pwd -P)"
  root_real="$(cd "$GAIA_AUDIT_SCRATCH_ROOT" && pwd -P)"
  [ "$parent" = "$root_real" ]
  # And the separators survive as their encoded form rather than being
  # stripped, which is what keeps the slug injective.
  grep -qF -- "%2F" <<<"$(basename "$output")"
}

@test "a traversing base sha cannot escape the scratch root either" {
  # The key's branch half is percent-encoded but its base-sha half is
  # interpolated raw, and the composed path reaches both mkdir -p and rm -rf.
  # This is the same escape as the member case, through the other positional.
  run bash "$SCRIPT" code-audit-frontend "../../victim" "$REPO"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  local parent root_real
  parent="$(cd "$(dirname "$output")" && pwd -P)"
  root_real="$(cd "$GAIA_AUDIT_SCRATCH_ROOT" && pwd -P)"
  [ "$parent" = "$root_real" ]
}

@test "a traversing base sha degrades to nokey rather than being minted raw" {
  run bash "$SCRIPT" code-audit-frontend "../../victim" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(basename "$output")" = "nokey.code-audit-frontend" ]
}

# --- release -----------------------------------------------------------------

@test "--release removes the member's directory" {
  local a
  a="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  [ -d "$a" ]
  run bash "$SCRIPT" --release code-audit-frontend deadbeef "$REPO"
  [ "$status" -eq 0 ]
  [ -d "$a" ] && return 1
  true
}

@test "--release removes only the named member's directory" {
  local a b
  a="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  b="$(bash "$SCRIPT" code-audit-maintainer-shell deadbeef "$REPO")"
  bash "$SCRIPT" --release code-audit-frontend deadbeef "$REPO"
  [ -d "$a" ] && return 1
  [ -d "$b" ]
}

@test "--release on a directory that was never minted is a silent no-op" {
  run bash "$SCRIPT" --release code-audit-frontend deadbeef "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- failure modes -----------------------------------------------------------

@test "an empty member name mints nothing and exits non-zero" {
  run bash "$SCRIPT" "" deadbeef "$REPO"
  [ "$status" -eq 2 ]
  grep -qF -- "needs a member name" <<<"$output"
}

@test "a bare --release with no member name is refused, not a silent success" {
  # Releasing nothing looks exactly like releasing successfully, so the CLI
  # has to be loud here or a caller believes its tree was cleaned up.
  run bash "$SCRIPT" --release
  [ "$status" -eq 2 ]
  grep -qF -- "needs a member name" <<<"$output"
}

@test "a mistyped --release is refused, never minted as a member named after the typo" {
  run bash "$SCRIPT" --relase code-audit-frontend deadbeef "$REPO"
  [ "$status" -eq 2 ]
  grep -qF -- "unknown option" <<<"$output"
  [ -e "$GAIA_AUDIT_SCRATCH_ROOT" ] && return 1
  true
}

@test "a TRAILING --release is refused, never absorbed into a positional and minted" {
  # The natural misreading of "release it with the same command under
  # --release". Absorbed as <dir>, it makes the audit key undeterminable, so
  # the run mints nokey.<member> and exits 0 while the directory the caller
  # asked to release is untouched.
  local a
  a="$(bash "$SCRIPT" code-audit-frontend deadbeef "$REPO")"
  run bash "$SCRIPT" code-audit-frontend deadbeef --release
  [ "$status" -eq 2 ]
  grep -qF -- "unknown option" <<<"$output"
  [ -e "$GAIA_AUDIT_SCRATCH_ROOT/nokey.code-audit-frontend" ] && return 1
  [ -d "$a" ]
}

@test "an unwritable scratch root reports the create failure, not a checkout failure" {
  # The two failures send a caller to opposite places, so they must not share
  # one message: this one is a full disk or a read-only mount, never a
  # checkout that failed to resolve.
  [ "$(id -u)" -eq 0 ] && skip "root ignores the mode bits this test relies on"
  local jail="$TMP/jail"
  mkdir -p "$jail"
  chmod 500 "$jail"
  GAIA_AUDIT_SCRATCH_ROOT="$jail/mutation-scratch" run bash "$SCRIPT" code-audit-frontend deadbeef "$REPO"
  chmod 700 "$jail"
  [ "$status" -eq 1 ]
  grep -qF -- "could not create" <<<"$output"
  grep -qF -- "no main checkout" <<<"$output" && return 1
  true
}

@test "sourcing the file has no side effects" {
  run bash -c ". '$SCRIPT'; printf 'sourced\n'"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced" ]
  [ -d "$GAIA_AUDIT_SCRATCH_ROOT" ] && return 1
  true
}

@test "the sourced functions are the same ones the CLI dispatches to" {
  run bash -c ". '$SCRIPT'; gaia_audit_scratch_dir code-audit-frontend deadbeef '$REPO'"
  [ "$status" -eq 0 ]
  grep -qF -- "/mutation-scratch/deadbeef.work.code-audit-frontend" <<<"$output"
}

# --- registry conformance ----------------------------------------------------

@test "the on-disk layout matches the audit-mutation-scratch registry entry" {
  local registry
  registry="$( cd "$THIS_DIR/../.." && pwd )/state-registry.json"
  [ -f "$registry" ] || skip "state-registry.json missing"
  run jq -r '.entries[] | select(.id == "audit-mutation-scratch") | "\(.path)|\(.match)|\(.kind)|\(.scope)"' "$registry"
  [ "$status" -eq 0 ]
  [ "$output" = "cache/mutation-scratch/|prefix|dir|ephemeral" ]
}

# --- the mint/populate asymmetry (gaia-react/gaia#1759) -----------------------
#
# A member dispatched into a linked worktree is handed a directory it cannot
# reach with Write/Edit. The two halves fail differently, which is what makes
# it confusing rather than obvious: the mint SUCCEEDS (mkdir -p from Bash) and
# the populate FAILS (the runtime's own worktree confinement refuses a
# file_path that leaves the tree, and `.gaia/local` is one symlink to main's).
#
# GAIA cannot make that Write succeed -- the refusal is the runtime's, not any
# guard's -- so what the mint owes its caller is the constraint, said once, at
# the moment the path is handed over. These cases pin that it is said in the
# worktree case, NOT said otherwise, and said on stderr so a caller capturing
# stdout still gets a bare path.

# Builds a real linked worktree off $REPO and echoes its path. Real rather
# than mocked: gaia_is_linked_worktree is layout-derived, so a fake directory
# would assert nothing about the predicate the script actually consults.
# git keeps its own stderr here: when a runner cannot create a worktree, that
# message is the only thing naming why every case below red, and the cases
# themselves can only report the assignment that failed.
mk_worktree() {
  git -C "$REPO" worktree add -q "$TMP/wt" -b wt-branch || return 1
  printf '%s' "$TMP/wt"
}

@test "minting from a linked worktree says the directory must be populated from Bash" {
  local wt err
  wt="$(mk_worktree)"
  err="$TMP/err"
  ( cd "$wt" && bash "$SCRIPT" code-audit-frontend deadbeef ) >/dev/null 2>"$err"
  grep -qF -- "Bash" "$err"
  grep -qF -- "Write" "$err"
}

@test "the worktree note goes to stderr, so stdout is still a bare path" {
  local wt out
  wt="$(mk_worktree)"
  out="$( cd "$wt" && bash "$SCRIPT" code-audit-frontend deadbeef 2>/dev/null )"
  # Exactly one line, and it is a directory that exists.
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ]
  [ -d "$out" ]
}

@test "the note does not change the mint's exit status" {
  local wt
  wt="$(mk_worktree)"
  # `run`, not a bare subshell: bats runs a test body under errexit, so a
  # failing subshell aborts the test at the subshell itself and a following
  # `[ "$?" -eq 0 ]` can only ever observe 0. That spelling reads as the
  # assertion while errexit is doing the work, and it cannot fail.
  run bash -c 'cd "$1" && bash "$2" code-audit-frontend deadbeef' _ "$wt" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "minting from a plain checkout says nothing: the note is worktree-only" {
  local err
  err="$TMP/err"
  ( cd "$REPO" && bash "$SCRIPT" code-audit-frontend deadbeef ) >/dev/null 2>"$err"
  [ ! -s "$err" ]
}

@test "--release from a worktree is silent: releasing is rm -rf and always works" {
  local wt err
  wt="$(mk_worktree)"
  err="$TMP/err"
  ( cd "$wt" && bash "$SCRIPT" code-audit-frontend deadbeef ) >/dev/null 2>/dev/null
  ( cd "$wt" && bash "$SCRIPT" --release code-audit-frontend deadbeef ) >/dev/null 2>"$err"
  [ ! -s "$err" ]
}
