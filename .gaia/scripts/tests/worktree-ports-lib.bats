#!/usr/bin/env bats
#
# Suite for .gaia/scripts/worktree-ports-lib.sh: the slot ledger, lock, reclaim
# predicate, stale-marker retirement, port file and SITE_URL derivation.
# Fixtures are throwaway git repositories with real linked worktrees under
# $BATS_TEST_TMPDIR; GAIA_PORTS_STATE_DIRECTORY keeps state out of this repository.
#
# Run: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/worktree-ports-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/worktree-ports-lib.sh"
  STATE="$BATS_TEST_TMPDIR/state"
  export GAIA_PORTS_STATE_DIRECTORY="$STATE"
  unset GAIA_PORTS_DEV_BASE_PORT GAIA_PORTS_STORYBOOK_BASE_PORT SITE_URL
  mkdir -p "$BATS_TEST_TMPDIR/main/frontend" "$BATS_TEST_TMPDIR/trees"
  git init -q -b main "$BATS_TEST_TMPDIR/main"
  FIXTURE_MAIN="$(cd "$BATS_TEST_TMPDIR/main" && pwd -P)"
  : >"$FIXTURE_MAIN/frontend/react-router.config.ts"
  fixture_git add -A
  fixture_git commit -q -m base
}

fixture_git() {
  git -C "$FIXTURE_MAIN" -c user.email=gaia-test@example.com -c user.name="GAIA Test" -c commit.gpgsign=false "$@"
}

# add_worktree <name>: a linked worktree; prints its physical path.
add_worktree() {
  fixture_git worktree add -q -b "$1" "$BATS_TEST_TMPDIR/trees/$1" >/dev/null 2>&1 || return 1
  ( cd "$BATS_TEST_TMPDIR/trees/$1" && pwd -P )
}

ledger_line_count_for_slot() {
  grep -c -- "^$1"$'\t' "$STATE/slots.tsv"
}

@test "assign: first tree gets 1, second gets 2, re-assigning the first is byte-identical" {
  tree_one="$(add_worktree one)"
  tree_two="$(add_worktree two)"
  run gaia_ports_assign_slot "$STATE" "$tree_one"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run gaia_ports_assign_slot "$STATE" "$tree_two"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  cp "$STATE/slots.tsv" "$BATS_TEST_TMPDIR/before.tsv"
  run gaia_ports_assign_slot "$STATE" "$tree_one"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  cmp -s "$STATE/slots.tsv" "$BATS_TEST_TMPDIR/before.tsv"
}

@test "reclaim: removed directories are retired with tombstones, locked or not" {
  tree_a="$(add_worktree a)"
  tree_b="$(add_worktree b)"
  tree_c="$(add_worktree c)"
  tree_d="$(add_worktree d)"
  for tree in "$tree_a" "$tree_b" "$tree_c" "$tree_d"; do
    gaia_ports_assign_slot "$STATE" "$tree" >/dev/null
  done
  fixture_git worktree lock "$tree_b"
  fixture_git worktree lock "$tree_c"
  rm -rf "$tree_a" "$tree_b"

  run gaia_ports_reclaim "$STATE" "$FIXTURE_MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\t%s\n2\t%s' "$tree_a" "$tree_b")" ]

  # The locked tree with an existing directory and the plain registered tree survive.
  grep -qF -- "$tree_c" "$STATE/slots.tsv"
  grep -qF -- "$tree_d" "$STATE/slots.tsv"
  grep -qF -- "$tree_a" "$STATE/slots.tsv" && return 1
  grep -qF -- "$tree_b" "$STATE/slots.tsv" && return 1

  now="$(date +%s)"
  for expected in "1 $tree_a" "2 $tree_b"; do
    slot="${expected%% *}"
    root="${expected#* }"
    tombstone="$(ls "$STATE"/tombstones/"$slot".*.tsv)"
    [ -f "$tombstone" ]
    IFS=$'\t' read -r recorded_slot recorded_root recorded_epoch <"$tombstone"
    [ "$recorded_slot" = "$slot" ]
    [ "$recorded_root" = "$root" ]
    [ "$tombstone" = "$STATE/tombstones/$slot.$recorded_epoch.tsv" ]
    [ "$((now - recorded_epoch))" -le 10 ]
    [ "$((now - recorded_epoch))" -ge -2 ]
  done
}

@test "reclaim: an entry for a path git does not list is removed though its directory exists" {
  tree_one="$(add_worktree one)"
  gaia_ports_assign_slot "$STATE" "$tree_one" >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/stranger"
  stranger="$(cd "$BATS_TEST_TMPDIR/stranger" && pwd -P)"
  printf '7\t%s\tmarker\n' "$stranger" >>"$STATE/slots.tsv"

  run gaia_ports_reclaim "$STATE" "$FIXTURE_MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '7\t%s' "$stranger")" ]
  [ -d "$stranger" ]
  grep -qF -- "$stranger" "$STATE/slots.tsv" && return 1
  grep -qF -- "$tree_one" "$STATE/slots.tsv"
}

@test "reclaim: git failing to list worktrees changes nothing" {
  tree_one="$(add_worktree one)"
  gaia_ports_assign_slot "$STATE" "$tree_one" >/dev/null
  cp "$STATE/slots.tsv" "$BATS_TEST_TMPDIR/before.tsv"
  run gaia_ports_reclaim "$STATE" "$BATS_TEST_TMPDIR/not-a-repository"
  [ "$status" -eq 1 ]
  cmp -s "$STATE/slots.tsv" "$BATS_TEST_TMPDIR/before.tsv"
}

@test "assign: the lowest free slot is reused after reclaim and appears once" {
  tree_one="$(add_worktree one)"
  tree_two="$(add_worktree two)"
  gaia_ports_assign_slot "$STATE" "$tree_one" >/dev/null
  gaia_ports_assign_slot "$STATE" "$tree_two" >/dev/null
  rm -rf "$tree_one"
  gaia_ports_reclaim "$STATE" "$FIXTURE_MAIN" >/dev/null
  tree_three="$(add_worktree three)"
  run gaia_ports_assign_slot "$STATE" "$tree_three"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ "$(ledger_line_count_for_slot 1)" -eq 1 ]
  [ "$(ledger_line_count_for_slot 2)" -eq 1 ]
}

@test "assign: a foreign listener on a dev or Storybook port skips the slot for a new tree" {
  gaia_server_listener_owner() {
    printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/probe.log"
    if [ "$1" = "$FOREIGN_PORT" ]; then
      printf 'foreign 123 /elsewhere\n'
    else
      printf 'free\n'
    fi
  }
  tree_one="$(add_worktree one)"
  tree_two="$(add_worktree two)"
  tree_three="$(add_worktree three)"

  FOREIGN_PORT=5174
  run gaia_ports_assign_slot "$STATE" "$tree_one"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  FOREIGN_PORT=none
  run gaia_ports_assign_slot "$STATE" "$tree_two"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # An existing holder keeps its slot with no probe even while the port reads foreign.
  FOREIGN_PORT=5174
  rm -f "$BATS_TEST_TMPDIR/probe.log"
  run gaia_ports_assign_slot "$STATE" "$tree_two"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ -e "$BATS_TEST_TMPDIR/probe.log" ] && return 1

  # A Storybook port held by a foreign listener skips the slot as well.
  FOREIGN_PORT=6009
  run gaia_ports_assign_slot "$STATE" "$tree_three"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "stale marker: a recreated worktree is retired by its marker and assigned afresh" {
  tree_one="$(add_worktree one)"
  gaia_ports_assign_slot "$STATE" "$tree_one" >/dev/null
  marker_before="$(gaia_ports_tree_marker "$tree_one")"
  fixture_git worktree remove --force "$tree_one"
  sleep 1.1
  fixture_git worktree add -q -b recreated "$tree_one" >/dev/null 2>&1
  marker_after="$(gaia_ports_tree_marker "$tree_one")"
  [ -n "$marker_before" ]
  [ -n "$marker_after" ]
  [ "$marker_before" != "$marker_after" ]

  run gaia_ports_retire_stale_entry "$STATE" "$tree_one"
  [ "$status" -eq 0 ]
  grep -qF -- "$tree_one" "$STATE/slots.tsv" && return 1
  tombstone="$(ls "$STATE"/tombstones/1.*.tsv)"
  IFS=$'\t' read -r recorded_slot recorded_root recorded_epoch <"$tombstone"
  [ "$recorded_slot" = "1" ]
  [ "$recorded_root" = "$tree_one" ]
  now="$(date +%s)"
  [ "$((now - recorded_epoch))" -le 5 ]
  [ "$((now - recorded_epoch))" -ge -2 ]

  run gaia_ports_assign_slot "$STATE" "$tree_one"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  IFS=$'\t' read -r _ _ recorded_marker <"$STATE/slots.tsv"
  [ "$recorded_marker" = "$marker_after" ]
}

@test "stale marker: a matching marker retires nothing and writes no tombstone" {
  tree_one="$(add_worktree one)"
  gaia_ports_assign_slot "$STATE" "$tree_one" >/dev/null
  mkdir -p "$STATE/tombstones"
  before="$(ls "$STATE/tombstones" | wc -l | tr -d ' ')"
  run gaia_ports_retire_stale_entry "$STATE" "$tree_one"
  [ "$status" -eq 1 ]
  [ "$(ls "$STATE/tombstones" | wc -l | tr -d ' ')" = "$before" ]
  grep -qF -- "$tree_one" "$STATE/slots.tsv"
}

@test "assign: exhaustion is rc 1 and appends nothing" {
  mkdir -p "$STATE"
  slot=1
  : >"$STATE/slots.tsv"
  while [ "$slot" -le 99 ]; do
    printf '%s\t/fake/tree-%s\tmarker\n' "$slot" "$slot" >>"$STATE/slots.tsv"
    slot=$((slot + 1))
  done
  [ "$(wc -l <"$STATE/slots.tsv" | tr -d ' ')" -eq 99 ]
  cp "$STATE/slots.tsv" "$BATS_TEST_TMPDIR/before.tsv"
  tree_one="$(add_worktree one)"
  run gaia_ports_assign_slot "$STATE" "$tree_one"
  [ "$status" -eq 1 ]
  cmp -s "$STATE/slots.tsv" "$BATS_TEST_TMPDIR/before.tsv"
}

@test "lock: a held lock times out near the deadline" {
  mkdir -p "$STATE/slots.lock"
  export GAIA_PORTS_LOCK_DEADLINE_SECONDS=1
  start="$(date +%s)"
  run gaia_ports_lock "$STATE"
  [ "$status" -eq 1 ]
  [ "$(($(date +%s) - start))" -le 3 ]
  [ -d "$STATE/slots.lock" ]
}

@test "lock: a lock past a minute old is broken and taken, and unlock releases it" {
  mkdir -p "$STATE/slots.lock"
  touch -t 200001010000 "$STATE/slots.lock"
  export GAIA_PORTS_LOCK_DEADLINE_SECONDS=1
  run gaia_ports_lock "$STATE"
  [ "$status" -eq 0 ]
  [ -d "$STATE/slots.lock" ]
  [ -z "$(find "$STATE/slots.lock" -maxdepth 0 -mmin +1)" ]
  gaia_ports_unlock "$STATE"
  [ -d "$STATE/slots.lock" ] && return 1
  run gaia_ports_lock "$STATE"
  [ "$status" -eq 0 ]
}

@test "port file: written in the exact format and read back" {
  run gaia_ports_write_file "$FIXTURE_MAIN" 3
  [ "$status" -eq 0 ]
  file="$FIXTURE_MAIN/frontend/.gaia-ports"
  expected="$(printf '%s\n' \
    '# GAIA per-worktree ports, written by worktree provisioning on every entry. Edits are overwritten.' \
    'GAIA_PORT_SLOT=3' \
    'DEV_PORT=5176' \
    'STORYBOOK_PORT=6009' \
    'SITE_URL=http://localhost:5176')"
  [ "$(cat "$file")" = "$expected" ]
  run gaia_ports_read_file "$file"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '3\t5176\t6009\thttp://localhost:5176')" ]
  run gaia_ports_file_path "$FIXTURE_MAIN"
  [ "$output" = "$file" ]
}

@test "port file: absent is rc 1" {
  run gaia_ports_read_file "$BATS_TEST_TMPDIR/missing-file"
  [ "$status" -eq 1 ]
}

@test "port file: every malformed shape is rc 2 and the valid shape is rc 0" {
  file="$BATS_TEST_TMPDIR/ports-file"
  valid=$'GAIA_PORT_SLOT=1\nDEV_PORT=5174\nSTORYBOOK_PORT=6007\nSITE_URL=http://localhost:5174\n'
  printf '%s' "$valid" >"$file"
  run gaia_ports_read_file "$file"
  [ "$status" -eq 0 ]

  printf '%s' $'GAIA_PORT_SLOT=1\nDEV_PORT=5174\nSITE_URL=http://localhost:5174\n' >"$file"
  run gaia_ports_read_file "$file"
  [ "$status" -eq 2 ]

  printf '%s%s' "$valid" $'DEV_PORT=5175\n' >"$file"
  run gaia_ports_read_file "$file"
  [ "$status" -eq 2 ]

  printf '%s' $'GAIA_PORT_SLOT=1\nDEV_PORT=abc\nSTORYBOOK_PORT=6007\nSITE_URL=http://localhost:5174\n' >"$file"
  run gaia_ports_read_file "$file"
  [ "$status" -eq 2 ]

  printf '%s' $'GAIA_PORT_SLOT=1\nDEV_PORT=0\nSTORYBOOK_PORT=6007\nSITE_URL=http://localhost:5174\n' >"$file"
  run gaia_ports_read_file "$file"
  [ "$status" -eq 2 ]

  printf '%s' $'GAIA_PORT_SLOT=1\nDEV_PORT=5174\nSTORYBOOK_PORT=70000\nSITE_URL=http://localhost:5174\n' >"$file"
  run gaia_ports_read_file "$file"
  [ "$status" -eq 2 ]

  printf '%s' $'GAIA_PORT_SLOT=x\nDEV_PORT=5174\nSTORYBOOK_PORT=6007\nSITE_URL=http://localhost:5174\n' >"$file"
  run gaia_ports_read_file "$file"
  [ "$status" -eq 2 ]
}

@test "port file: an unwritable package directory is rc 1 and leaves no file behind" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  chmod a-w "$FIXTURE_MAIN/frontend"
  run gaia_ports_write_file "$FIXTURE_MAIN" 1
  chmod u+w "$FIXTURE_MAIN/frontend"
  [ "$status" -eq 1 ]
  [ -z "$(find "$FIXTURE_MAIN/frontend" -maxdepth 1 -name '.gaia-ports*')" ]
}

@test "site url: the port is replaced for every URL shape" {
  env_file="$FIXTURE_MAIN/frontend/.env"
  check_site_url() {
    printf '%s\n' "$1" >"$env_file"
    run gaia_ports_site_url "$FIXTURE_MAIN" 5175
    [ "$status" -eq 0 ]
    [ "$output" = "$2" ]
  }
  check_site_url 'SITE_URL=http://localhost:5173' 'http://localhost:5175'
  check_site_url 'SITE_URL=https://app.local.test:5173' 'https://app.local.test:5175'
  check_site_url 'SITE_URL=http://example.test/base' 'http://example.test:5175/base'
  check_site_url 'SITE_URL=http://example.test:1234/path' 'http://example.test:5175/path'
  check_site_url 'SITE_URL=http://[::1]:5173' 'http://[::1]:5175'
  check_site_url 'SITE_URL="http://localhost:5173"' 'http://localhost:5175'
  check_site_url "SITE_URL='https://quoted.test:5173/x'" 'https://quoted.test:5175/x'
  check_site_url 'OTHER=1' 'http://localhost:5175'
  rm -f "$env_file"
  run gaia_ports_site_url "$FIXTURE_MAIN" 5175
  [ "$output" = "http://localhost:5175" ]
}

@test "site url: the env file is read with sed and never sourced" {
  printf '%s\n' 'SECRET=$(touch "'"$BATS_TEST_TMPDIR"'/sourced")' 'SITE_URL=http://localhost:5173' >"$FIXTURE_MAIN/frontend/.env"
  run gaia_ports_site_url "$FIXTURE_MAIN" 5175
  [ "$output" = "http://localhost:5175" ]
  [ -e "$BATS_TEST_TMPDIR/sourced" ] && return 1
  true
}

@test "package directory: without jq the first top-level directory with a router config is used" {
  stub="$BATS_TEST_TMPDIR/no-jq-bin"
  mkdir -p "$stub"
  for tool in git env find sort sed tr tail date mkdir rm mv cat stat sleep dirname rmdir touch; do
    ln -s "$(command -v "$tool")" "$stub/$tool"
  done
  [ -z "$(PATH="$stub" command -v jq)" ]
  load_status="$(PATH="$stub"; gaia_packages_load "$FIXTURE_MAIN" >/dev/null 2>&1; printf '%s' "$?")"
  [ "$load_status" = "4" ]

  result="$(PATH="$stub"; gaia_ports_package_directory "$FIXTURE_MAIN")"
  [ "$result" = "$FIXTURE_MAIN/frontend" ]

  bare="$BATS_TEST_TMPDIR/bare-tree"
  mkdir -p "$bare/frontend"
  git init -q -b main "$bare"
  bare="$(cd "$bare" && pwd -P)"
  code=0
  result="$(PATH="$stub"; gaia_ports_package_directory "$bare")" || code=$?
  [ "$code" -eq 3 ]
  [ -z "$result" ]
}

@test "linker: running it from a worktree leaves the port file a regular file" {
  tree_one="$(add_worktree one)"
  mkdir -p "$FIXTURE_MAIN/frontend"
  printf 'GAIA_PORT_SLOT=0\n' >"$FIXTURE_MAIN/frontend/.gaia-ports"
  gaia_ports_write_file "$tree_one" 1

  is_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

  # Control: the assertion goes red when the file is a symlink to main's.
  control="$BATS_TEST_TMPDIR/control-link"
  ln -s "$FIXTURE_MAIN/frontend/.gaia-ports" "$control"
  run is_regular_file "$control"
  [ "$status" -ne 0 ]

  is_regular_file "$tree_one/frontend/.gaia-ports"
  ( cd "$tree_one" && bash "$REPO_ROOT/.gaia/scripts/link-worktree.sh" ) >/dev/null 2>&1
  is_regular_file "$tree_one/frontend/.gaia-ports"
  [ "$(grep -c '^GAIA_PORT_SLOT=1$' "$tree_one/frontend/.gaia-ports")" -eq 1 ]
}

@test "context line and missing-file message carry the ask-first sentence and ports hint" {
  run gaia_ports_context_line 2 http://localhost:5175 6008
  [ "$output" = "GAIA ports for this worktree (slot 2): app http://localhost:5175, Storybook http://localhost:6008. Never stop a process on a port another live tree owns without asking the user first. Run bash .gaia/scripts/ports.sh to see this tree's ports." ]
  run gaia_ports_missing_file_message /t /t/frontend/.gaia-ports
  [ "$output" = "GAIA: /t is a linked worktree with no port file at /t/frontend/.gaia-ports, so it has no ports of its own and will not borrow the main checkout's. Run: bash .claude/hooks/provision-worktree.sh /t Never stop a process on a port another live tree owns without asking the user first. Run bash .gaia/scripts/ports.sh to see this tree's ports." ]
}

@test "state directory: the seam wins and otherwise the main root's ports folder is named" {
  run gaia_ports_state_directory "$FIXTURE_MAIN"
  [ "$output" = "$STATE" ]
  unset GAIA_PORTS_STATE_DIRECTORY
  tree_one="$(add_worktree one)"
  run gaia_ports_state_directory "$tree_one"
  [ "$status" -eq 0 ]
  [ "$output" = "$FIXTURE_MAIN/.gaia/local/ports" ]
  run gaia_ports_state_directory "$BATS_TEST_TMPDIR/not-a-repository"
  [ "$status" -eq 1 ]
}

@test "base ports honor the test seams" {
  [ "$(gaia_ports_dev_base_port)" = "5173" ]
  [ "$(gaia_ports_storybook_base_port)" = "6006" ]
  export GAIA_PORTS_DEV_BASE_PORT=7000 GAIA_PORTS_STORYBOOK_BASE_PORT=8000
  [ "$(gaia_ports_dev_base_port)" = "7000" ]
  [ "$(gaia_ports_storybook_base_port)" = "8000" ]
}
