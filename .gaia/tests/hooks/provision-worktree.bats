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
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` and
# `grep -qF`, with every non-final custom check ending in an explicit
# `return 1`.

setup() {
  HOOK_ABS="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/provision-worktree.sh"
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN"
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

# ---------- 1. The direct-call form provisions the named tree ----------
@test "an explicit worktree argument is provisioned" {
  make_main
  WT="$(add_worktree feat-arg)"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local/audit" ] || return 1

  target_real="$(cd "$WT/.gaia/local/audit" && pwd -P)"
  main_real="$(cd "$MAIN/.gaia/local/audit" && pwd -P)"
  [ "$target_real" = "$main_real" ]
}

# ---------- 2. The EnterWorktree payload names the tree ----------
@test "the EnterWorktree tool_response names the tree to provision" {
  make_main
  WT="$(add_worktree feat-enter)"

  run bash -c "printf '%s' '$(enter_payload "$WT")' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local/audit" ] || return 1
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
  [ -L "$WT/.gaia/local/audit" ] || return 1
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
  before="$(cd "$WT/.gaia/local/audit" && pwd -P)"

  # Something real must be reachable through the link, so a second run that
  # silently replaced the target rather than leaving it alone is detectable.
  echo kept > "$MAIN/.gaia/local/audit/marker.txt"

  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]
  after="$(cd "$WT/.gaia/local/audit" && pwd -P)"
  [ "$before" = "$after" ]
  grep -qF kept "$WT/.gaia/local/audit/marker.txt"
}

# ---------- 6. Self-healing: a broken link is repaired ----------
# The property the phase gate names: a worktree whose links were broken by hand
# repairs itself on the next entry, with no manual step.
@test "a shared-state link broken by hand is repaired on the next entry" {
  make_main
  WT="$(add_worktree feat-selfheal)"
  run bash "$HOOK_ABS" "$WT"
  [ "$status" -eq 0 ]

  rm -f "$WT/.gaia/local/audit"
  mkdir -p "$WT/.gaia/local/audit"
  echo orphaned > "$WT/.gaia/local/audit/orphan.txt"

  run bash -c "printf '%s' '$(enter_payload "$WT")' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]

  [ -L "$WT/.gaia/local/audit" ] || return 1
  target_real="$(cd "$WT/.gaia/local/audit" && pwd -P)"
  main_real="$(cd "$MAIN/.gaia/local/audit" && pwd -P)"
  [ "$target_real" = "$main_real" ]
}

# ---------- 7. A worktree made outside GAIA's machinery is provisioned ----------
# Plain `git worktree add` fires no creation hook, so a tree made that way has
# never been provisioned by anything. Entry is what covers it.
@test "a worktree created by plain git worktree add is provisioned on entry" {
  make_main
  WT="$(add_worktree feat-byhand)"
  [ -L "$WT/.gaia/local/audit" ] && return 1

  run bash -c "printf '%s' '$(enter_payload "$WT")' | bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -L "$WT/.gaia/local/audit" ] || return 1
}

# ---------- 8. Typed routes are generated in the worktree, not in main ----------
@test "typegen runs against the worktree, borrowing the main checkout's CLI" {
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
  [ -L "$WT/.gaia/local/audit" ] || return 1
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

  [ "$(cat "$WT/.gaia/local/red-ledger/$key/observations.jsonl")" = "keyed" ]
  [ -f "$WT/.gaia/local/red-ledger/observations.jsonl" ] || return 1
  [ "$(cat "$WT/.gaia/local/red-ledger/observations.jsonl")" = "stale" ]
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

  [ "$(cat "$WT/.gaia/local/forensics/$key/20260101T000000Z-hook.md")" = "keyed-report" ]
  [ -f "$WT/.gaia/local/forensics/20260101T000000Z-hook.md" ] || return 1
  [ "$(cat "$WT/.gaia/local/forensics/20260101T000000Z-hook.md")" = "stale-report" ]
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
