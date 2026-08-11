#!/usr/bin/env bats
#
# SC2010 is intentional file-wide: the *.bak.<timestamp> backup filenames the
# assertions below match are test-created with no special characters, so
# `ls | grep` cannot hit its unsafe-filename failure mode here.
# shellcheck disable=SC2010
#
# Bats suite for .gaia/scripts/link-worktree.sh (SPEC-005 task-link-script).
#
# A linked worktree's whole .gaia/local is ONE symlink to the main checkout's
# own .gaia/local (SPEC-061's cutover); every registry-declared entry lives
# under that one shared directory now, so this suite proves the single
# symlink and its write-through, not a per-path enumeration.
#
# Each test gets a fresh tmp directory containing a main checkout + a linked
# worktree (mirrors the SPEC-004 setupWorktreeSandbox helper, in bash).

setup() {
  # Resolve the script under test relative to this file (repo-root agnostic).
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/link-worktree.sh"

  # Canonicalize via `pwd -P` because macOS resolves /var -> /private/var
  # inside `git rev-parse`, and the script reports absolute paths from the
  # canonical form. We compare against those reports byte-for-byte.
  TMPROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/gaia-link-wt-XXXXXX")"
  TMPROOT="$(cd "$TMPROOT_RAW" && pwd -P)"
  MAIN="$TMPROOT/main"
  LINKED="$TMPROOT/linked"

  # Git identity for commits inside the sandbox (CI without a configured user).
  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" commit --allow-empty -q -m "init"
  git -C "$MAIN" worktree add -q "$LINKED" -b "feature/test"
}

teardown() {
  if [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ]; then
    # Clean the linked worktree first so git doesn't complain.
    git -C "$MAIN" worktree remove --force "$LINKED" 2>/dev/null || true
    rm -rf "$TMPROOT"
  fi
  if [ -n "$TMPROOT_RAW" ] && [ "$TMPROOT_RAW" != "$TMPROOT" ] && [ -d "$TMPROOT_RAW" ]; then
    rm -rf "$TMPROOT_RAW"
  fi
}

# Run the script with cwd set to $1.
run_in() {
  ( cd "$1" && bash "$SCRIPT" )
}

# ---------- 1. Fresh worktree, no pre-existing files ----------
@test "fresh worktree: creates the one .gaia/local symlink" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]
  [ -L "$LINKED/.gaia/local" ]
  [ "$(readlink "$LINKED/.gaia/local")" = "$MAIN/.gaia/local" ]

  # Exactly one "linked:" log line, naming .gaia/local itself -- not a
  # per-entry enumeration.
  linked_lines="$(grep -c '^linked: ' <<<"$output")"
  [ "$linked_lines" -eq 1 ]
  [[ "$output" == *"linked: $LINKED/.gaia/local"* ]] || return 1
}

@test "fresh worktree: .gaia gets exactly one child, local, and it is the symlink" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  entries="$(find "$LINKED/.gaia" -maxdepth 1 -mindepth 1 | sort)"
  [ "$entries" = "$LINKED/.gaia/local" ]
  [ -L "$LINKED/.gaia/local" ]
}

# ---------- 2. Already-linked worktree (idempotent) ----------
@test "already-linked: re-running is a no-op with no backups" {
  run_in "$LINKED"
  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  [ -L "$LINKED/.gaia/local" ]

  # No backup files anywhere.
  run bash -c "find '$LINKED' -name '*.bak.*' -print"
  [ -z "$output" ]

  # Logged "already-linked".
  run run_in "$LINKED"
  [[ "$output" == *"already-linked: $LINKED/.gaia/local"* ]] || return 1
}

# ---------- 3. Worktree with a pre-existing plain .gaia/local ----------
@test "pre-existing plain .gaia/local: backed up whole, then symlinked" {
  # A real (non-symlink) .gaia/local with content, as a worktree used before
  # this cutover would have (per-tree entries as real directories under it).
  mkdir -p "$LINKED/.gaia/local/red-ledger"
  printf 'stale-content' > "$LINKED/.gaia/local/red-ledger/observations.jsonl"

  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  [ -L "$LINKED/.gaia/local" ]

  bak="$(ls "$LINKED/.gaia/" | grep '^local\.bak\.')"
  [ -n "$bak" ]
  [ "$(cat "$LINKED/.gaia/$bak/red-ledger/observations.jsonl")" = "stale-content" ]

  [[ "$output" == *"linked-after-backup: $LINKED/.gaia/local"* ]] || return 1
}

# ---------- 4. Worktree with broken symlink (target does not exist) ----------
@test "broken .gaia/local symlink: backed up and replaced" {
  mkdir -p "$LINKED/.gaia"
  ln -s "/nonexistent/path/local" "$LINKED/.gaia/local"

  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  # The path is now a symlink to the canonical target.
  [ -L "$LINKED/.gaia/local" ]
  [ "$(readlink "$LINKED/.gaia/local")" = "$MAIN/.gaia/local" ]

  # The broken symlink got renamed to a .bak file (which is itself still a
  # broken symlink; `mv` of a symlink moves the link, not the target).
  bak="$(ls "$LINKED/.gaia/" | grep '^local\.bak\.')"
  [ -n "$bak" ]
  [ -L "$LINKED/.gaia/$bak" ]
  [ "$(readlink "$LINKED/.gaia/$bak")" = "/nonexistent/path/local" ]

  [[ "$output" == *"linked-after-backup: $LINKED/.gaia/local"* ]] || return 1
}

# ---------- 5. Main-checkout invocation ----------
@test "main checkout: emits 'not a linked worktree' and creates no .gaia/local" {
  run run_in "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a linked worktree"* ]] || return 1

  # Nothing created in main by this no-op invocation.
  [ ! -e "$MAIN/.gaia/local" ]
}

# ---------- 6. Main checkout missing .gaia/local ----------
@test "main missing .gaia/local: creates it (a real dir) before symlinking" {
  [ ! -e "$MAIN/.gaia/local" ]

  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  # Main-side target now exists, as a real directory (never a symlink).
  [ -d "$MAIN/.gaia/local" ]
  [ ! -L "$MAIN/.gaia/local" ]

  # The worktree's symlink resolves (no dangling).
  [ -L "$LINKED/.gaia/local" ]
  [ -d "$LINKED/.gaia/local" ]
}

# ---------- 7. Symlink-permission failure (simulated) ----------
@test "ln -s failure: logs failed and exits 0 anyway" {
  # Shadow `ln` with a failing version on PATH.
  fake_bin="$TMPROOT/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ln" <<'FAKE'
#!/bin/sh
echo "fake ln: permission denied" >&2
exit 1
FAKE
  chmod +x "$fake_bin/ln"

  PATH="$fake_bin:$PATH" run bash -c "cd '$LINKED' && bash '$SCRIPT'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"failed: $LINKED/.gaia/local"* ]] || return 1

  # The symlink was NOT created (since ln was sabotaged).
  [ ! -L "$LINKED/.gaia/local" ]
}

# ---------- 8. Non-git cwd ----------
@test "not a git repo: logs and exits 0" {
  nogit="$TMPROOT/nogit"
  mkdir -p "$nogit"

  run run_in "$nogit"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a git repo"* ]] || return 1
}

# ---------- 9. Write-through: a per-tree-keyed write from the worktree ----------
# lands in the main checkout, because .gaia/local is now the SAME physical
# directory reached from either side, not a per-entry symlink into it.
@test "write-through: a keyed red-ledger write on the worktree side lands in the main checkout" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  [ -L "$LINKED/.gaia/local" ]
  [ "$(readlink "$LINKED/.gaia/local")" = "$MAIN/.gaia/local" ]

  mkdir -p "$LINKED/.gaia/local/red-ledger/deadbeefdeadbeef"
  printf '%s\n' '{"total":42}' >> "$LINKED/.gaia/local/red-ledger/deadbeefdeadbeef/observations.jsonl"
  [ -f "$MAIN/.gaia/local/red-ledger/deadbeefdeadbeef/observations.jsonl" ]
  [ "$(cat "$MAIN/.gaia/local/red-ledger/deadbeefdeadbeef/observations.jsonl")" = '{"total":42}' ]
}

# ---------- 9b. Harden decline ledger durability (write-through to main) ----------
@test "harden declines: a decline written on the worktree side lands in the main checkout" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  mkdir -p "$LINKED/.gaia/local/harden"
  printf '%s\n' '{"version":1,"declines":[{"finding_class":"x"}]}' > "$LINKED/.gaia/local/harden/declines.json"
  [ -f "$MAIN/.gaia/local/harden/declines.json" ]
  [ "$(cat "$MAIN/.gaia/local/harden/declines.json")" = '{"version":1,"declines":[{"finding_class":"x"}]}' ]
}

@test "env files: fresh worktree shares .env and .env.local, skips .env.example" {
  printf 'ENV_VAR=main' > "$MAIN/.env"
  printf 'LOCAL_VAR=local' > "$MAIN/.env.local"
  printf 'EXAMPLE_VAR=example' > "$MAIN/.env.example"

  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  [ -L "$LINKED/.env" ]
  [ -L "$LINKED/.env.local" ]
  [ "$(readlink "$LINKED/.env")" = "$MAIN/.env" ]
  [ "$(readlink "$LINKED/.env.local")" = "$MAIN/.env.local" ]

  # .env.example is committed and already present as a plain file; never linked.
  [ ! -L "$LINKED/.env.example" ]

  # Content reads through the symlink.
  [ "$(cat "$LINKED/.env")" = "ENV_VAR=main" ]
}

@test "env files: no env files in main means no env symlinks, still exit 0" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]
  [ ! -L "$LINKED/.env" ]

  # The one .gaia/local symlink still exists (no regression from the env addition).
  [ -L "$LINKED/.gaia/local" ]
}

@test "env files: idempotent re-run logs already-linked with no backups" {
  printf 'ENV_VAR=main' > "$MAIN/.env"
  run_in "$LINKED"
  run run_in "$LINKED"
  [ "$status" -eq 0 ]
  grep -qF -- "already-linked: $LINKED/.env" <<<"$output" || return 1

  run bash -c "find '$LINKED' -maxdepth 1 -name '.env.bak.*' -print"
  [ -z "$output" ]
}

@test "env files: pre-existing plain .env in worktree is backed up then linked" {
  printf 'ENV_VAR=main' > "$MAIN/.env"
  printf 'STRAY_VAR=stray' > "$LINKED/.env"

  run run_in "$LINKED"
  [ "$status" -eq 0 ]
  [ -L "$LINKED/.env" ]

  bak="$(ls -a "$LINKED" | grep '^\.env\.bak\.')"
  [ -n "$bak" ]
  [ "$(cat "$LINKED/$bak")" = "STRAY_VAR=stray" ]

  grep -qF -- "linked-after-backup: $LINKED/.env" <<<"$output" || return 1
}

# ---------- 14. Runtime read-through: writes to main .env are visible via the symlink ----------
@test "env files: a write to main .env is visible via the worktree symlink" {
  printf 'ENV_VAR=main' > "$MAIN/.env"
  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  printf '\nAPPENDED_VAR=appended\n' >> "$MAIN/.env"
  grep -qF -- "APPENDED_VAR=appended" "$LINKED/.env" || return 1
}

@test "env files: editor cruft under .env.* glob is rejected by the regex guard" {
  printf 'ENV_VAR=main' > "$MAIN/.env"
  printf 'STRAY_CRUFT=1' > "$MAIN/.env.local~"

  run run_in "$LINKED"
  [ "$status" -eq 0 ]
  [ -L "$LINKED/.env" ]

  # The cruft is NOT linked: fails if the regex guard is dropped and the shell
  # links the raw glob match.
  [ ! -L "$LINKED/.env.local~" ]
}

# ---------- 16. The byte-locked link trio: the .sh and .ts twins agree ----------

# Before the state registry, this script's own link_one list and the CLI's
# SHARED_PATHS were two hand-maintained copies of the same five paths, kept in
# sync by hand (tech-debt #953). After the cutover neither twin enumerates a
# path list at all -- both symlink the ONE path, .gaia/local -- so the thing
# left to keep in lockstep is that literal itself. This proves it two ways:
# the script's own logged action names exactly .gaia/local, and the
# TypeScript twin's source hardcodes the identical relative path, so a future
# edit that widens or narrows either twin's target shows up here.
@test "shared path: the script's one action is .gaia/local, matching the TypeScript twin's literal" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  linked_lines="$(grep -c '^linked: ' <<<"$output")"
  [ "$linked_lines" -eq 1 ]
  [[ "$output" == *"linked: $LINKED/.gaia/local"* ]] || return 1

  ts_src="$SCRIPT_DIR/../cli/src/setup/link-worktree.ts"
  [ -f "$ts_src" ]
  grep -qF "path.join('.gaia', 'local')" "$ts_src" || return 1
}
