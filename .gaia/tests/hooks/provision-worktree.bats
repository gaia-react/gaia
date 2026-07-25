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
