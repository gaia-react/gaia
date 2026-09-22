#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so the `$` expansions reach the fixture file as literal text. An expansion the
# shell performed here would delete the evidence -- `"$GAIA_AWK"` is the form
# under test, and a fixture carrying its VALUE proves nothing.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-awk-interpreter-pin.sh: the static gate that
# flags a bare awk interpreter in command position inside the
# guard-awk-lib.sh closure, where the resolved `"$GAIA_AWK"` is the required
# form.
#
# Three jobs. Prove the detector fires on the class, under every interpreter
# name the rule closes over and under a path-invoked one; prove it stays quiet
# on each legitimate shape, which for this gate is the load-bearing half,
# because this repository's own guards, resolver and prose all NAME `mawk`,
# `gawk` and `/usr/bin/awk` in comments, refusal messages and grep patterns,
# and a naive command-position reader reds on every one of them; and prove the
# discovery is armed, since a derived surface can empty itself silently.
#
# Two tests are load-bearing beyond coverage. "reds on the interpreters the
# resolver itself reaches for" carries `mawk` and `/usr/bin/awk`, the two names
# awk-interp-lib.sh resolves, so the gate is proven to close over the fail-open
# direction an allowlist would have opened; this gate ships no allowlist, and
# that test is what says so in a form that re-checks itself. And "the closure
# derivation reaches a consumer added beside the anchor" is what proves the
# surface is derived rather than listed, which is the property that makes a
# later consumer join with no edit to the gate.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The gate resolves its scan surface with `git ls-files` relative to cwd while
# it sources its library relative to its OWN path, so every fixture is a real
# git repository the gate is run from, and the gate itself is always the real
# one in this checkout. That split is what makes the empty-closure refusal
# drivable at all: a fixture repo can lack guard-awk-lib.sh while the gate
# still loads it.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-awk-interpreter-pin.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# new_tmp: a scratch directory under $BATS_TEST_TMPDIR when bats provides one,
# so bats reaps it even on an aborted run, and under $TMPDIR otherwise.
new_tmp() {
  mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/awk-interpreter-pin-XXXXXX"
}

# fixture_repo_bare: an initialized git repo in $TMP with nothing tracked.
# Point a test that needs an empty scan surface here.
fixture_repo_bare() {
  TMP="$( new_tmp )"
  git -C "$TMP" init -q .
}

# fixture_repo: fixture_repo_bare with the closure anchor in place. The gate
# derives its whole surface from that file, so a fixture without one reaches
# the empty-closure refusal rather than the class detection; every test about
# the class needs it already there.
fixture_repo() {
  fixture_repo_bare
  fixture_file .gaia/scripts/guard-awk-lib.sh 'true'
}

# fixture_file <relpath> <body>: write <body> verbatim to $TMP/<relpath> and
# track it. `printf %s` never interprets an escape, so the body reaches the
# file as the characters the gate is meant to read.
fixture_file() {
  local dest="$TMP/$1"
  mkdir -p "$( dirname "$dest" )"
  printf '%s\n' "$2" > "$dest"
  git -C "$TMP" add -A
}

# fixture_consumer <body>: the common case, a tracked closure consumer beside
# the anchor. The source line is the bracketed idiom every real consumer
# carries, because that is the shape the up-hop derivation reads.
fixture_consumer() {
  fixture_file .gaia/scripts/probe.sh \
    'set +e; [ -f "$d/guard-awk-lib.sh" ] && . "$d/guard-awk-lib.sh" 2>/dev/null; set -e
'"$1"
}

# run_linter: run the gate from inside the fixture repo, streams merged, which
# is what bats `run` does anyway. The one test that needs them apart splits
# them itself.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
}

# --- the class fires -------------------------------------------------------

@test "reds on a bare awk in command position, naming the line and the claim" {
  fixture_repo
  fixture_consumer 'awk -v x=1 "{print}" file'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/probe.sh:2:" <<<"$output" || return 1
  # The claim, not only the status: a bare status is shared by every other
  # finding this gate can print, so asserting it alone would pass on the
  # wrong one.
  grep -qF -- "awk in command position" <<<"$output" || return 1
  grep -qF -- 'must invoke "$GAIA_AWK"' <<<"$output"
}

@test "reds on a bare gawk, the implementation the resolver rejects outright" {
  fixture_repo
  fixture_consumer 'gawk "{print}" file'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/probe.sh:2:" <<<"$output" || return 1
  grep -qF -- "gawk in command position" <<<"$output"
}

@test "reds on a bare nawk" {
  fixture_repo
  fixture_consumer 'nawk "{print}" file'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nawk in command position" <<<"$output"
}

# The fail-closed direction, and the reason this gate ships no allowlist at
# all. `mawk` and `/usr/bin/awk` are exactly the interpreters
# awk-interp-lib.sh resolves, so an allowlist written to spare "the ones we
# already use" would license both -- and naming either directly is what routes
# around the resolver's identity probe, which decides by ASKING the binary
# rather than by trusting a basename. A pin that permits the pinned names is
# not a pin.
@test "reds on the interpreters the resolver itself reaches for" {
  fixture_repo
  fixture_consumer 'mawk "{print}" file
/usr/bin/awk "{print}" file'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/probe.sh:2: mawk in command position" <<<"$output" || return 1
  grep -qF -- ".gaia/scripts/probe.sh:3: /usr/bin/awk in command position" <<<"$output"
}

@test "reds on a call inside a command substitution, assigned or piped" {
  fixture_repo
  fixture_consumer 'hits=$(awk "{print}" file)
count="$(awk "END{print NR}" file)"
printf x | awk "{print}"
if awk -f prog file; then true; fi
LC_ALL=C awk "{print}" file'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/probe.sh:2:" <<<"$output" || return 1
  grep -qF -- ".gaia/scripts/probe.sh:3:" <<<"$output" || return 1
  grep -qF -- ".gaia/scripts/probe.sh:4:" <<<"$output" || return 1
  grep -qF -- ".gaia/scripts/probe.sh:5:" <<<"$output" || return 1
  # The assignment PREFIX arm: `LC_ALL=C awk` still invokes awk, and a reader
  # that treats an assignment as ending the command position misses it.
  grep -qF -- ".gaia/scripts/probe.sh:6:" <<<"$output"
}

@test "reds on the anchor library itself, which is a member of its own closure" {
  fixture_repo_bare
  fixture_file .gaia/scripts/guard-awk-lib.sh 'awk "{print}" file'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/guard-awk-lib.sh:1:" <<<"$output"
}

# --- the required form, and the shapes that only look like the class --------

@test "quiet on the required form" {
  fixture_repo
  fixture_consumer '"$GAIA_AWK" -v x=1 "{print}" file
out="$("$GAIA_AWK" "END{print NR}" file)"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a comment naming every interpreter the rule closes over" {
  fixture_repo
  fixture_consumer '# awk, gawk, mawk and nawk are what this rule closes over
true  # and /usr/bin/awk is named here too'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on an interpreter name inside a single-quoted string" {
  fixture_repo
  fixture_consumer "printf '%s\\n' 'awk is data here'
msg='run mawk to see it'"
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on an interpreter name in argument position" {
  fixture_repo
  fixture_consumer 'grep -q awk file
command -v mawk >/dev/null 2>&1
printf "%s" "gawk"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a longer identifier that merely contains an interpreter name" {
  fixture_repo
  fixture_consumer 'my_awk_prog --run
GAIA_AWK_STATUS=0
awkward_helper file'
  run_linter
  [ "$status" -eq 0 ]
}

# A quoted heredoc body is data, and this repository fills them with prose and
# with fixture text naming its own tools. It is a stated FAIL-OPEN in the
# gate header rather than a claim, and this pins the behavior the header
# describes so a later reader finds the two agreeing.
@test "quiet on an interpreter name inside a quoted heredoc body" {
  fixture_repo
  fixture_consumer 'cat <<"EOF"
awk is prose here
EOF'
  run_linter
  [ "$status" -eq 0 ]
}

# The class detector must survive the shape every real member of this closure
# is built out of: an awk program held in a single-quoted literal spanning many
# lines, whose own text contains awk built-ins and comments. A line-local
# reader reports those; this one carries quote state across lines.
@test "quiet on awk program text held in a multi-line single-quoted literal" {
  fixture_repo
  local body
  body="$( cat <<'PROBE'
set +e; [ -f "$d/guard-awk-lib.sh" ] && . "$d/guard-awk-lib.sh" 2>/dev/null; set -e
readonly PROG='
BEGIN { print }
# a comment inside the program naming awk and mawk
{ print "awk" }
'
true
PROBE
)"
  fixture_file .gaia/scripts/probe.sh "$body"
  run_linter
  [ "$status" -eq 0 ]
}

# --- the surface, stated closed --------------------------------------------

@test "a bats suite is outside the surface, as the gate header states" {
  fixture_repo
  fixture_file .gaia/scripts/probe.bats '@test "t" { awk "{print}" file; }'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a file that does not source the anchor is outside the surface" {
  fixture_repo
  fixture_file .gaia/scripts/stranger.sh 'awk "{print}" file'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a consumer BELOW the anchor directory is outside the surface" {
  fixture_repo
  fixture_file .gaia/scripts/tests/fixtures/deep.sh \
    'set +e; [ -f "$d/guard-awk-lib.sh" ] && . "$d/guard-awk-lib.sh" 2>/dev/null; set -e
awk "{print}" file'
  run_linter
  [ "$status" -eq 0 ]
}

# The property that makes the surface derived rather than listed: a consumer
# added beside the anchor joins with no edit to the gate. This is the sibling
# of the reason shell-lint.bats derives its roster from
# whole-tree-invariants.sh instead of restating it.
@test "the closure derivation reaches a consumer added beside the anchor" {
  fixture_repo
  fixture_file .gaia/scripts/lint-newcomer.sh \
    'set +e; [ -f "$d/guard-awk-lib.sh" ] && . "$d/guard-awk-lib.sh" 2>/dev/null; set -e
awk "{print}" file'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/lint-newcomer.sh:2:" <<<"$output"
}

# The DOWNWARD hop: the resolver is reached through the anchor's own source
# statement rather than named in the gate, so renaming it moves the surface
# with it.
@test "the closure derivation reaches a library the anchor itself sources" {
  fixture_repo_bare
  fixture_file .gaia/scripts/guard-awk-lib.sh \
    'set +e; [ -f "$d/awk-interp-lib.sh" ] && . "$d/awk-interp-lib.sh" 2>/dev/null; set -e'
  fixture_file .gaia/scripts/awk-interp-lib.sh 'awk "{print}" file'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/awk-interp-lib.sh:1:" <<<"$output"
}

# --- discovery is armed, not merely correct --------------------------------

# The lie-green case this status exists for, and the one a derived surface
# makes genuinely reachable: renaming or deleting the anchor empties the
# closure while the tree around it is still full of tracked shell, so the scan
# has files to walk and none of them is in scope. A clean pass there would
# certify a surface the gate never opened.
@test "an empty closure is a hard error, never a clean tree" {
  fixture_repo_bare
  fixture_file .gaia/scripts/renamed-lib.sh 'true'
  run_linter
  [ "$status" -ne 0 ]
  [ "$status" -eq 4 ]
  grep -qF -- "the closure anchor .gaia/scripts/guard-awk-lib.sh is not in the tracked shell set" <<<"$output" || return 1
  grep -qF -- "nothing was scanned" <<<"$output"
}

# Distinct from the empty CLOSURE above: here the tracked shell set itself came
# back empty, which the shared library reports and this gate forwards rather
# than flattening. An operator handed one status for both would look at the
# wrong thing.
@test "an empty tracked shell set is distinct from an empty closure" {
  fixture_repo_bare
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "no tracked files matched the scan surface" <<<"$output"
}

@test "a discovery that never ran exits distinctly from a surface that came back empty" {
  TMP="$( new_tmp )"
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
  [ "$status" -eq 3 ]
  grep -qF -- "discovery failed" <<<"$output"
}

@test "a missing guard-awk-lib.sh beside the gate is its own refusal" {
  TMP="$( new_tmp )"
  cp "$LINTER" "$TMP/lint-awk-interpreter-pin.sh"
  run bash -c "cd '$TMP' && bash '$TMP/lint-awk-interpreter-pin.sh' 2>&1"
  [ "$status" -eq 2 ]
  grep -qF -- "guard-awk-lib.sh is missing beside this script" <<<"$output"
}

@test "an untracked file carrying the class is not scanned" {
  fixture_repo
  mkdir -p "$TMP/.gaia/scripts"
  printf '%s\n' 'set +e; [ -f "$d/guard-awk-lib.sh" ] && . "$d/guard-awk-lib.sh" 2>/dev/null; set -e
awk "{print}" file' > "$TMP/.gaia/scripts/untracked.sh"
  run_linter
  [ "$status" -eq 0 ]
}

# A file the walk could not read to the end is never certified clean. An
# unterminated literal swallows the rest of the file, so a clean verdict over
# it would mean nothing; the gate says so instead.
@test "a file the walk left desynced is reported rather than certified" {
  fixture_repo_bare
  fixture_file .gaia/scripts/guard-awk-lib.sh "PROG='unterminated"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "ERROR:" <<<"$output" || return 1
  grep -qF -- "was still open at end of file" <<<"$output"
}

# --- the two output lines the roster row demands ---------------------------

# .gaia/scripts/tests/shell-lint.bats derives, from whole-tree-invariants.sh
# itself, every guard excluded from the WTI roster on the ground that
# shell-lint runs it, and asserts this gate's own clean line in the gate's
# output. bats `run` merges both streams, so no assertion over `$output` can
# see which one it landed on; this test splits them.
@test "the clean line is printed on stderr, not on stdout" {
  fixture_repo
  fixture_consumer 'true'
  run bash -c "cd '$TMP' && bash '$LINTER' >'$TMP/out' 2>'$TMP/err'"
  [ "$status" -eq 0 ]
  grep -qF -- "lint-awk-interpreter-pin: clean" "$TMP/err" || return 1
  grep -qF -- "lint-awk-interpreter-pin: clean" "$TMP/out" && return 1
  true
}

@test "findings are printed on stdout, where a caller reading the report sees them" {
  fixture_repo
  fixture_consumer 'awk "{print}" file'
  run bash -c "cd '$TMP' && bash '$LINTER' >'$TMP/out' 2>'$TMP/err'"
  [ "$status" -eq 1 ]
  grep -qF -- "awk in command position" "$TMP/out"
}

# --- the registrations a folded guard owes ---------------------------------

# The roster obligation, proven against a staged mirror rather than by reading
# the row. The candidate sweep resolves its runner and its scan root from its
# own filename with no environment override, so a copied runner alone is never
# consulted: the whole tree has to be mirrored. The live runner is never
# edited.
@test "removing the whole-tree roster row reds the candidate sweep" {
  TMP="$( new_tmp )"
  local mirror="$TMP/mirror" f
  mkdir -p "$mirror/.gaia/tests/lib" "$mirror/.gaia/tests/helpers" "$mirror/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/tests/lib/whole-tree-invariants.bats" "$mirror/.gaia/tests/lib/"
  # That suite's setup() sources helpers beside it, resolved from its own
  # BATS_TEST_DIRNAME, so a mirror holding only the suite aborts in setup and
  # the control below reds for the mirror rather than for the missing row.
  # Mirror the whole helpers directory rather than the one file setup happens
  # to source today, so a helper added there does not silently break this.
  cp "$REPO_ROOT"/.gaia/tests/helpers/*.sh "$mirror/.gaia/tests/helpers/"
  for f in "$REPO_ROOT"/.gaia/scripts/lint-*.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mirror/.gaia/scripts/${f##*/}"
  done

  # Control first: the mirror with the row intact must be GREEN, or the red
  # below is attributable to the mirror rather than to the missing row.
  cp "$REPO_ROOT/.gaia/tests/whole-tree-invariants.sh" "$mirror/.gaia/tests/"
  run bats --filter 'every candidate checker is either a member or a documented exclusion' \
    "$mirror/.gaia/tests/lib/whole-tree-invariants.bats"
  [ "$status" -eq 0 ]

  grep -v -- 'lint-awk-interpreter-pin.sh|runs transitively' \
    "$REPO_ROOT/.gaia/tests/whole-tree-invariants.sh" > "$mirror/.gaia/tests/whole-tree-invariants.sh"
  run bats --filter 'every candidate checker is either a member or a documented exclusion' \
    "$mirror/.gaia/tests/lib/whole-tree-invariants.bats"
  [ "$status" -ne 0 ]
  grep -qF -- "lint-awk-interpreter-pin.sh" <<<"$output"
}

# The inventory obligation, driven the same way: red against a copy of the page
# with the row removed, green against the real one.
@test "removing the scripts-inventory row reds that guard" {
  TMP="$( new_tmp )"
  local root="$TMP/root" inventory="$REPO_ROOT/.gaia/scripts/lint-scripts-wiki-inventory.sh" f
  mkdir -p "$root/.gaia/scripts" "$root/wiki/concepts"
  for f in "$REPO_ROOT"/.gaia/scripts/lint-*.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/.gaia/scripts/${f##*/}"
  done
  grep -v -- 'lint-awk-interpreter-pin.sh' \
    "$REPO_ROOT/wiki/concepts/GAIA Scripts.md" > "$root/wiki/concepts/GAIA Scripts.md"
  git -C "$root" init -q .
  git -C "$root" add -A
  run bash -c "bash '$inventory' '$root' 2>&1"
  [ "$status" -eq 1 ]
  grep -qF -- "lint-awk-interpreter-pin.sh" <<<"$output"

  # Green against the real page, which is the half that says the red above was
  # the missing row rather than the mirror.
  cp "$REPO_ROOT/wiki/concepts/GAIA Scripts.md" "$root/wiki/concepts/GAIA Scripts.md"
  run bash -c "bash '$inventory' '$root' 2>&1"
  [ "$status" -eq 0 ]

  run bash -c "bash '$inventory' '$REPO_ROOT' 2>&1"
  [ "$status" -eq 0 ]
}

# The release-exclusion obligation. Its only enforcement runs at release time,
# so nothing else in this repository would catch the omission; the entry is
# asserted here, and so is the reasoned paragraph above it, because a bare path
# with no reason is the shape that entry format exists to prevent.
@test "the gate is listed in .gaia/release-exclude under a reasoned paragraph" {
  local prior
  grep -qx -- '\.gaia/scripts/lint-awk-interpreter-pin\.sh' "$REPO_ROOT/.gaia/release-exclude" || return 1
  # Captured whole and trimmed in the shell rather than piped into `head`: a
  # quiet reader that closes the pipe early is the shape
  # .gaia/scripts/lint-sigpipe-readers.sh flags, and it scans this file.
  prior="$( grep -B1 -x -- '\.gaia/scripts/lint-awk-interpreter-pin\.sh' "$REPO_ROOT/.gaia/release-exclude" )"
  prior="${prior%%
*}"
  case "$prior" in
    '#'*) ;;
    *) return 1 ;;
  esac
  [ "${#prior}" -gt 120 ]
}

# --- the real tree ---------------------------------------------------------

@test "the real closure passes the gate" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}
