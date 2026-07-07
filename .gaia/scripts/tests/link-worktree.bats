#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/link-worktree.sh (SPEC-005 task-link-script).
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
@test "fresh worktree: creates all shared symlinks" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]
  [ -L "$LINKED/.gaia/local/setup-state.json" ]
  [ -L "$LINKED/.gaia/local/cache/shared" ]
  [ -L "$LINKED/.gaia/local/audit" ]
  [ -L "$LINKED/.gaia/local/telemetry" ]

  # Targets are absolute paths into MAIN.
  [ "$(readlink "$LINKED/.gaia/local/setup-state.json")" = "$MAIN/.gaia/local/setup-state.json" ]
  [ "$(readlink "$LINKED/.gaia/local/cache/shared")" = "$MAIN/.gaia/local/cache/shared" ]
  [ "$(readlink "$LINKED/.gaia/local/audit")" = "$MAIN/.gaia/local/audit" ]
  [ "$(readlink "$LINKED/.gaia/local/telemetry")" = "$MAIN/.gaia/local/telemetry" ]

  # Each "linked:" log appears once on stderr.
  [[ "$output" == *"linked: $LINKED/.gaia/local/setup-state.json"* ]]
  [[ "$output" == *"linked: $LINKED/.gaia/local/cache/shared"* ]]
  [[ "$output" == *"linked: $LINKED/.gaia/local/audit"* ]]
  [[ "$output" == *"linked: $LINKED/.gaia/local/telemetry"* ]]
}

# ---------- 2. Already-linked worktree (idempotent) ----------
@test "already-linked: re-running is a no-op with no backups" {
  run_in "$LINKED"
  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  # All shared symlinks still present.
  [ -L "$LINKED/.gaia/local/setup-state.json" ]
  [ -L "$LINKED/.gaia/local/cache/shared" ]
  [ -L "$LINKED/.gaia/local/audit" ]
  [ -L "$LINKED/.gaia/local/telemetry" ]

  # No backup files anywhere.
  run bash -c "find '$LINKED' -name '*.bak.*' -print"
  [ -z "$output" ]

  # All shared paths logged "already-linked".
  run run_in "$LINKED"
  [[ "$output" == *"already-linked: $LINKED/.gaia/local/setup-state.json"* ]]
  [[ "$output" == *"already-linked: $LINKED/.gaia/local/cache/shared"* ]]
  [[ "$output" == *"already-linked: $LINKED/.gaia/local/audit"* ]]
  [[ "$output" == *"already-linked: $LINKED/.gaia/local/telemetry"* ]]
}

# ---------- 3. Worktree with pre-existing plain files ----------
@test "pre-existing plain files: backed up then symlinks created" {
  # Create a plain setup-state.json file with content.
  mkdir -p "$LINKED/.gaia/local"
  printf '{"plain":"file"}' > "$LINKED/.gaia/local/setup-state.json"

  # Create a plain cache/ directory with content.
  mkdir -p "$LINKED/.gaia/local/cache/shared"
  printf 'plain-cache-content' > "$LINKED/.gaia/local/cache/shared/marker.txt"

  # Create a plain audit/ directory with content.
  mkdir -p "$LINKED/.gaia/local/audit"
  printf 'plain-audit-content' > "$LINKED/.gaia/local/audit/marker.txt"

  # Create a plain telemetry/ directory with content.
  mkdir -p "$LINKED/.gaia/local/telemetry"
  printf 'plain-telemetry-content' > "$LINKED/.gaia/local/telemetry/marker.txt"

  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  # All are now symlinks.
  [ -L "$LINKED/.gaia/local/setup-state.json" ]
  [ -L "$LINKED/.gaia/local/cache/shared" ]
  [ -L "$LINKED/.gaia/local/audit" ]
  [ -L "$LINKED/.gaia/local/telemetry" ]

  # Backups exist with the original content preserved.
  setup_bak="$(ls "$LINKED/.gaia/local/" | grep '^setup-state\.json\.bak\.')"
  [ -n "$setup_bak" ]
  [ "$(cat "$LINKED/.gaia/local/$setup_bak")" = '{"plain":"file"}' ]

  cache_bak="$(ls "$LINKED/.gaia/local/cache/" | grep '^shared\.bak\.')"
  [ -n "$cache_bak" ]
  [ "$(cat "$LINKED/.gaia/local/cache/$cache_bak/marker.txt")" = "plain-cache-content" ]

  audit_bak="$(ls "$LINKED/.gaia/local/" | grep '^audit\.bak\.')"
  [ -n "$audit_bak" ]
  [ "$(cat "$LINKED/.gaia/local/$audit_bak/marker.txt")" = "plain-audit-content" ]

  telemetry_bak="$(ls "$LINKED/.gaia/local/" | grep '^telemetry\.bak\.')"
  [ -n "$telemetry_bak" ]
  [ "$(cat "$LINKED/.gaia/local/$telemetry_bak/marker.txt")" = "plain-telemetry-content" ]

  # All logged "linked-after-backup".
  [[ "$output" == *"linked-after-backup: $LINKED/.gaia/local/setup-state.json"* ]]
  [[ "$output" == *"linked-after-backup: $LINKED/.gaia/local/cache/shared"* ]]
  [[ "$output" == *"linked-after-backup: $LINKED/.gaia/local/audit"* ]]
  [[ "$output" == *"linked-after-backup: $LINKED/.gaia/local/telemetry"* ]]
}

# ---------- 4. Worktree with broken symlink (target does not exist) ----------
@test "broken symlink: backed up and replaced" {
  mkdir -p "$LINKED/.gaia/local"
  ln -s "/nonexistent/path/setup-state.json" "$LINKED/.gaia/local/setup-state.json"

  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  # The path is now a symlink to the canonical target.
  [ -L "$LINKED/.gaia/local/setup-state.json" ]
  [ "$(readlink "$LINKED/.gaia/local/setup-state.json")" = "$MAIN/.gaia/local/setup-state.json" ]

  # The broken symlink got renamed to a .bak file (which is itself still a
  # broken symlink; `mv` of a symlink moves the link, not the target).
  bak="$(ls "$LINKED/.gaia/local/" | grep '^setup-state\.json\.bak\.')"
  [ -n "$bak" ]
  [ -L "$LINKED/.gaia/local/$bak" ]
  [ "$(readlink "$LINKED/.gaia/local/$bak")" = "/nonexistent/path/setup-state.json" ]

  [[ "$output" == *"linked-after-backup: $LINKED/.gaia/local/setup-state.json"* ]]
}

# ---------- 5. Main-checkout invocation ----------
@test "main checkout: emits 'not a linked worktree' and creates no symlinks" {
  run run_in "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a linked worktree"* ]]

  # No symlinks created in main.
  [ ! -L "$MAIN/.gaia/local/setup-state.json" ]
  [ ! -L "$MAIN/.gaia/local/cache/shared" ]
  [ ! -L "$MAIN/.gaia/local/audit" ]
}

# ---------- 6. Main checkout missing target directories ----------
@test "main missing targets: creates main-side dirs before symlinking" {
  # Confirm the main checkout has nothing under .gaia/.
  [ ! -d "$MAIN/.gaia" ]

  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  # Main-side targets now exist.
  [ -d "$MAIN/.gaia/local" ]
  [ -d "$MAIN/.gaia/local/audit" ]
  [ -d "$MAIN/.gaia/local/telemetry" ]
  [ -d "$MAIN/.gaia/local/cache/shared" ]

  # Symlinks resolve (no dangling).
  [ -L "$LINKED/.gaia/local/cache/shared" ]
  [ -d "$LINKED/.gaia/local/cache/shared" ] # follows symlink: dir exists.
  [ -L "$LINKED/.gaia/local/audit" ]
  [ -d "$LINKED/.gaia/local/audit" ]
  [ -L "$LINKED/.gaia/local/telemetry" ]
  [ -d "$LINKED/.gaia/local/telemetry" ]
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
  [[ "$output" == *"failed: $LINKED/.gaia/local/setup-state.json"* ]]
  [[ "$output" == *"failed: $LINKED/.gaia/local/cache/shared"* ]]
  [[ "$output" == *"failed: $LINKED/.gaia/local/audit"* ]]

  # Symlinks were NOT created (since ln was sabotaged).
  [ ! -L "$LINKED/.gaia/local/setup-state.json" ]
  [ ! -L "$LINKED/.gaia/local/cache/shared" ]
  [ ! -L "$LINKED/.gaia/local/audit" ]
}

# ---------- 8. Non-git cwd ----------
@test "not a git repo: logs and exits 0" {
  nogit="$TMPROOT/nogit"
  mkdir -p "$nogit"

  run run_in "$nogit"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a git repo"* ]]
}

# ---------- 9. Telemetry ledger durability (write-through to main) ----------
@test "telemetry: a ledger write on the worktree side lands in the main checkout" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]

  # The telemetry dir is a symlink into MAIN.
  [ -L "$LINKED/.gaia/local/telemetry" ]
  [ "$(readlink "$LINKED/.gaia/local/telemetry")" = "$MAIN/.gaia/local/telemetry" ]

  # A ledger append on the worktree side is visible in the main checkout, so a
  # worktree KICKOFF run records to the surviving main ledger (SPEC-013 UAT-008).
  printf '%s\n' '{"action":"execute","total":42}' >> "$LINKED/.gaia/local/telemetry/cost.jsonl"
  [ -f "$MAIN/.gaia/local/telemetry/cost.jsonl" ]
  [ "$(cat "$MAIN/.gaia/local/telemetry/cost.jsonl")" = '{"action":"execute","total":42}' ]
}

# ---------- 10. Fresh worktree shares root .env files, skips .env.example ----------
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

# ---------- 11. No env files in main -> no env symlinks, still exit 0 ----------
@test "env files: no env files in main means no env symlinks, still exit 0" {
  run run_in "$LINKED"
  [ "$status" -eq 0 ]
  [ ! -L "$LINKED/.env" ]

  # The five fixed symlinks still exist (no regression from the env addition).
  [ -L "$LINKED/.gaia/local/setup-state.json" ]
  [ -L "$LINKED/.gaia/local/cache/shared" ]
  [ -L "$LINKED/.gaia/local/audit" ]
  [ -L "$LINKED/.gaia/local/telemetry" ]
}

# ---------- 12. Idempotent re-run: env symlink logs "already-linked" ----------
@test "env files: idempotent re-run logs already-linked with no backups" {
  printf 'ENV_VAR=main' > "$MAIN/.env"
  run_in "$LINKED"
  run run_in "$LINKED"
  [ "$status" -eq 0 ]
  grep -qF -- "already-linked: $LINKED/.env" <<<"$output" || return 1

  run bash -c "find '$LINKED' -maxdepth 1 -name '.env.bak.*' -print"
  [ -z "$output" ]
}

# ---------- 13. Pre-existing plain .env in worktree is backed up then linked ----------
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

# ---------- 15. Editor cruft under the .env.* glob is rejected by the regex guard ----------
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
