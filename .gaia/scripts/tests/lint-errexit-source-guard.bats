#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-errexit-source-guard.sh: the static gate that
# flags a `source` / `.` reachable with errexit armed and not bracketed against
# a present-but-unparseable target. The gate scans .claude/hooks/**/*.sh and
# .gaia/scripts/**/*.sh, excluding tests/.
#
# Three jobs: prove the detector fires on each known-bad shape (unguarded load,
# flat restore in a sourced file, a suspend that never restores), prove it stays
# quiet on each accepted shape (flat bracket in an entry point, state-preserving
# bracket in a library, parse-check, no errexit anywhere), and assert the real
# scanned tree is clean so a regression fails CI.
#
# The depth case is the one worth reading. `bash -n` does not recurse, so a
# consumer that parse-checks a library says nothing about what the library
# itself sources; the closure test below plants an unguarded load two source
# levels down from the only file that arms errexit and asserts it is still
# reported. That is the property that ends the depth chase.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
# The linter is invoked as `bash "$LINTER"` from a fixture cwd, matching how CI
# runs it from the repo root; its scan roots are cwd-relative.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-errexit-source-guard.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# new_fixture: an empty tmp repo with both scan roots present. Sets $TMP.
new_fixture() {
  TMP="$(mktemp -d -t errexit-source-lint-XXXXXX)"
  mkdir -p "$TMP/.claude/hooks/lib" "$TMP/.gaia/scripts"
}

# plant <relpath> <body>: write <body> to $TMP/<relpath>.
plant() {
  mkdir -p "$TMP/$(dirname "$1")"
  printf '%s\n' "$2" > "$TMP/$1"
}

# 1. The real scanned tree is clean (regression gate)

@test "the real scanned tree (.claude/hooks + .gaia/scripts) passes the lint" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 2. The detector fires on each known-bad shape

@test "flags an unguarded load in a file that arms errexit" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n. .claude/hooks/lib/helper.sh\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:3" <<<"$output"
  grep -qF -- "unguarded load" <<<"$output"
}

@test "flags an -f test with no bracket: presence proves nothing about parseability" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n[ -f .claude/hooks/lib/helper.sh ] && . .claude/hooks/lib/helper.sh\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:3" <<<"$output"
}

@test "flags a || true arm with no bracket: bash 3.2 aborts through it" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n. .claude/hooks/lib/helper.sh 2>/dev/null || true\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:3" <<<"$output"
}

@test "flags a flat set -e restore in a sourced file" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f .claude/hooks/lib/mid.sh ] && . .claude/hooks/lib/mid.sh 2>/dev/null; set -e\n'
  plant .claude/hooks/lib/mid.sh $'set +e\n. "$(dirname "${BASH_SOURCE[0]}")/helper.sh" 2>/dev/null\nset -e\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/lib/mid.sh:2" <<<"$output"
  grep -qF -- "flat" <<<"$output"
}

@test "flags a flat set -e restore in a file that arms errexit AND is sourced" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f .gaia/scripts/dual.sh ] && . .gaia/scripts/dual.sh 2>/dev/null; set -e\n'
  plant .gaia/scripts/dual.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f .gaia/scripts/helper.sh ] && . .gaia/scripts/helper.sh 2>/dev/null; set -e\n'
  plant .gaia/scripts/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/dual.sh:3" <<<"$output"
  grep -qF -- "flat" <<<"$output"
}

@test "flags a suspend that never restores" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e\n. .claude/hooks/lib/helper.sh 2>/dev/null\necho done\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:4" <<<"$output"
  grep -qF -- "never restored" <<<"$output"
}

@test "flags an unguarded load two source levels below the only errexit file" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n"${BASH:-bash}" -n .gaia/scripts/mid.sh 2>/dev/null && . .gaia/scripts/mid.sh 2>/dev/null || true\n'
  plant .gaia/scripts/mid.sh $'_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nerrexit_was=0\ncase $- in *e*) errexit_was=1 ;; esac\nset +e\n. "$_d/deep.sh" 2>/dev/null\nif [ "$errexit_was" = 1 ]; then set -e; fi\n'
  plant .gaia/scripts/deep.sh $'_dd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n. "$_dd/leaf.sh"\n'
  plant .gaia/scripts/leaf.sh $'leaf() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/deep.sh:2" <<<"$output"
  # The parse-checked consumer and the correctly bracketed middle stay quiet:
  # only the unguarded site two levels down is reported.
  grep -qF -- ".claude/hooks/probe.sh:" <<<"$output" && return 1
  grep -qF -- ".gaia/scripts/mid.sh:" <<<"$output" && return 1
  return 0
}

# 3. Accepted shapes and out-of-scope files are NOT flagged

@test "accepts the flat bracket in a file that arms errexit and is not sourced" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f .claude/hooks/lib/helper.sh ] && . .claude/hooks/lib/helper.sh 2>/dev/null; set -e\ntype helper >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "accepts the state-preserving bracket in a library" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f .claude/hooks/lib/mid.sh ] && . .claude/hooks/lib/mid.sh 2>/dev/null; set -e\n'
  plant .claude/hooks/lib/mid.sh $'_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nerrexit_was=0\ncase $- in *e*) errexit_was=1 ;; esac\nset +e\n. "$_d/helper.sh" 2>/dev/null\nif [ "$errexit_was" = 1 ]; then set -e; fi\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "accepts the parse-check shape, same line and multi-line" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n"${BASH:-bash}" -n .claude/hooks/lib/helper.sh 2>/dev/null && . .claude/hooks/lib/helper.sh 2>/dev/null || true\nif "${BASH:-bash}" -n .claude/hooks/lib/other.sh 2>/dev/null; then\n  . .claude/hooks/lib/other.sh 2>/dev/null || true\nfi\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  plant .claude/hooks/lib/other.sh $'other() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "ignores a bare load in a file no errexit shell can reach" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -uo pipefail\n. .claude/hooks/lib/helper.sh\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "ignores a dot in argument position and a dot ending a sentence" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\njq -e . "$1" >/dev/null 2>&1 || true\ngit grep -n -- . >/dev/null 2>&1 || true\necho "See the workflow page (wiki/concepts/PR Merge Workflow.md). Create a branch first."\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "ignores a load written only inside a comment" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n# . .claude/hooks/lib/helper.sh\necho ok  # . .claude/hooks/lib/helper.sh\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "does not read its own tests/ fixtures as findings" {
  new_fixture
  plant .gaia/scripts/tests/fixture-probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n. .gaia/scripts/helper.sh\n'
  plant .gaia/scripts/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 4. The `if . "$p"; then` spelling, which the capability oracle stayed blind to

@test "reads a load written as an if condition" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nif . .claude/hooks/lib/helper.sh; then\n  helper\nfi\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:3" <<<"$output"
}
