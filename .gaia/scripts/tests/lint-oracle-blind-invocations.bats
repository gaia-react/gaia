#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-oracle-blind-invocations.sh: the gate that flags
# an invocation the capability oracle's anchors cannot see, by differencing
# bash's own reading of command position against the anchors' reading of the
# same line.
#
# The jobs. Prove the detector fires on a shape the anchors miss. Prove it
# stays quiet on the paired shape the anchors accept, and on the prose that
# looks identical once quoting is invisible -- the false-positive direction the
# whole design exists to avoid. Prove the command-prefix list the script
# carries is driven per entry rather than sampled. And assert the real scanned
# tree is clean, so a regression fails CI.
#
# The mutation control is the arm worth reading. Every positive here would also
# pass if the alias machinery silently stopped expanding and the check reported
# every candidate word, so one arm strips the `shopt -s expand_aliases` line out
# of a copy of the script and requires the fixture to come back clean. Without
# it the suite cannot tell "bash says this is a command" from "the check says
# so about everything".
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
# The lint is invoked as `bash "$LINTER"` from a fixture cwd, matching how CI
# runs it from the repo root; its scan roots are cwd-relative.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-oracle-blind-invocations.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# new_fixture: an empty tmp tree with both scan roots present. Sets $TMP.
new_fixture() {
  TMP="$(mktemp -d -t oracle-blind-lint-XXXXXX)"
  mkdir -p "$TMP/.claude/hooks" "$TMP/.gaia/scripts"
}

# plant <body>: write <body> as the fixture's one hook, under a `set -e` header
# so the file reads like the tree's real ones.
plant() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$1" > "$TMP/.claude/hooks/probe.sh"
}

# run_lint: drive the real script from the fixture root.
run_lint() {
  run bash -c "cd '$TMP' && bash '$LINTER'"
}

# hits <line-body>: plant it, run, and require a finding on its line. The body
# lands on line 3, after the shebang and the `set -e`.
hits() {
  new_fixture
  plant "$1"
  run_lint
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:3:" <<<"$output"
}

# quiet <line-body>: plant it, run, and require a clean tree.
quiet() {
  new_fixture
  plant "$1"
  run_lint
  [ "$status" -eq 0 ]
  grep -qF -- ".claude/hooks/probe.sh:3:" <<<"$output" && return 1
  true
}

# scan_roots: the script's own SCAN_ROOTS, derived rather than restated, with
# the same single-assignment pin the PREFIX_WORDS arm uses and for the same
# reason: the one-line `sed` below cannot see an append.
scan_roots() {
  [ "$(grep -cE '^[[:space:]]*SCAN_ROOTS(\[[^]]*\])?\+?=' "$LINTER")" -eq 1 ] || return 1
  sed -n 's/^SCAN_ROOTS=(\(.*\))$/\1/p' "$LINTER"
}

# uncovered <roots>: reads candidate paths on stdin and prints the ones no root
# in <roots> contains. Empty output means the roots cover every candidate.
uncovered() {
  local roots="$1" f r hit
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=0
    for r in $roots; do
      case "$f" in "$r"/*) hit=1; break ;; esac
    done
    [ "$hit" -eq 1 ] || printf '%s\n' "$f"
  done
}

# ---------------------------------------------------------------------------
# 1. The real scanned tree is clean (regression gate)
# ---------------------------------------------------------------------------

@test "the real scanned tree passes the lint" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 1b. The scan roots have to be the oracle's surface, not the two directories
#     it is usually described by
# ---------------------------------------------------------------------------

@test "SCAN_ROOTS covers every source directory the audit workflow's own oracle filter names" {
  local roots wf pattern alts dirs files probes left
  roots="$(scan_roots)"
  [ -n "$roots" ]
  wf="$REPO_ROOT/.github/workflows/audit-ci-tests.yml"
  # The repo's other expression of the oracle's surface is the ERE guarding the
  # workflow's hook-capabilities gate: one anchored alternative per source
  # directory the closure walks, alongside anchored single files. Deriving the
  # roots against it is what keeps the two from drifting, which is how this
  # check came to scan less than the oracle in the first place.
  #
  # The honest limit, stated rather than claimed away: this ties the roots to
  # the workflow's reading of the surface, and neither artifact re-derives the
  # closure. A closure that grows into a directory NEITHER names is unchecked
  # here. Deriving it directly is possible and was measured rather than assumed
  # against: the two `--print-reach` walks that answer it cost about two minutes
  # per run, for a case that has not occurred and that silently breaks the
  # workflow's own arming first.
  pattern="$(sed -n "s/^ *pattern='\(.*\)'\$/\1/p" "$wf")"
  [ -n "$pattern" ]
  # A `|` inside a parenthesised group is not an alternative of the top-level
  # ERE, so the groups collapse to a placeholder before the split. Without that
  # step `(json|schema\.json)` splits into two fragments, neither of which is a
  # shape this arm can read, and the partition check below fires on a pattern
  # that is in fact well-formed.
  pattern="$(printf '%s\n' "$pattern" | sed 's/([^)]*)/X/g')"
  alts="$(printf '%s\n' "$pattern" | tr '|' '\n' | grep -c .)"
  dirs="$(printf '%s\n' "$pattern" | tr '|' '\n' | sed -n 's|^\^\(.*\)/$|\1|p' | sed 's/\\//g')"
  files="$(printf '%s\n' "$pattern" | tr '|' '\n' | grep -c '\$$')"
  [ -n "$dirs" ]
  # A short read of the pattern is the dangerous case, so the two shapes this
  # arm knows how to read have to account for every alternative in it. An
  # alternative that is neither a directory prefix nor a file anchor stops the
  # suite rather than being dropped from the set silently.
  [ "$(( $(printf '%s\n' "$dirs" | grep -c .) + files ))" -eq "$alts" ]
  probes="$(printf '%s\n' "$dirs" | sed 's|$|/probe.sh|')"
  left="$(printf '%s\n' "$probes" | uncovered "$roots")"
  [ -z "$left" ]
  # Mutation, so the coverage claim above is not vacuous: a narrowed root set
  # has to leave something uncovered.
  left="$(printf '%s\n' "$probes" | uncovered ".claude/hooks")"
  [ -n "$left" ]
}

# ---------------------------------------------------------------------------
# 2. Fires where the anchors are blind, stays quiet on the paired shape they
#    accept. The arms come in pairs on purpose: a detector that fires on the
#    blind spelling and also on the anchored one is reporting the tree rather
#    than the divergence, and only the pair separates the two.
# ---------------------------------------------------------------------------

@test "flags a bare path behind an assignment prefix" {
  hits 'X=1 .gaia/scripts/target.sh'
}

@test "is quiet on the same call at the start of its own line" {
  quiet '.gaia/scripts/target.sh'
}

@test "flags a bare path in an if condition" {
  hits 'if .gaia/scripts/target.sh; then :; fi'
}

@test "flags a bare path in a while condition" {
  hits 'while .gaia/scripts/target.sh; do break; done'
}

@test "flags a bare path in an until condition" {
  hits 'until .gaia/scripts/target.sh; do break; done'
}

@test "is quiet on the same call behind an && the anchors accept" {
  quiet 'true && .gaia/scripts/target.sh'
}

@test "flags a bare path opening a subshell" {
  hits '( .gaia/scripts/target.sh )'
}

@test "flags a bare path opening a brace group" {
  hits '{ .gaia/scripts/target.sh; }'
}

@test "flags a quoted path behind a command prefix" {
  hits 'exec "$dir/target.sh"'
}

@test "flags a dot load behind an assignment prefix" {
  hits 'X=1 . "$dir/target.sh"'
}

@test "is quiet on the same dot load in a condition the anchors accept" {
  quiet 'if . "$dir/target.sh"; then :; fi'
}

# ---------------------------------------------------------------------------
# 3. Prose and operands: the false-positive direction
# ---------------------------------------------------------------------------

@test "is quiet on a path inside a double-quoted message" {
  quiet 'echo "run if .gaia/scripts/target.sh is missing"'
}

@test "is quiet on a path in a parenthetical inside a message" {
  quiet 'echo "may not run the writer (.gaia/scripts/target.sh)"'
}

@test "is quiet on a path that is an argument rather than a command" {
  quiet 'cat .gaia/scripts/target.sh'
}

@test "is quiet on a path assigned to a variable" {
  quiet 'lib="$dir/.gaia/scripts/target.sh"'
}

@test "is quiet on a path inside a comment" {
  quiet '# the writer is .gaia/scripts/target.sh and it runs elsewhere'
}

@test "is quiet on a path inside a heredoc body" {
  new_fixture
  plant $'cat <<EOF\nif .gaia/scripts/target.sh; then :; fi\nEOF'
  run_lint
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. The command-prefix list is a coverage claim, so it is driven per entry
# ---------------------------------------------------------------------------

@test "every word in the script's own PREFIX_WORDS list is read as a command position" {
  local decl words w read_count=0
  # A derivation that comes back short is the dangerous case, not the empty one:
  # the arm stays green while driving a subset under a name that says every.
  # Counting the split against itself would be true by construction, so what
  # makes the read honest here is pinning the list to ONE assignment: the
  # pattern below reaches `+=`, a subscripted element and a leading-whitespace
  # spelling, so an append the single-line `sed` cannot see stops the suite
  # instead of shrinking it.
  [ "$(grep -cE '^[[:space:]]*PREFIX_WORDS(\[[^]]*\])?\+?=' "$LINTER")" -eq 1 ]
  decl="$(sed -n 's/^PREFIX_WORDS=(\(.*\))$/\1/p' "$LINTER")"
  [ -n "$decl" ]
  words="$decl"
  for w in $words; do
    read_count=$(( read_count + 1 ))
    hits "$w .gaia/scripts/target.sh"
  done
  # A per-element claim over an empty set is true and means nothing.
  [ "$read_count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# 5. Non-vacuity: the verdict comes from bash's alias expansion
# ---------------------------------------------------------------------------

@test "a copy with alias expansion disabled reports nothing, so the verdict is bash's" {
  # Sampling one blind shape on purpose. This arm exists to prove the positives
  # above are not vacuous, and one shape settles that; the coverage claim is
  # section 2's job and is made per shape there.
  new_fixture
  plant 'if .gaia/scripts/target.sh; then :; fi'
  run_lint
  [ "$status" -eq 1 ]

  # The mutant needs the oracle library beside it, because the script resolves
  # that library from its own on-disk location -- and it must NOT land in
  # .gaia/scripts to get it. That directory is a scan root of this very lint,
  # discovery is `find` rather than `git ls-files` so an untracked dotfile is
  # visible there, and the shards run concurrently in one workspace. Both files
  # go to a directory of their own, which $TMP's teardown already removes.
  local mdir="$TMP/mutant"
  mkdir -p "$mdir"
  cp "$REPO_ROOT/.gaia/scripts/capability-oracle-lib.sh" "$mdir/capability-oracle-lib.sh"
  sed '/shopt -s expand_aliases/d' "$LINTER" > "$mdir/lint.sh"
  grep -qF -- "expand_aliases" "$mdir/lint.sh" && return 1
  run bash -c "cd '$TMP' && bash '$mdir/lint.sh'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 6. A file the rewrite cannot parse is reported, never skipped
# ---------------------------------------------------------------------------

@test "reports a file whose sentinel rewrite does not parse rather than passing it" {
  new_fixture
  # A file the probe cannot parse is a file whose blindness is unmeasured, and
  # the honest report of that is a finding rather than a skip. The verdict must
  # not depend on why the parse failed, so the fixture reaches it the simplest
  # way there is.
  printf '#!/usr/bin/env bash\nif [ -f .gaia/scripts/target.sh ]; then\n' > "$TMP/.claude/hooks/probe.sh"
  run_lint
  [ "$status" -eq 1 ]
  grep -qF -- "unprobeable" <<<"$output"
}

# ---------------------------------------------------------------------------
# 7. The check's own failure is distinguishable from a clean tree
# ---------------------------------------------------------------------------

@test "exits 2 rather than 0 when the scan roots resolve no files" {
  TMP="$(mktemp -d -t oracle-blind-lint-XXXXXX)"
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 2 ]
  grep -qF -- "zero" <<<"$output"
}
