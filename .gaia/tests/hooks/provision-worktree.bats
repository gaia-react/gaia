#!/usr/bin/env bats
#
# .claude/hooks/provision-worktree.sh: idempotent worktree provisioning.
#
# The hook answers one question -- "is the tree this session is working in a
# linked worktree, and does it hold the state a worktree needs?" -- and repairs
# what it finds. It has three callers (SessionStart, PostToolUse/EnterWorktree,
# and worktree creation calling it directly), so the cases below are organised
# by how the tree is named rather than by which caller named it: an explicit
# argument, the EnterWorktree tool_response, the payload cwd, and the process
# cwd fallback.
#
# The typegen arm is exercised through a stub `react-router` binary installed
# at the borrowed path under the main checkout, the same proxy the concurrency
# meter's C6-03 uses. A real typegen needs the app's whole dependency tree.
#
# The install arm is exercised through a stub `pnpm` binary prepended onto
# PATH, standing in for the package manager the same way the react-router
# stub stands in for typegen: a real `pnpm install` needs registry access and
# the app's whole dependency tree, neither of which a hermetic suite has.
#
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` and
# `grep -qF`, with every non-final custom check ending in an explicit
# `return 1`.

setup() {
  HOOK_ABS="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/provision-worktree.sh"
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN"
  [ -n "${PNPM_STUB_DIR:-}" ] && rm -rf "$PNPM_STUB_DIR"
  return 0
}

# make_main: a main checkout carrying the hook and the two libraries it needs,
# committed, so a linked worktree added from it checks out its own copies --
# which is how the hook runs in production, from the tree it is provisioning.
make_main() {
  MAIN=$(mktemp -d -t gaia-provision-main-XXXXXX)
  MAIN="$(cd "$MAIN" && pwd -P)"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false

  mkdir -p "$MAIN/.claude/hooks" "$MAIN/.gaia/scripts" "$MAIN/.gaia/local"
  cp "$HOOK_ABS" "$MAIN/.claude/hooks/provision-worktree.sh"
  cp "$REPO_ROOT_REAL/.gaia/scripts/main-root-lib.sh" "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT_REAL/.gaia/scripts/state-registry-lib.sh" "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT_REAL/.gaia/scripts/link-worktree.sh" "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT_REAL/.gaia/state-registry.json" "$MAIN/.gaia/"
  cp "$REPO_ROOT_REAL/.gaia/state-registry.schema.json" "$MAIN/.gaia/"
  chmod +x "$MAIN/.claude/hooks/provision-worktree.sh" "$MAIN"/.gaia/scripts/*.sh

  echo init > "$MAIN/f"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init
}

# add_worktree <name>: a linked worktree of MAIN, echoed as a physical path.
add_worktree() {
  local name="$1"
  git -C "$MAIN" worktree add -q -b "$name" "$MAIN/.claude/worktrees/$name" >/dev/null 2>&1
  ( cd "$MAIN/.claude/worktrees/$name" && pwd -P )
}

# stub_typegen: a react-router stand-in at the path the hook borrows from the
# main checkout. Stamps the tree it was run in, so the assertion can tell which
# tree typegen actually ran against.
stub_typegen() {
  mkdir -p "$MAIN/node_modules/.bin"
  cat > "$MAIN/node_modules/.bin/react-router" <<'SH'
#!/bin/sh
if [ "$1" = "typegen" ]; then
  mkdir -p .react-router/types
  pwd -P > .react-router/types/.stamp
fi
SH
  chmod +x "$MAIN/node_modules/.bin/react-router"
}

# enter_payload <tree>: the PostToolUse payload the harness emits for
# EnterWorktree -- cwd already switched, tool_response naming the path.
enter_payload() {
  jq -nc --arg p "$1" '{tool_name: "EnterWorktree", cwd: $p, tool_response: {worktreePath: $p}}'
}

# tree_key_for <tree>: the same gaia_tree_key the hook itself computes,
# derived from MAIN's own copy of the library (identical to the tree's own
# copy, since add_worktree checks it out from the same commit).
tree_key_for() {
  bash "$MAIN/.gaia/scripts/main-root-lib.sh" --tree-key "$1"
}

# add_lockfile: commits a placeholder pnpm-lock.yaml onto MAIN, so a worktree
# added afterward checks out its own copy -- the file the install step gates
# on. Content is irrelevant; the stub pnpm never reads it.
add_lockfile() {
  echo lockfile > "$MAIN/pnpm-lock.yaml"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m "add lockfile"
}

# stub_pnpm [exit_code]: a pnpm stand-in prepended onto PATH, standing in for
# the real package manager the same way stub_typegen stands in for
# react-router. Every invocation appends the cwd it ran in to PNPM_LOG, so the
# assertions can tell which tree the install ran in, and how many times it
# ran. Exits with <exit_code> (default 0).
stub_pnpm() {
  local exit_code="${1:-0}"
  PNPM_STUB_DIR="$(mktemp -d -t gaia-provision-pnpm-XXXXXX)"
  PNPM_LOG="$PNPM_STUB_DIR/pnpm.log"
  : > "$PNPM_LOG"
  cat > "$PNPM_STUB_DIR/pnpm" <<SH
#!/bin/sh
pwd -P >> "$PNPM_LOG"
exit $exit_code
SH
  chmod +x "$PNPM_STUB_DIR/pnpm"
  PATH="$PNPM_STUB_DIR:$PATH"
  export PATH
}

# ---------- 1. The direct-call form provisions the named tree ----------
@test "an explicit worktree argument is provisioned" {
  make_main
  WT="$(add_worktree feat-arg)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local" ] || return 1

  target_real="$(cd "$WT/.gaia/local" && pwd -P)"
  main_real="$(cd "$MAIN/.gaia/local" && pwd -P)"
  [ "$target_real" = "$main_real" ]
}

# ---------- 2. The EnterWorktree payload names the tree ----------
@test "the EnterWorktree tool_response names the tree to provision" {
  make_main
  WT="$(add_worktree feat-enter)"

  run bash -c "printf '%s' '$(enter_payload "$WT")' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local" ] || return 1
}

# ---------- 3. The payload cwd is used when there is no tool_response ----------
# The SessionStart payload carries a cwd and nothing else, so this is the arm
# that covers a session STARTING inside a worktree.
@test "a SessionStart payload is provisioned from its cwd" {
  make_main
  WT="$(add_worktree feat-sessionstart)"

  payload="$(jq -nc --arg p "$WT" '{hook_event_name: "SessionStart", source: "startup", cwd: $p}')"
  run bash -c "printf '%s' '$payload' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local" ] || return 1
}

# ---------- 4. The main checkout is never provisioned ----------
# The predicate, not the caller, is what decides. A SessionStart in the main
# checkout fires this hook on every startup, and it must do nothing there.
@test "the main checkout is left alone" {
  make_main

  payload="$(jq -nc --arg p "$MAIN" '{hook_event_name: "SessionStart", source: "startup", cwd: $p}')"
  run bash -c "printf '%s' '$payload' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]

  # No symlink was created over main's own real directory, and nothing was
  # logged: the hook returned before acting.
  [ -L "$MAIN/.gaia/local/audit" ] && return 1
  grep -qF -- "linked shared state" <<<"$output" && return 1
  return 0
}

# ---------- 5. Idempotent: a correct worktree survives a second run ----------
@test "provisioning an already-provisioned worktree changes nothing" {
  make_main
  WT="$(add_worktree feat-idempotent)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  before="$(cd "$WT/.gaia/local" && pwd -P)"

  # Something real must be reachable through the link, so a second run that
  # silently replaced the target rather than leaving it alone is detectable.
  echo kept > "$MAIN/.gaia/local/marker.txt"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  after="$(cd "$WT/.gaia/local" && pwd -P)"
  [ "$before" = "$after" ]
  grep -qF kept "$WT/.gaia/local/marker.txt"
}

# ---------- 6. Self-healing: a broken link is repaired ----------
# The property the phase gate names: a worktree whose links were broken by hand
# repairs itself on the next entry, with no manual step.
@test "a shared-state link broken by hand is repaired on the next entry" {
  make_main
  WT="$(add_worktree feat-selfheal)"
  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  rm -f "$WT/.gaia/local"
  mkdir -p "$WT/.gaia/local/audit"
  echo orphaned > "$WT/.gaia/local/audit/orphan.txt"

  run bash -c "printf '%s' '$(enter_payload "$WT")' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]

  [ -L "$WT/.gaia/local" ] || return 1
  target_real="$(cd "$WT/.gaia/local" && pwd -P)"
  main_real="$(cd "$MAIN/.gaia/local" && pwd -P)"
  [ "$target_real" = "$main_real" ]
}

# ---------- 7. A worktree made outside GAIA's machinery is provisioned ----------
# Plain `git worktree add` fires no creation hook, so a tree made that way has
# never been provisioned by anything. Entry is what covers it.
@test "a worktree created by plain git worktree add is provisioned on entry" {
  make_main
  WT="$(add_worktree feat-byhand)"
  [ -L "$WT/.gaia/local" ] && return 1

  run bash -c "printf '%s' '$(enter_payload "$WT")' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local" ] || return 1
}

# ---------- 8. Typed routes are generated in the worktree, not in main ----------
# The fallback arm: no lockfile means the install step never runs, so the tree
# has no CLI of its own and typegen borrows main's. The prefers-its-own arm is
# test 32, below.
@test "typegen falls back to the main checkout's CLI when the tree has none of its own" {
  make_main
  stub_typegen
  WT="$(add_worktree feat-typegen)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  [ -f "$WT/.react-router/types/.stamp" ] || return 1
  # The stamp records the cwd typegen ran in: the worktree, never main.
  [ "$(cat "$WT/.react-router/types/.stamp")" = "$WT" ]
  [ -f "$MAIN/.react-router/types/.stamp" ] && return 1
  return 0
}

# ---------- 9. Typed routes are refreshed, not merely created ----------
# The property a create-time-only run cannot hold: the types must be CURRENT,
# so a stale copy is regenerated rather than left because a file exists.
@test "stale typed routes are regenerated on entry" {
  make_main
  stub_typegen
  # The tree's name must not contain the marker word below: the stamp records
  # the worktree's own path, so a tree named for the marker would match it and
  # the assertion would pass without typegen having run at all.
  WT="$(add_worktree feat-refresh)"

  mkdir -p "$WT/.react-router/types"
  echo LEFTOVER > "$WT/.react-router/types/.stamp"

  run bash -c "printf '%s' '$(enter_payload "$WT")' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  grep -qF LEFTOVER "$WT/.react-router/types/.stamp" && return 1
  [ "$(cat "$WT/.react-router/types/.stamp")" = "$WT" ]
}

# ---------- 10. A checkout with nothing installed is not a failure ----------
@test "a main checkout with no installed CLI provisions links and skips typegen" {
  make_main
  WT="$(add_worktree feat-nocli)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local" ] || return 1
  [ -e "$WT/.react-router/types/.stamp" ] && return 1
  return 0
}

# ---------- 11. A non-repository path is not provisioned ----------
@test "a path outside any checkout is left alone" {
  make_main
  outside="$(mktemp -d -t gaia-provision-outside-XXXXXX)"

  run bash "$HOOK_ABS" "$outside"
  [ "$status" -eq 0 ]
  [ -e "$outside/.gaia" ] && { rm -rf "$outside"; return 1; }
  rm -rf "$outside"
  return 0
}

# ---------- 12. A relative payload value never reaches `cd` ----------
# The value reaches a bare `cd`, which would option-parse a leading dash and
# succeed into the wrong directory, so only an absolute path is honored.
@test "a relative tree argument is refused rather than resolved" {
  make_main
  WT="$(add_worktree feat-relative)"

  run bash "$HOOK_ABS" "some/relative/path"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local/audit" ] && return 1
  return 0
}

# ---------- 13. Carry-forward: red-ledger, the case the phase exists for ----------
@test "unkeyed red-ledger data is carried forward to the keyed path, byte for byte" {
  make_main
  WT="$(add_worktree feat-carry-red)"
  mkdir -p "$WT/.gaia/local/red-ledger"
  printf '{"a":1}\n{"a":2}\n' > "$WT/.gaia/local/red-ledger/observations.jsonl"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  key="$(tree_key_for "$WT")"
  [ -f "$WT/.gaia/local/red-ledger/$key/observations.jsonl" ] || return 1
  [ -e "$WT/.gaia/local/red-ledger/observations.jsonl" ] && return 1
  diff <(printf '{"a":1}\n{"a":2}\n') "$WT/.gaia/local/red-ledger/$key/observations.jsonl"
}

# ---------- 14. Carry-forward is idempotent ----------
@test "carrying forward the RED ledger twice loses nothing on the second run" {
  make_main
  WT="$(add_worktree feat-carry-red-twice)"
  mkdir -p "$WT/.gaia/local/red-ledger"
  printf 'line-one\n' > "$WT/.gaia/local/red-ledger/observations.jsonl"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  key="$(tree_key_for "$WT")"
  [ -f "$WT/.gaia/local/red-ledger/$key/observations.jsonl" ] || return 1

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ "$(cat "$WT/.gaia/local/red-ledger/$key/observations.jsonl")" = "line-one" ]
  [ -e "$WT/.gaia/local/red-ledger/observations.jsonl" ] && return 1
  return 0
}

# ---------- 15. Carry-forward never overwrites keyed data ----------
@test "keyed red-ledger data already present is never overwritten by stale unkeyed data" {
  make_main
  WT="$(add_worktree feat-carry-red-noclobber)"
  key="$(tree_key_for "$WT")"
  mkdir -p "$WT/.gaia/local/red-ledger/$key"
  echo keyed > "$WT/.gaia/local/red-ledger/$key/observations.jsonl"
  mkdir -p "$WT/.gaia/local/red-ledger"
  echo stale > "$WT/.gaia/local/red-ledger/observations.jsonl"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  # The keyed data survives untouched, reached through the worktree's new
  # symlink into main's .gaia/local: migrate_keyed_subtrees_to_main moved it
  # there, never overwriting it.
  [ "$(cat "$WT/.gaia/local/red-ledger/$key/observations.jsonl")" = "keyed" ]

  # The stale unkeyed file was carry-forward's to move, and carry-forward
  # declined because the keyed file already existed -- so it was never
  # touched, and it rides along inside the whole pre-cutover .gaia/local that
  # the linker backs up wholesale, unread and unmerged, when it replaces it
  # with the symlink. It survives there, not at the live (now-symlinked) path.
  backup_dir=""
  for d in "$WT"/.gaia/local.bak.*; do
    [ -d "$d" ] && backup_dir="$d"
  done
  [ -n "$backup_dir" ] || return 1
  [ "$(cat "$backup_dir/red-ledger/observations.jsonl")" = "stale" ]
}

# ---------- 16. A symlinked .gaia/local disables the step entirely ----------
# The gate this test exercises exists for a change not yet landed: a linked
# worktree's whole .gaia/local becomes one symlink to main's. Simulated here
# with a symlink to an independent directory (not MAIN's own .gaia/local) so
# the assertion isolates the carry-forward step from link-worktree.sh's own,
# separately-owned behavior toward a symlinked .gaia/local.
@test "a symlinked .gaia/local skips the carry-forward step entirely" {
  make_main
  WT="$(add_worktree feat-carry-symlink)"
  target_dir="$(mktemp -d -t gaia-provision-symlink-target-XXXXXX)"
  mkdir -p "$target_dir/red-ledger"
  echo untouched > "$target_dir/red-ledger/observations.jsonl"
  rm -rf "$WT/.gaia/local"
  ln -s "$target_dir" "$WT/.gaia/local"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  key="$(tree_key_for "$WT")"
  if [ -e "$target_dir/red-ledger/$key" ]; then
    rm -rf "$target_dir"
    return 1
  fi
  if [ "$(cat "$target_dir/red-ledger/observations.jsonl")" != "untouched" ]; then
    rm -rf "$target_dir"
    return 1
  fi
  rm -rf "$target_dir"
  return 0
}

# ---------- 17. The main checkout's own unkeyed data is rescued too ----------
# The case the early gate would otherwise miss: nothing else runs at main's
# own session start to carry this forward.
@test "the main checkout's own unkeyed data is carried forward" {
  make_main
  mkdir -p "$MAIN/.gaia/local/red-ledger"
  echo main-red > "$MAIN/.gaia/local/red-ledger/observations.jsonl"

  payload="$(jq -nc --arg p "$MAIN" '{hook_event_name: "SessionStart", source: "startup", cwd: $p}')"
  run bash -c "printf '%s' '$payload' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]

  key="$(tree_key_for "$MAIN")"
  [ -f "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl" ] || return 1
  [ "$(cat "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl")" = "main-red" ]
  [ -e "$MAIN/.gaia/local/red-ledger/observations.jsonl" ] && return 1
  return 0
}

# ---------- 18. Nothing to migrate is silent ----------
@test "nothing to migrate is a silent no-op" {
  make_main
  WT="$(add_worktree feat-carry-nothing)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  grep -qF -- "CARRY-FORWARD" <<<"$output" && return 1
  grep -qF -- "carried forward" <<<"$output" && return 1
  return 0
}

# ---------- 19. The worthiness-ledger sibling migrates the same way ----------
@test "unkeyed worthiness-ledger data is carried forward to the keyed path" {
  make_main
  WT="$(add_worktree feat-carry-worthiness)"
  mkdir -p "$WT/.gaia/local/worthiness-ledger"
  echo worth-data > "$WT/.gaia/local/worthiness-ledger/worthiness.jsonl"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  key="$(tree_key_for "$WT")"
  [ -f "$WT/.gaia/local/worthiness-ledger/$key/worthiness.jsonl" ] || return 1
  [ "$(cat "$WT/.gaia/local/worthiness-ledger/$key/worthiness.jsonl")" = "worth-data" ]
}

# ---------- 20. forensics/: the multi-file, loosely-named directory shape ----------
@test "unkeyed forensics reports are carried forward to the keyed subdirectory" {
  make_main
  WT="$(add_worktree feat-carry-forensics)"
  mkdir -p "$WT/.gaia/local/forensics"
  echo report-one > "$WT/.gaia/local/forensics/20260101T000000Z-hook.md"
  echo report-two > "$WT/.gaia/local/forensics/20260102T000000Z-hook.md"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  key="$(tree_key_for "$WT")"
  [ "$(cat "$WT/.gaia/local/forensics/$key/20260101T000000Z-hook.md")" = "report-one" ]
  [ "$(cat "$WT/.gaia/local/forensics/$key/20260102T000000Z-hook.md")" = "report-two" ]
  [ -e "$WT/.gaia/local/forensics/20260101T000000Z-hook.md" ] && return 1
  [ -e "$WT/.gaia/local/forensics/20260102T000000Z-hook.md" ] && return 1
  return 0
}

# ---------- 21. forensics/: never overwrites a keyed file with a stale one ----------
@test "keyed forensics data already present is never overwritten by stale unkeyed data" {
  make_main
  WT="$(add_worktree feat-carry-forensics-noclobber)"
  key="$(tree_key_for "$WT")"
  mkdir -p "$WT/.gaia/local/forensics/$key"
  echo keyed-report > "$WT/.gaia/local/forensics/$key/20260101T000000Z-hook.md"
  mkdir -p "$WT/.gaia/local/forensics"
  echo stale-report > "$WT/.gaia/local/forensics/20260101T000000Z-hook.md"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  # The keyed report survives untouched, reached through the worktree's new
  # symlink into main's .gaia/local.
  [ "$(cat "$WT/.gaia/local/forensics/$key/20260101T000000Z-hook.md")" = "keyed-report" ]

  # Same reasoning as the red-ledger sibling: carry-forward declined to move
  # the stale unkeyed report because the keyed one already existed, so it
  # rides along inside the whole pre-cutover .gaia/local the linker backs up
  # wholesale, unread and unmerged.
  backup_dir=""
  for d in "$WT"/.gaia/local.bak.*; do
    [ -d "$d" ] && backup_dir="$d"
  done
  [ -n "$backup_dir" ] || return 1
  [ "$(cat "$backup_dir/forensics/20260101T000000Z-hook.md")" = "stale-report" ]
}

# ---------- 22. handoff/: the fourth entry, same directory shape as forensics ----------
@test "unkeyed handoff data is carried forward to the keyed subdirectory" {
  make_main
  WT="$(add_worktree feat-carry-handoff)"
  mkdir -p "$WT/.gaia/local/handoff"
  echo handoff-body > "$WT/.gaia/local/handoff/HANDOFF-2026-01-01-x.md"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  key="$(tree_key_for "$WT")"
  [ "$(cat "$WT/.gaia/local/handoff/$key/HANDOFF-2026-01-01-x.md")" = "handoff-body" ]
  [ -e "$WT/.gaia/local/handoff/HANDOFF-2026-01-01-x.md" ] && return 1
  return 0
}

# ---------- 23. migrate_keyed_subtrees_to_main: the cutover-migration half ----------
# A linked worktree still holding a REAL .gaia/local (pre-cutover, already
# tree-keyed by an earlier session) must have its keyed per-tree subtrees
# rescued into main's .gaia/local before the linker backs the whole directory
# up to .gaia/local.bak.<ts> and replaces it with the one shared symlink --
# otherwise the data ends up inside a backup nothing reads.
@test "pre-cutover keyed data migrates into main's .gaia/local, byte for byte, reachable through the new symlink" {
  make_main
  WT="$(add_worktree feat-migrate-basic)"
  key="$(tree_key_for "$WT")"
  mkdir -p "$WT/.gaia/local/red-ledger/$key" "$WT/.gaia/local/forensics/$key"
  printf '{"a":1}\n{"a":2}\n' > "$WT/.gaia/local/red-ledger/$key/observations.jsonl"
  echo forensic-body > "$WT/.gaia/local/forensics/$key/20260101T000000Z-hook.md"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  # Landed in MAIN's own .gaia/local, byte for byte.
  diff <(printf '{"a":1}\n{"a":2}\n') "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl"
  [ "$(cat "$MAIN/.gaia/local/forensics/$key/20260101T000000Z-hook.md")" = "forensic-body" ]

  # Reachable from the worktree through the new single symlink too.
  [ -L "$WT/.gaia/local" ] || return 1
  diff <(printf '{"a":1}\n{"a":2}\n') "$WT/.gaia/local/red-ledger/$key/observations.jsonl"
  [ "$(cat "$WT/.gaia/local/forensics/$key/20260101T000000Z-hook.md")" = "forensic-body" ]
}

# ---------- 24. migrate_keyed_subtrees_to_main is idempotent ----------
@test "migrate_keyed_subtrees_to_main is idempotent: a second run changes nothing" {
  make_main
  WT="$(add_worktree feat-migrate-idempotent)"
  key="$(tree_key_for "$WT")"
  mkdir -p "$WT/.gaia/local/red-ledger/$key"
  echo line-one > "$WT/.gaia/local/red-ledger/$key/observations.jsonl"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ "$(cat "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl")" = "line-one" ]

  # After the first run .gaia/local is a symlink, so the migration gate skips
  # entirely -- the second run must neither re-log a migration nor disturb
  # what the first run already moved.
  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  grep -qF -- "migrated red-ledger/$key into the main checkout" <<<"$output" && return 1
  [ "$(cat "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl")" = "line-one" ]
  [ "$(cat "$WT/.gaia/local/red-ledger/$key/observations.jsonl")" = "line-one" ]
}

# ---------- 25. A destination that already exists is skipped, not merged ----------
@test "a destination that already exists in main is skipped, not overwritten, not merged, and logged loudly" {
  make_main
  WT="$(add_worktree feat-migrate-conflict)"
  key="$(tree_key_for "$WT")"

  mkdir -p "$MAIN/.gaia/local/red-ledger/$key"
  echo main-data > "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl"

  mkdir -p "$WT/.gaia/local/red-ledger/$key"
  echo worktree-data > "$WT/.gaia/local/red-ledger/$key/observations.jsonl"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  grep -qF -- "CUTOVER MIGRATION SKIPPED: red-ledger/$key exists in both this worktree and the main checkout" <<<"$output" || return 1

  # Main's own data is untouched -- not overwritten, not merged.
  [ "$(cat "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl")" = "main-data" ]

  # The worktree's copy is untouched by the migration step itself; it only
  # leaves the live worktree path when the linker backs up the whole
  # pre-cutover .gaia/local afterward, unread and unmerged.
  backup_dir=""
  for d in "$WT"/.gaia/local.bak.*; do
    [ -d "$d" ] && backup_dir="$d"
  done
  [ -n "$backup_dir" ] || return 1
  [ "$(cat "$backup_dir/red-ledger/$key/observations.jsonl")" = "worktree-data" ]
}

# ---------- 26. The main checkout itself is never migrated ----------
@test "the main checkout itself is never migrated -- it is not a linked worktree" {
  make_main
  key="$(tree_key_for "$MAIN")"
  mkdir -p "$MAIN/.gaia/local/red-ledger/$key"
  echo main-own-data > "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl"

  payload="$(jq -nc --arg p "$MAIN" '{hook_event_name: "SessionStart", source: "startup", cwd: $p}')"
  run bash -c "printf '%s' '$payload' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]

  grep -qF -- "CUTOVER MIGRATION" <<<"$output" && return 1
  [ "$(cat "$MAIN/.gaia/local/red-ledger/$key/observations.jsonl")" = "main-own-data" ]
  [ -L "$MAIN/.gaia/local" ] && return 1
  return 0
}

# ---------- 27. Dependencies are installed on entry when a lockfile is present ----------
@test "dependencies are installed on entry when a lockfile is present" {
  make_main
  add_lockfile
  stub_pnpm
  WT="$(add_worktree feat-install)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ -s "$PNPM_LOG" ] || return 1
  # The stub records the cwd it ran in: the worktree, never main.
  [ "$(cat "$PNPM_LOG")" = "$WT" ]
}

# ---------- 28. The install runs on EVERY entry, not only when node_modules is absent ----------
@test "dependencies are installed on every entry, not only when node_modules is absent" {
  make_main
  add_lockfile
  stub_pnpm
  WT="$(add_worktree feat-install-every)"
  mkdir -p "$WT/node_modules"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PNPM_LOG" | tr -d ' ')" = "1" ] || return 1

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PNPM_LOG" | tr -d ' ')" = "2" ]
}

# ---------- 29. No lockfile: no install attempted, linking and typegen still happen ----------
@test "no lockfile means no install is attempted, and linking plus typegen still happen" {
  make_main
  stub_typegen
  stub_pnpm
  WT="$(add_worktree feat-nolock)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ -s "$PNPM_LOG" ] && return 1
  [ -L "$WT/.gaia/local" ] || return 1
  [ -f "$WT/.react-router/types/.stamp" ]
}

# ---------- 30. pnpm absent from PATH: logged, non-fatal, typegen still runs ----------
@test "pnpm absent from PATH: install is skipped, logged, non-fatal, and typegen still runs" {
  make_main
  add_lockfile
  stub_typegen
  WT="$(add_worktree feat-nopnpm)"

  # Strip only the directory the resolved `pnpm` binary lives in, leaving
  # every other tool the hook needs (bash, git, jq, coreutils) resolvable --
  # a curated allowlist would have to name every tool the hook and its
  # libraries call and rot the moment one more is added. When pnpm is already
  # absent (as it is at this point in CI, before the dependency-install
  # steps later in the job), stripping is a no-op and the case is already
  # naturally in effect.
  pnpm_path="$(command -v pnpm 2>/dev/null)" || pnpm_path=""
  filtered_path="$PATH"
  if [ -n "$pnpm_path" ]; then
    pnpm_dir="$(dirname "$pnpm_path")"
    filtered_path="${filtered_path//$pnpm_dir:/}"
    filtered_path="${filtered_path%:$pnpm_dir}"
  fi

  PATH="$filtered_path" run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  grep -qF -- "no pnpm found on PATH" <<<"$output" || return 1
  [ -f "$WT/.react-router/types/.stamp" ]
}

# ---------- 31. The install exiting non-zero is logged, non-fatal, typegen still runs ----------
@test "the install exiting non-zero is logged, non-fatal, and typegen still runs" {
  make_main
  add_lockfile
  stub_typegen
  stub_pnpm 1
  WT="$(add_worktree feat-installfail)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  grep -qF -- "INSTALL FAILED for $WT" <<<"$output" || return 1
  [ -f "$WT/.react-router/types/.stamp" ]
}

# ---------- 32. Typegen prefers the tree's own CLI when one is present ----------
# The other half of test 8's pair: when the tree HAS its own CLI, it is used
# instead of main's borrowed one, even though main's is also present here.
@test "typegen prefers the tree's own CLI when one is present" {
  make_main
  stub_typegen
  WT="$(add_worktree feat-typegen-own)"

  mkdir -p "$WT/node_modules/.bin"
  cat > "$WT/node_modules/.bin/react-router" <<'SH'
#!/bin/sh
if [ "$1" = "typegen" ]; then
  mkdir -p .react-router/types
  echo own-cli > .react-router/types/.stamp
fi
SH
  chmod +x "$WT/node_modules/.bin/react-router"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ "$(cat "$WT/.react-router/types/.stamp")" = "own-cli" ]
}
