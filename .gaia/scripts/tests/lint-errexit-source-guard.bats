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

@test "flags a load pulled out from under the parse check that gates it" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nif "${BASH:-bash}" -n .claude/hooks/lib/helper.sh 2>/dev/null; then\n  :\nfi\n. .claude/hooks/lib/helper.sh\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:6" <<<"$output"
}

# The restore this load needs lives in a heredoc BODY, which is data the shell
# hands to a command rather than shell it runs. Read as code the pair brackets
# the load; read as data the load is inside a suspend nothing closes. The load
# sits after the `set +e` and before the body deliberately: a fixture whose load
# precedes the heredoc entirely is reported for the ordinary reason and cannot
# tell a linter that skips heredoc bodies from one that does not.
@test "a restore inside a heredoc body does not close the bracket above it" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e\n. .claude/hooks/lib/helper.sh\ncat <<\'USAGE\'\nset -e\nUSAGE\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:4" <<<"$output"
  grep -qF -- "never restored" <<<"$output"
}

# The swallow direction, which fails OPEN and so is the more dangerous half. A
# `<<WORD` inside a quoted string is not a heredoc opener; read as one it opens
# a body that never ends, and every line below is skipped as body, so the file
# is reported clean over input the scan never read. Verbatim from
# .gaia/scripts/read-audit-ci-config.sh, where it is live today.
@test "a << inside a quoted string does not swallow the rest of the file" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nprintf \'retrigger_workflows<<__GAIA_END__\\n\'\n. .claude/hooks/lib/helper.sh\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:4" <<<"$output"
}

# `<<<` is a herestring: its operand is a word on the same line, not a body on
# the lines below. Read as a heredoc opener it swallows the rest of the file.
@test "a herestring does not swallow the rest of the file" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\ngrep -q x <<<hello || true\n. .claude/hooks/lib/helper.sh\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:4" <<<"$output"
}

# The residual guard. Whatever the walk reads wrong, a heredoc still open when
# the file ends means every line after it went unread, so the check says so and
# fails rather than returning a verdict over input it never saw.
@test "an unterminated heredoc fails the check instead of reporting clean" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\ncat <<\'NEVER\'\nbody line\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- "is never closed" <<<"$output"
  grep -qF -- "UNREAD" <<<"$output"
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

# The sentence whose next word IS a variable, which the bare-variable operand
# arm would otherwise accept. Verbatim from .gaia/scripts/cost-reprice.sh, where
# it is inert today only because that file does not arm errexit.
@test "ignores a sentence that continues past a variable" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nlog "cost-reprice: refusing to rewrite, which would drop $((expected_lines - total_count)) row(s). $ledger is untouched."\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# The bracket is a shape, not an identifier. A library spelling it exactly and
# naming the captured state anything else is not a defect, and reporting it as
# one prints back the shape its author already used as the remedy.
@test "accepts the state-preserving bracket under a different variable name" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f .claude/hooks/lib/mid.sh ] && . .claude/hooks/lib/mid.sh 2>/dev/null; set -e\n'
  plant .claude/hooks/lib/mid.sh $'_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nhad_e=0\ncase $- in *e*) had_e=1 ;; esac\nset +e\n. "$_d/helper.sh" 2>/dev/null\nif [ "$had_e" = 1 ]; then set -e; fi\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# The multi-line restore, where the guard is on the line above rather than
# ahead of the `set -e` on its own line, with a comment between the two. The
# comment is the point: a `then`-adjacency test that a comment line clears reds
# this file, and this tree comments densely enough that the commented spelling
# is the likely one.
@test "accepts a state-preserving bracket whose restore spans two lines" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f .claude/hooks/lib/mid.sh ] && . .claude/hooks/lib/mid.sh 2>/dev/null; set -e\n'
  plant .claude/hooks/lib/mid.sh $'_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nerrexit_was=0\ncase $- in *e*) errexit_was=1 ;; esac\nset +e\n. "$_d/helper.sh" 2>/dev/null\nif [ "$errexit_was" = 1 ]; then\n  # put errexit back only for a caller that had it\n  set -e\nfi\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# The report is the check's whole output, so a load whose degrade is spelled
# with `||` must arrive with that degrade still attached.
@test "the reported line survives a pipe character in the source text" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n. .claude/hooks/lib/helper.sh || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ". .claude/hooks/lib/helper.sh || exit 0" <<<"$output"
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

# 5. One coordinate system per line, and one quote state

# A site is positioned over the masked line and a set event over the raw one:
# any masked span left of the `set +e` shrinks one column and not the other, so
# the load sorts ahead of the suspend it sits inside and a correct bracket reads
# as a defect. The control below is the same file with the substitution replaced
# by a literal, which is what makes this a test of the coordinate system rather
# than of the bracket.
@test "a command substitution ahead of set +e does not reorder a one-line bracket" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nd="$(dirname "${BASH_SOURCE[0]}")/lib"; set +e; . "$d/helper.sh" 2>/dev/null; set -e\ntype helper >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "the same bracket with no substitution ahead of it is accepted too" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nd=lib; set +e; . ".claude/hooks/$d/helper.sh" 2>/dev/null; set -e\ntype helper >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "a set -e spelled inside a string does not close a real suspend" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e\necho "remember to run set -e afterwards"\n[ -f ".claude/hooks/lib/helper.sh" ] && . ".claude/hooks/lib/helper.sh" 2>/dev/null\nset -e\ntype helper >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 6. The bare `(( ))` arithmetic command

# Missing this reads the digits of a left shift as a heredoc delimiter, skips
# every line below as body, and exits reporting a heredoc that does not exist
# while the loads below it genuinely went unread.
@test "a left shift in a bare (( )) is not read as a heredoc opener" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nn=1\n(( n = n << 3 ))\nset +e\n[ -f ".claude/hooks/lib/helper.sh" ] && . ".claude/hooks/lib/helper.sh" 2>/dev/null\nset -e\ntype helper >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "a left shift in a bare (( )) after an if keyword is not a heredoc opener either" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nn=1\nif (( n << 3 )); then n=0; fi\nset +e\n[ -f ".claude/hooks/lib/helper.sh" ] && . ".claude/hooks/lib/helper.sh" 2>/dev/null\nset -e\ntype helper >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 7. A state-preserving restore is credited by containment, not by adjacency

@test "accepts a conditional restore carrying a second statement before it" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f ".claude/hooks/lib/mid.sh" ] && . ".claude/hooks/lib/mid.sh" 2>/dev/null; set -e\ntype mid >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/mid.sh $'was=0\ncase $- in *e*) was=1 ;; esac\nset +e\n[ -f ".claude/hooks/lib/leaf.sh" ] && . ".claude/hooks/lib/leaf.sh" 2>/dev/null\nif [ "$was" = 1 ]; then\n  unset was\n  set -e\nfi\ntype leaf >/dev/null 2>&1 || true\nmid() { :; }\n'
  plant .claude/hooks/lib/leaf.sh $'leaf() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "accepts a conditional restore written in an else arm" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f ".claude/hooks/lib/mid.sh" ] && . ".claude/hooks/lib/mid.sh" 2>/dev/null; set -e\ntype mid >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/mid.sh $'was=0\ncase $- in *e*) was=1 ;; esac\nset +e\n[ -f ".claude/hooks/lib/leaf.sh" ] && . ".claude/hooks/lib/leaf.sh" 2>/dev/null\nif [ "$was" = 0 ]; then\n  :\nelse\n  set -e\nfi\ntype leaf >/dev/null 2>&1 || true\nmid() { :; }\n'
  plant .claude/hooks/lib/leaf.sh $'leaf() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "accepts a conditional restore written as a case arm" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f ".claude/hooks/lib/mid.sh" ] && . ".claude/hooks/lib/mid.sh" 2>/dev/null; set -e\ntype mid >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/mid.sh $'was=0\ncase $- in *e*) was=1 ;; esac\nset +e\n[ -f ".claude/hooks/lib/leaf.sh" ] && . ".claude/hooks/lib/leaf.sh" 2>/dev/null\ncase "$was" in 1) set -e ;; esac\ntype leaf >/dev/null 2>&1 || true\nmid() { :; }\n'
  plant .claude/hooks/lib/leaf.sh $'leaf() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# The bound on the rule above: depth is measured against the depth at the
# capture, so an include guard wrapping a whole library credits nothing. Without
# it every restore in such a library reads as conditional and the defect this
# gate exists to catch goes unreported.
@test "still flags an unconditional restore inside an include guard" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f ".claude/hooks/lib/mid.sh" ] && . ".claude/hooks/lib/mid.sh" 2>/dev/null; set -e\ntype mid >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/mid.sh $'if [ -z "${_GUARD:-}" ]; then\n  _GUARD=1\n  was=0\n  case $- in *e*) was=1 ;; esac\n  set +e\n  [ -f ".claude/hooks/lib/leaf.sh" ] && . ".claude/hooks/lib/leaf.sh" 2>/dev/null\n  set -e\n  type leaf >/dev/null 2>&1 || true\nfi\nmid() { :; }\n'
  plant .claude/hooks/lib/leaf.sh $'leaf() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/lib/mid.sh:6" <<<"$output"
  grep -qF -- "flat" <<<"$output"
}

# 8. A line may open more than one heredoc

# `cat <<A <<B` runs the two bodies in order. Tracking only the first leaves the
# body of B read as shell, so a load written inside it becomes a finding for a
# line that is data.
@test "a second heredoc opened on one line has its body treated as data" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\ncat <<A <<B\nplain\nA\n. .claude/hooks/lib/helper.sh\nB\necho done\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 9. A whole-operand expansion still names a file the walk cannot resolve

# `mask` reduces every `${...}` and `$(...)` span to one sentinel before the
# load test runs, so these three spellings arrive as the sentinel rather than as
# an expansion. Read as neither a `.sh` operand nor a variable they pass
# silently, which is the direction this gate exists to close.
@test "flags an unguarded load whose operand is a braced expansion" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n. "${LIB}"\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:3" <<<"$output"
}

@test "flags an unguarded load whose operand carries a brace default" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n. "${LIB:-.claude/hooks/lib/helper.sh}"\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:3" <<<"$output"
}

@test "flags an unguarded load whose operand is a command substitution" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\n. "$(printf \'%s\' .claude/hooks/lib/helper.sh)"\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:3" <<<"$output"
}

@test "accepts a braced-operand load that is bracketed" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nset +e; [ -f "${LIB}" ] && . "${LIB}" 2>/dev/null; set -e\ntype helper >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 10. The C-style `for (( ))` header, the arithmetic spelling with live sites

@test "a left shift in a for (( )) header is not read as a heredoc opener" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\nn=4\nfor (( i = 0; i < (n << 2); i++ )); do :; done\nset +e\n[ -f ".claude/hooks/lib/helper.sh" ] && . ".claude/hooks/lib/helper.sh" 2>/dev/null\nset -e\ntype helper >/dev/null 2>&1 || exit 0\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 11. A load token that exists only inside a string loads nothing

# A separator inside a string splits a sentence into a segment whose first word
# is the dot, so a usage string or a deny message carrying one would red a
# required shard on a file that loads nothing.
@test "ignores a load spelled only inside a string" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\necho "first; . .claude/hooks/lib/helper.sh"\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# The bound: a quoted dot ahead of a real load must not hide the real one.
@test "still flags a real load on a line whose string also spells one" {
  new_fixture
  plant .claude/hooks/probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\necho "first; . .claude/hooks/lib/helper.sh"\n. .claude/hooks/lib/helper.sh\n'
  plant .claude/hooks/lib/helper.sh $'helper() { :; }\n'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:4" <<<"$output"
}

# 12. A scan root that vanishes must fail the check, not shrink it

@test "fails loudly when a scan root is absent rather than scanning what remains" {
  new_fixture
  rm -rf "$TMP/.claude"
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- "scan root missing: .claude/hooks" <<<"$output"
}
