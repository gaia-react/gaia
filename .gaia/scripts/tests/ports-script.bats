#!/usr/bin/env bats
#
# Suite for .gaia/scripts/ports.sh: the four-line report on main and in a
# provisioned worktree, the SITE_URL precedence, and each refusal.
# Fixtures are throwaway git repositories with real linked worktrees under
# $BATS_TEST_TMPDIR; GAIA_PORTS_STATE_DIRECTORY keeps state out of this repository.
#
# Run: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/ports-script.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PORTS_SCRIPT="$REPO_ROOT/.gaia/scripts/ports.sh"
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

add_worktree() {
  fixture_git worktree add -q -b "$1" "$BATS_TEST_TMPDIR/trees/$1" >/dev/null 2>&1 || return 1
  ( cd "$BATS_TEST_TMPDIR/trees/$1" && pwd -P )
}

# provisioned_worktree <name> <slot>: a worktree holding <slot> with its port file written.
provisioned_worktree() {
  local tree
  tree="$(add_worktree "$1")" || return 1
  gaia_ports_write_file "$tree" "$2" || return 1
  printf '%s\n' "$tree"
}

@test "worktree with a port file: the four lines carry slot-offset ports and the file's site url" {
  other="$(add_worktree other)"
  gaia_ports_assign_slot "$STATE" "$other" >/dev/null
  tree="$(add_worktree two)"
  printf 'SITE_URL=http://app.test:5173\n' >"$tree/frontend/.env"
  gaia_ports_write_file "$tree" 2
  run bash "$PORTS_SCRIPT" --tree "$tree"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'slot=2\ndev=5175\nstorybook=6008\nsite_url=http://app.test:5175')" ]
}

@test "worktree with a port file: --field prints only the bare value" {
  tree="$(provisioned_worktree two 2)"
  run bash "$PORTS_SCRIPT" --tree "$tree" --field dev
  [ "$status" -eq 0 ]
  [ "$output" = "5175" ]
  run bash "$PORTS_SCRIPT" --tree "$tree" --field slot
  [ "$output" = "2" ]
  run bash "$PORTS_SCRIPT" --tree "$tree" --field storybook
  [ "$output" = "6008" ]
  run bash "$PORTS_SCRIPT" --tree "$tree" --field site-url
  [ "$output" = "http://localhost:5175" ]
}

@test "worktree with a port file: the tree defaults to the working directory" {
  tree="$(provisioned_worktree one 1)"
  output="$(cd "$tree" && bash "$PORTS_SCRIPT" --field dev)"
  [ "$output" = "5174" ]
}

@test "main checkout with no file: slot 0, base ports, site url from the env file" {
  printf 'SITE_URL=http://example.test/base\n' >"$FIXTURE_MAIN/frontend/.env"
  run bash "$PORTS_SCRIPT" --tree "$FIXTURE_MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'slot=0\ndev=5173\nstorybook=6006\nsite_url=http://example.test:5173/base')" ]
}

@test "non-linked clone with no file: slot 0 and the base ports" {
  clone="$BATS_TEST_TMPDIR/clone"
  git clone -q "$FIXTURE_MAIN" "$clone"
  printf 'SITE_URL=https://clone.test:3000\n' >"$clone/frontend/.env"
  run bash "$PORTS_SCRIPT" --tree "$clone"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'slot=0\ndev=5173\nstorybook=6006\nsite_url=https://clone.test:5173')" ]
}

@test "no env file on main: the default localhost url" {
  run bash "$PORTS_SCRIPT" --tree "$FIXTURE_MAIN" --field site-url
  [ "$output" = "http://localhost:5173" ]
}

@test "an exported SITE_URL wins on main and in a worktree with a port file" {
  export SITE_URL="https://exported.test:9999"
  printf 'SITE_URL=http://example.test:5173\n' >"$FIXTURE_MAIN/frontend/.env"
  run bash "$PORTS_SCRIPT" --tree "$FIXTURE_MAIN" --field site-url
  [ "$output" = "https://exported.test:9999" ]
  tree="$(provisioned_worktree one 1)"
  run bash "$PORTS_SCRIPT" --tree "$tree" --field site-url
  [ "$output" = "https://exported.test:9999" ]
  run bash "$PORTS_SCRIPT" --tree "$tree" --field dev
  [ "$output" = "5174" ]
}

@test "linked worktree with no port file: exit 3, empty stdout, the frozen message on stderr" {
  tree="$(add_worktree bare)"
  code=0
  bash "$PORTS_SCRIPT" --tree "$tree" >"$BATS_TEST_TMPDIR/stdout" 2>"$BATS_TEST_TMPDIR/stderr" || code=$?
  [ "$code" -eq 3 ]
  [ ! -s "$BATS_TEST_TMPDIR/stdout" ]
  expected="GAIA: $tree is a linked worktree with no port file at $tree/frontend/.gaia-ports, so it has no ports of its own and will not borrow the main checkout's. Run: bash .claude/hooks/provision-worktree.sh $tree Never stop a process on a port another live tree owns without asking the user first. Run bash .gaia/scripts/ports.sh to see this tree's ports."
  [ "$(cat "$BATS_TEST_TMPDIR/stderr")" = "$expected" ]
}

@test "linked worktree with no port file and an exported SITE_URL still refuses" {
  export SITE_URL="https://exported.test:9999"
  tree="$(add_worktree bare)"
  code=0
  bash "$PORTS_SCRIPT" --tree "$tree" >"$BATS_TEST_TMPDIR/stdout" 2>/dev/null || code=$?
  [ "$code" -eq 3 ]
  [ ! -s "$BATS_TEST_TMPDIR/stdout" ]
}

@test "malformed port file: exit 4 naming the file and the provisioning command" {
  tree="$(provisioned_worktree one 1)"
  printf 'GAIA_PORT_SLOT=1\nDEV_PORT=nope\n' >"$tree/frontend/.gaia-ports"
  code=0
  bash "$PORTS_SCRIPT" --tree "$tree" >"$BATS_TEST_TMPDIR/stdout" 2>"$BATS_TEST_TMPDIR/stderr" || code=$?
  [ "$code" -eq 4 ]
  [ ! -s "$BATS_TEST_TMPDIR/stdout" ]
  grep -qF -- "$tree/frontend/.gaia-ports" "$BATS_TEST_TMPDIR/stderr"
  grep -qF -- "bash .claude/hooks/provision-worktree.sh $tree" "$BATS_TEST_TMPDIR/stderr"
}

@test "usage errors exit 2" {
  run bash "$PORTS_SCRIPT" --field bogus
  [ "$status" -eq 2 ]
  run bash "$PORTS_SCRIPT" --nope
  [ "$status" -eq 2 ]
  run bash "$PORTS_SCRIPT" --tree
  [ "$status" -eq 2 ]
  run bash "$PORTS_SCRIPT" --tree "$BATS_TEST_TMPDIR/not-a-repository"
  [ "$status" -eq 2 ]
}

@test "a tree with no router config exits 5 naming the missing config, with and without jq" {
  bare="$BATS_TEST_TMPDIR/bare-tree"
  mkdir -p "$bare/frontend"
  git init -q -b main "$bare"
  run bash "$PORTS_SCRIPT" --tree "$bare"
  [ "$status" -eq 5 ]
  [[ "$output" == *"react-router.config."* ]]

  stub="$BATS_TEST_TMPDIR/no-jq-bin"
  mkdir -p "$stub"
  for tool in git env find sort sed tr tail date mkdir rm mv cat stat sleep dirname rmdir touch; do
    ln -s "$(command -v "$tool")" "$stub/$tool"
  done
  code=0
  error_output="$(PATH="$stub" "$BASH" "$PORTS_SCRIPT" --tree "$bare" 2>&1 >/dev/null)" || code=$?
  [ "$code" -eq 5 ]
  [[ "$error_output" == *"react-router.config."* ]]

  code=0
  result="$(PATH="$stub" "$BASH" "$PORTS_SCRIPT" --tree "$FIXTURE_MAIN" --field dev)" || code=$?
  [ "$code" -eq 0 ]
  [ "$result" = "5173" ]
}
