#!/usr/bin/env bats
#
# Suite for .gaia/scripts/storybook-launch.sh: the refusals (no port file, port
# taken on each address family) and the launch itself, with a stub `storybook`
# on PATH that records how it was called. Fixtures are throwaway git repos with
# real linked worktrees under $BATS_TEST_TMPDIR, each carrying copies of the
# scripts under test.
#
# Run: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/storybook-launch.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LISTENER="$REPO_ROOT/.gaia/tests/fixtures/ports/listen.mjs"
  export GAIA_PORTS_STATE_DIRECTORY="$BATS_TEST_TMPDIR/state"
  unset GAIA_PORTS_DEV_BASE_PORT GAIA_PORTS_STORYBOOK_BASE_PORT SITE_URL CLAUDE_CODE_SESSION_ID PORT SBCONFIG_PORT
  mkdir -p "$BATS_TEST_TMPDIR/main/frontend" "$BATS_TEST_TMPDIR/trees" "$BATS_TEST_TMPDIR/bin"
  git init -q -b main "$BATS_TEST_TMPDIR/main"
  FIXTURE_MAIN="$(cd "$BATS_TEST_TMPDIR/main" && pwd -P)"
  : >"$FIXTURE_MAIN/frontend/react-router.config.ts"
  mkdir -p "$FIXTURE_MAIN/.gaia/scripts" "$FIXTURE_MAIN/.claude/hooks/lib"
  cp "$REPO_ROOT"/.gaia/scripts/{storybook-launch,ports,worktree-ports-lib,server-process-lib,main-root-lib}.sh "$FIXTURE_MAIN/.gaia/scripts/"
  cp "$REPO_ROOT"/.claude/hooks/lib/*.sh "$FIXTURE_MAIN/.claude/hooks/lib/"
  git -C "$FIXTURE_MAIN" add -A
  git -C "$FIXTURE_MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q -m base
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"%s"\nprintf "PORT=%%s SBCONFIG_PORT=%%s\\n" "${PORT-unset}" "${SBCONFIG_PORT-unset}" >>"%s"\n' "$STUB_LOG" "$STUB_LOG" >"$BATS_TEST_TMPDIR/bin/storybook"
  chmod +x "$BATS_TEST_TMPDIR/bin/storybook"
  LISTENER_PIDS=""
}

teardown() {
  for pid in $LISTENER_PIDS; do kill "$pid" 2>/dev/null || true; done
  return 0
}

launch_in() {
  ( cd "$1/frontend" && PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$1/.gaia/scripts/storybook-launch.sh" "${@:2}" )
}

linked_worktree() {
  git -C "$FIXTURE_MAIN" worktree add -q -b "$1" "$BATS_TEST_TMPDIR/trees/$1" >/dev/null 2>&1 || return 1
  ( cd "$BATS_TEST_TMPDIR/trees/$1" && pwd -P )
}

# provisioned_worktree <name> <slot> <storybook-port>
provisioned_worktree() {
  tree="$(linked_worktree "$1")" || return 1
  cp -R "$FIXTURE_MAIN/.gaia" "$tree/" && mkdir -p "$tree/.claude/hooks" && cp -R "$FIXTURE_MAIN/.claude/hooks/lib" "$tree/.claude/hooks/"
  printf 'GAIA_PORT_SLOT=%s\nDEV_PORT=%s\nSTORYBOOK_PORT=%s\nSITE_URL=http://localhost:%s\n' "$2" "$((5173 + $2))" "$3" "$((5173 + $2))" >"$tree/frontend/.gaia-ports"
  printf '%s\n' "$tree"
}

start_listener() {
  local out="$BATS_TEST_TMPDIR/listener.out"
  : >"$out"
  node "$LISTENER" "$1" "$2" >"$out" 2>&1 &
  LISTENER_PIDS="$LISTENER_PIDS $!"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q '^listening ' "$out" && return 0
    sleep 0.25
  done
  return 1
}

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

@test "linked worktree with no port file: exit 3, missing-file message, storybook never called" {
  tree="$(linked_worktree bare)"
  cp -R "$FIXTURE_MAIN/.gaia" "$tree/"
  run launch_in "$tree"
  [ "$status" -eq 3 ]
  case "$output" in *"is a linked worktree with no port file"*) ;; *) return 1 ;; esac
  case "$output" in *"Never stop a process on a port another live tree owns without asking the user first."*) ;; *) return 1 ;; esac
  [ ! -e "$STUB_LOG" ]
}

@test "port taken on 127.0.0.1: exit 1, message names the port and the ask-first sentence, storybook never called" {
  port="$(free_port)"
  tree="$(provisioned_worktree taken 1 "$port")"
  start_listener "$port" 127.0.0.1
  run launch_in "$tree"
  [ "$status" -eq 1 ]
  case "$output" in *"port $port, this tree's Storybook port, is already in use"*) ;; *) return 1 ;; esac
  case "$output" in *"Never stop a process on a port another live tree owns without asking the user first."*) ;; *) return 1 ;; esac
  [ ! -e "$STUB_LOG" ]
}

@test "port taken on ::1: exit 1 and storybook never called" {
  port="$(free_port)"
  tree="$(provisioned_worktree takensix 1 "$port")"
  if ! start_listener "$port" ::1; then skip "this host has no IPv6 loopback"; fi
  run launch_in "$tree"
  [ "$status" -eq 1 ]
  case "$output" in *"port $port, this tree's Storybook port, is already in use"*) ;; *) return 1 ;; esac
  [ ! -e "$STUB_LOG" ]
}

@test "free port: storybook gets dev -p <port> --exact-port plus passed-through args, PORT and SBCONFIG_PORT set to the port" {
  port="$(free_port)"
  tree="$(provisioned_worktree free 1 "$port")"
  PORT=9999 SBCONFIG_PORT=8888 run launch_in "$tree" --ci
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$STUB_LOG")" = "dev -p $port --exact-port --ci" ]
  [ "$(sed -n 2p "$STUB_LOG")" = "PORT=$port SBCONFIG_PORT=$port" ]
}

@test "main checkout: storybook gets -p 6006 --exact-port" {
  if node -e 'const s=require("net").createServer();s.once("error",()=>process.exit(1));s.listen(6006,"127.0.0.1",()=>s.close())' 2>/dev/null; then :; else skip "port 6006 is in use on this host"; fi
  run launch_in "$FIXTURE_MAIN"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$STUB_LOG")" = "dev -p 6006 --exact-port" ]
}
