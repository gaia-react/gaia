#!/usr/bin/env bats

# Suite for .gaia/tests/installed-dependencies-mark-guard.sh, the guard that
# derives which bats suites read installed dependencies and fails when the
# installed-dependencies marks disagree with that set or when a marked suite
# would skip, rather than fail, on a runner that lacks its dependency.
#
# Only the test that runs the guard over the real repository carries the
# whole-tree mark; every other test drives the guard over a fixture repository
# under $BATS_TEST_TMPDIR with `--root`. The mark line a fixture suite carries
# is assembled at run time (mark_line), so it never sits at column 0 in this
# file and bats never tags the fixtures' text.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GUARD="$REPO_ROOT/.gaia/tests/installed-dependencies-mark-guard.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  SUITE_DIRECTORY="$FIXTURE/.gaia/tests/lib"
  mkdir -p "$SUITE_DIRECTORY"
}

mark_line() {
  printf '# bats %s\n' 'file_tags=installed-dependencies'
}

backstop_line() {
  printf '# installed-dependencies backstop: %s\n' "$1"
}

# write_suite <name> [marked]: the suite body on stdin, written under the
# fixture's lib directory, with the mark first when asked. A body spells its
# tests `TEST "name" {`, because bats rewrites a literal test line even inside
# a heredoc.
write_suite() {
  local target="$SUITE_DIRECTORY/$1.bats"
  {
    printf '#!/usr/bin/env bats\n'
    if [ "${2:-}" = marked ]; then mark_line; fi
    sed 's/^TEST /@test /'
  } >"$target"
}

# write_helper <relative path under the fixture>: the helper body on stdin.
write_helper() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  cat >"$FIXTURE/$1"
}

run_guard() {
  run bash "$GUARD" --root "$FIXTURE" "$@"
}

@test "an unmarked suite that runs pnpm exec vitest fails and is named" {
  write_suite uses-vitest <<'SUITE'
TEST "runs the unit tests" {
  run pnpm exec vitest run
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *uses-vitest.bats*) ;;
    *) printf 'the finding does not name the suite:\n%s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a marked suite that runs pnpm exec vitest passes" {
  write_suite uses-vitest marked <<'SUITE'
TEST "runs the unit tests" {
  run pnpm exec vitest run
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "a marked suite that runs none of the detected commands is reported as a stale mark" {
  write_suite plain marked <<'SUITE'
TEST "prints" {
  run echo hello
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *plain.bats*stale*) ;;
    *) printf 'the finding does not name the stale mark:\n%s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a pnpm function the suite defines is a stub, so the suite is not a user" {
  write_suite stub-function <<'SUITE'
pnpm() { echo "stubbed pnpm $*"; }

TEST "calls the stub" {
  run pnpm exec thing
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "a pnpm file the suite writes onto PATH is a stub, so the suite is not a user" {
  write_suite stub-file <<'SUITE'
TEST "calls the stub file" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho stub\n' >"$BATS_TEST_TMPDIR/bin/pnpm"
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run pnpm install
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "a stub of one tool does not hide a real call to another" {
  write_suite stub-and-real <<'SUITE'
pnpm() { echo stub; }

TEST "runs the real npx" {
  run npx tsx script.ts
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
}

@test "a mention in a comment, a quoted string or a heredoc body is not a call" {
  write_suite mentions <<'SUITE'
# This suite never runs pnpm exec vitest itself.
TEST "greps for the text" {
  run grep -q "pnpm exec vitest" some-file
  printf '%s\n' 'npx tsx x' >"$BATS_TEST_TMPDIR/out"
  cat >"$BATS_TEST_TMPDIR/doc" <<'DOC'
Run pnpm install, then playwright test.
DOC
  command -v pnpm || true
  tools=(pnpm npx vitest)
  true
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "a call through run, a prefix word, a pipe or a subshell is detected" {
  local shape
  for shape in \
    'run --separate-stderr pnpm -C "$BATS_TEST_DIRNAME" test' \
    'FOO=1 BAR=2 npx tsx x.ts' \
    'echo go | vitest run' \
    'value=$(playwright --version)' \
    'timeout 30 pnpm exec tsc' \
    'bash -c "cd /tmp && pnpm exec x"'; do
    rm -f "$SUITE_DIRECTORY"/*.bats
    write_suite shaped <<SUITE
TEST "shape" {
  $shape
}
SUITE
    run_guard
    if [ "$status" -ne 1 ]; then
      printf 'shape not detected: %s\n%s\n' "$shape" "$output" >&2
      return 1
    fi
  done
}

@test "a sourced helper that calls require_node_typescript makes the suite a user" {
  write_helper .gaia/tests/lib/helpers/gate.sh <<'HELPER'
check_gate() {
  require_node_typescript "$1"
}
HELPER
  write_suite via-helper <<'SUITE'
setup() {
  . "$BATS_TEST_DIRNAME/helpers/gate.sh"
  check_gate "$BATS_TEST_DIRNAME"
}

TEST "runs" {
  true
}
SUITE
  # The helper hop is one level: the call to the shared gate is what counts,
  # so the helper file itself calls it by name.
  write_helper .gaia/tests/lib/helpers/gate.sh <<'HELPER'
require_node_typescript "$1"
HELPER
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *via-helper.bats*) ;;
    *) printf 'the finding does not name the suite:\n%s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a sourced helper that runs pnpm makes the suite a user" {
  write_helper .gaia/tests/lib/helpers/runner.sh <<'HELPER'
run_workspace_tests() {
  pnpm -C frontend test --run
}
HELPER
  write_suite via-runner <<'SUITE'
load helpers/runner

TEST "runs" {
  run_workspace_tests
}
SUITE
  # bats resolves `load helpers/runner` to helpers/runner.bash.
  mv "$FIXTURE/.gaia/tests/lib/helpers/runner.sh" "$FIXTURE/.gaia/tests/lib/helpers/runner.bash"
  run_guard
  [ "$status" -eq 1 ]
}

@test "a helper outside a helpers directory is not followed" {
  write_helper .gaia/tests/lib/shared.sh <<'HELPER'
pnpm install
HELPER
  write_suite elsewhere <<'SUITE'
. "$BATS_TEST_DIRNAME/shared.sh"

TEST "runs" {
  true
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "node on a script that resolves workspace packages makes the suite a user" {
  write_helper .gaia/scripts/needs/uses-package.mjs <<'SCRIPT'
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
require('typescript');
SCRIPT
  write_suite runs-script <<'SUITE'
SCRIPT_UNDER_TEST="$BATS_TEST_DIRNAME/../../scripts/needs/uses-package.mjs"

TEST "runs the script" {
  run node "$SCRIPT_UNDER_TEST" arg
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
}

@test "node on a script that imports only built-ins does not make the suite a user" {
  write_helper .gaia/scripts/needs/builtin-only.mjs <<'SCRIPT'
import net from 'node:net';
net.createServer();
SCRIPT
  write_suite runs-builtin-script <<'SUITE'
TEST "runs the script" {
  run node "$BATS_TEST_DIRNAME/../../scripts/needs/builtin-only.mjs" 1234
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "node -e text that requires a bare package makes the suite a user" {
  write_suite eval-bare <<'SUITE'
TEST "resolves a package" {
  run node -e "console.log(require('left-pad')('x', 3))"
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
}

@test "node -e text that requires only built-ins does not make the suite a user" {
  write_suite eval-builtin <<'SUITE'
TEST "opens a port" {
  run node -e "require('net').createServer(); require('node:fs'); require('./local.js')"
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "a suite no bats leg runs is outside the derived set" {
  write_helper .gaia/tests/bats-shards.sh <<'SHARDER'
#!/usr/bin/env bash
case "$1" in
  shards) echo only ;;
  files) echo .gaia/tests/lib/in-leg.bats ;;
esac
SHARDER
  write_suite in-leg <<'SUITE'
TEST "plain" {
  true
}
SUITE
  write_suite out-of-leg <<'SUITE'
TEST "uses pnpm" {
  run pnpm install
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
  run_guard --list-derived
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a mark on a suite no bats leg runs is a stale mark" {
  write_helper .gaia/tests/bats-shards.sh <<'SHARDER'
#!/usr/bin/env bash
case "$1" in
  shards) echo only ;;
  files) echo .gaia/tests/lib/in-leg.bats ;;
esac
SHARDER
  write_suite in-leg <<'SUITE'
TEST "plain" {
  true
}
SUITE
  write_suite out-of-leg marked <<'SUITE'
TEST "uses pnpm" {
  run pnpm install
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *out-of-leg.bats*) ;;
    *) printf 'the finding does not name the suite:\n%s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a mark placed after the first test does not count" {
  write_suite late-mark <<'SUITE'
TEST "runs" {
  run pnpm install
}
SUITE
  mark_line >>"$SUITE_DIRECTORY/late-mark.bats"
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *late-mark.bats*) ;;
    *) printf 'the finding does not name the suite:\n%s\n' "$output" >&2; return 1 ;;
  esac
}

@test "--list-derived prints each user once and nothing else" {
  write_suite alpha marked <<'SUITE'
TEST "runs" {
  run pnpm install
}
SUITE
  write_suite beta <<'SUITE'
TEST "plain" {
  true
}
SUITE
  run_guard --list-derived
  [ "$status" -eq 0 ]
  [ "$output" = ".gaia/tests/lib/alpha.bats" ]
}

@test "a marked suite that skips when its dependency is absent, with no backstop, fails" {
  write_suite skips-on-ci marked <<'SUITE'
setup() {
  [ -d "$BATS_TEST_DIRNAME/node_modules" ] || skip "no node_modules on this runner"
}

TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *skips-on-ci.bats*) ;;
    *) printf 'the finding does not name the suite:\n%s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a backstop naming a workflow that names the suite provisions it, and is listed" {
  mkdir -p "$FIXTURE/.github/workflows"
  printf 'run: bats .gaia/tests/lib/skips-on-ci.bats\n' >"$FIXTURE/.github/workflows/backstop.yml"
  write_suite skips-on-ci marked <<SUITE
$(backstop_line .github/workflows/backstop.yml)
setup() {
  [ -d "\$BATS_TEST_DIRNAME/node_modules" ] || skip "no node_modules on this runner"
}

TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
  run_guard --list-backstopped
  [ "$status" -eq 0 ]
  [ "$output" = ".gaia/tests/lib/skips-on-ci.bats" ]
}

@test "a backstop naming a workflow that does not name the suite fails" {
  mkdir -p "$FIXTURE/.github/workflows"
  printf 'run: bats some-other-suite.bats\n' >"$FIXTURE/.github/workflows/backstop.yml"
  write_suite skips-on-ci marked <<SUITE
$(backstop_line .github/workflows/backstop.yml)
setup() {
  [ -d "\$BATS_TEST_DIRNAME/node_modules" ] || skip "no node_modules on this runner"
}

TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *skips-on-ci.bats*) ;;
    *) printf 'the finding does not name the suite:\n%s\n' "$output" >&2; return 1 ;;
  esac
  run_guard --list-backstopped
  [ -z "$output" ]
}

@test "a backstop naming a workflow file that does not exist fails" {
  write_suite skips-on-ci marked <<SUITE
$(backstop_line .github/workflows/missing.yml)
TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
}

@test "a skip behind a gate that fails under GITHUB_ACTIONS needs no backstop" {
  write_helper .gaia/tests/lib/helpers/gate.sh <<'HELPER'
require_dependency() {
  [ -d "$1/node_modules" ] && return 0
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "missing on CI" >&2
    return 1
  fi
  skip "node_modules not installed"
}
HELPER
  write_suite gated marked <<'SUITE'
. "$BATS_TEST_DIRNAME/helpers/gate.sh"

setup() {
  require_dependency "$BATS_TEST_DIRNAME"
}

TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "a skip unrelated to a dependency needs no backstop" {
  write_suite port-skip marked <<'SUITE'
TEST "runs" {
  run pnpm exec tsx x.ts
  [ "$status" -eq 0 ] || skip "port 6006 is in use on this host"
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "a root with no bats suite is refused with exit 2" {
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE/.gaia/tests/lib"
  run_guard
  [ "$status" -eq 2 ]
}

@test "a usage error exits 2" {
  run bash "$GUARD" --root
  [ "$status" -eq 2 ]
  run bash "$GUARD" --nonsense
  [ "$status" -eq 2 ]
}

@test "the pattern is read from the shared library and restated nowhere here" {
  grep -qF 'verify_installed_dependencies_mark_pattern' "$REPO_ROOT/.gaia/tests/helpers/verify-harness-bats-lib.sh"
  grep -qF 'verify_installed_dependencies_mark_pattern' "$GUARD"
  grep -qE 'installed-dependencies\(,' "$GUARD" && return 1
  grep -qE 'installed-dependencies\(,' "$BATS_TEST_FILENAME" && return 1
  true
}

# bats test_tags=whole-tree
@test "the real repository is clean, and its derived set holds the known users" {
  run bash "$GUARD" --root "$REPO_ROOT"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  local derived suite
  derived="$(bash "$GUARD" --root "$REPO_ROOT" --list-derived)"
  for suite in red-ledger-lib capture-red-observations red-verify-commit-check \
    red-verify-e2e worthiness-presence-check extract-test-signals-stories-reporter \
    uat-lifecycle-e2e; do
    case "$derived" in
      *"/$suite.bats"*) ;;
      *) printf 'derived set is missing %s\n' "$suite" >&2; return 1 ;;
    esac
  done
}

# bats test_tags=whole-tree
@test "the real repository lists the conformance suite as backstopped" {
  local backstopped
  backstopped="$(bash "$GUARD" --root "$REPO_ROOT" --list-backstopped)"
  case "$backstopped" in
    *region-marker-conformance.bats*) ;;
    *) printf 'backstopped set:\n%s\n' "$backstopped" >&2; return 1 ;;
  esac
}
