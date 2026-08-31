#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so its text reaches the fixture file unexpanded. The prose IS the thing under
# test, so letting the shell touch it would delete the evidence.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-stale-cardinals.sh: the static gate that flags a
# definite cardinal naming a countable set of repository artifacts in a comment
# or a bats `@test` name, where nothing recounts the set.
#
# Three jobs. Prove the detector fires on the class; prove it stays quiet on
# every legitimate shape, which for this gate is the load-bearing half, because
# the predicate is a prose predicate and a gate nobody can keep green gets
# switched off; and assert the real scanned tree is clean so a regression fails
# CI.
#
# Two tests are load-bearing beyond coverage, and both carry a historical form
# verbatim rather than a tidied stand-in. A gate written for a class must red
# against that class's real shape or it asserts nothing about the class it was
# written for. `reds against the naming-convention header form` and `reds
# against the derived-count separator form` are the two instances that motivated
# this gate, copied from the comments they were found in: one spells its
# cardinal as a word and sits directly against its noun, the other spells it as
# digits and sits behind a modifier. They fail differently, and a detector that
# reaches one does not necessarily reach the other -- the digit form was in fact
# missed by the first draft of the noun vocabulary, which is why it is pinned
# here rather than trusted.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The gate resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added. It sources
# guard-awk-lib.sh from beside its own path, which is the real .gaia/scripts/
# rather than the fixture, so no fixture seeds a copy of the library.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-stale-cardinals.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_repo_bare: an initialized git repo in $TMP with no files yet and no
# seeded surface. Point a test that needs an empty scan set here.
fixture_repo_bare() {
  TMP="$(mktemp -d -t stale-cardinals-lint-XXXXXX)"
  git -C "$TMP" init -q .
}

# fixture_repo: fixture_repo_bare with a benign tracked file on BOTH surfaces
# already seeded. The gate hard-errors on an empty *.sh discovery set and
# gaia_guard_bats_files hard-errors on an empty *.bats surface, so an ordinary
# fixture needs one of each in place to reach the class detection at all --
# seeding only the surface a given test exercises trades that test's real
# verdict for the other surface's ERROR, which carries the same exit status.
fixture_repo() {
  fixture_repo_bare
  fixture_file seed.bats '@test "seed" { true; }'
  fixture_file seed.sh 'true'
}

# fixture_file <relpath> <body>: write <body> verbatim to $TMP/<relpath> and
# track it. `printf %s` never interprets an escape, so the body reaches the file
# as authored. Call fixture_repo first.
fixture_file() {
  local dest="$TMP/$1"
  mkdir -p "$( dirname "$dest" )"
  printf '%s\n' "$2" > "$dest"
  git -C "$TMP" add -A
}

# fixture_script <body>: the common case, a tracked shell script.
fixture_script() {
  fixture_file check.sh "$1"
}

# A tracked bats suite is the only surface where the pragma is honored and the
# only one carrying a `@test` name, so several tests below need one. They call
# `fixture_file probe.bats` directly rather than through a wrapper of their own.
#
# That is not a style choice. The shared library classifies a bats line as
# fixture DATA partly by the command word that writes it, against a closed set
# of writer names it recognizes (guard-awk-lib.sh, `G_classify`). `fixture_file`
# and `fixture_script` are in that set; a locally-invented wrapper is not, so
# every line of a multi-line body handed to one is read as executed shell and
# this suite's own fixture prose is reported as a live finding. Adding a name to
# the shared set to suit one suite widens a contract every consumer of that
# library depends on, so the call goes direct instead.

# at_test <name>: one literal bats test declaration, ASSEMBLED rather than
# written out.
#
# Bats preprocesses this file before bash ever sees it, and it rewrites any
# SOURCE line whose first token is `@test` into a bats_test_function call. It
# does that inside a single-quoted string exactly as it does at the top level,
# and it strips leading whitespace first, so indenting does not save the line
# either. A fixture needing a real `@test` on disk therefore cannot spell one at
# the start of a line in this file.
#
# The failure is silent and it looks like a gate bug: the fixture is written,
# tracked and scanned as usual, and the gate answers correctly about the
# bats_test_function line it was actually handed, which carries no test name and
# so no instance. Assembling the line keeps the token off column one.
at_test() {
  printf '@test "%s" { true; }' "$1"
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
}

# --- the real tree ---------------------------------------------------------

@test "the real tracked tree passes the gate" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER' 2>&1"
  [ "$status" -eq 0 ]
  grep -qF -- "lint-stale-cardinals: clean" <<<"$output"
}

# The clean-tree test above is worth nothing unless this gate can red on the
# real tree at all. Copying a tracked file back into a fixture repo with one
# phrase injected is the closest reachable mutation: same file, same shape,
# one instance added.
@test "a real tracked comment with one instance injected reds" {
  fixture_repo
  fixture_file real.sh "$( cat "$REPO_ROOT/.gaia/tests/helpers/files.sh" )
# and the seven files below are granted to nobody"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "real.sh:" <<<"$output"
}

# --- the class fires, historical forms first -------------------------------

@test "reds against the naming-convention header form" {
  fixture_repo
  fixture_script '#!/usr/bin/env bash
# This file is not a check, so it takes the *-lib.sh naming its ten siblings
# use and is swept by nothing.
true'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:2:" <<<"$output"
  grep -qF -- "states a count of a set nothing recounts" <<<"$output"
}

@test "reds against the derived-count separator form" {
  fixture_repo
  fixture_script '#!/usr/bin/env bash
# Credits the 412 fixture lines whose literal body carries a semicolon.
true'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:2:" <<<"$output"
}

@test "reds on an all-quantified cardinal" {
  fixture_repo
  fixture_script '# Widening this set moves all three consumers at once.
true'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "reds on a possessive determiner" {
  fixture_repo
  fixture_script '# The denial its five siblings already give.
true'
  run_linter
  [ "$status" -eq 1 ]
}

@test "reds on a demonstrative determiner" {
  fixture_repo
  fixture_script '# These four tests pin the record field.
true'
  run_linter
  [ "$status" -eq 1 ]
}

@test "reds regardless of letter case" {
  fixture_repo
  fixture_script '# Earned write lands for ALL THREE MEMBERS.
true'
  run_linter
  [ "$status" -eq 1 ]
}

@test "reds inside a bats test name" {
  fixture_repo
  fixture_file probe.bats '@test "the write lands for all three members" {
  true
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.bats:1:" <<<"$output"
}

# The whitespace test on a clause ender. A colon inside a label namespace or a
# dot inside a path is punctuation the walk must read straight through: without
# the whitespace requirement each one ends the clause and silently suppresses a
# real instance, which is the failure direction a barrier can take.
@test "an ender inside an identifier does not suppress the finding" {
  fixture_repo
  fixture_script '# The three `surface:` tests above already prove the axis.
true'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

# --- the class stays quiet -------------------------------------------------

@test "stays quiet on a bare cardinal with no determiner" {
  fixture_repo
  fixture_script '# Three read sites build the path themselves.
true'
  run_linter
  [ "$status" -eq 0 ]
}

@test "stays quiet on a cardinality of two" {
  fixture_repo
  fixture_script '# The two consumers of a whole-PR base do not agree.
true'
  run_linter
  [ "$status" -eq 0 ]
}

@test "stays quiet on a noun outside the vocabulary" {
  fixture_repo
  fixture_script '# There are all three ways to read this and no more.
true'
  run_linter
  [ "$status" -eq 0 ]
}

# The sentence-boundary control. Without it a comment closing one sentence on
# `at all.` and opening the next on a cardinal presents a determiner, a cardinal
# and a noun in order, and the gate invents a phrase neither sentence contains.
@test "stays quiet across a sentence boundary" {
  fixture_repo
  fixture_script '# It looks into a tree that holds no SPECs at all. Three read
# sites build the path themselves rather than calling a library.
true'
  run_linter
  [ "$status" -eq 0 ]
}

@test "stays quiet when the noun sits beyond the window" {
  fixture_repo
  fixture_script '# The three separately maintained downstream consumers differ.
true'
  run_linter
  [ "$status" -eq 0 ]
}

@test "stays quiet on a code line carrying the same words" {
  fixture_repo
  fixture_script 'echo "the three consumers"
true'
  run_linter
  [ "$status" -eq 0 ]
}

@test "stays quiet on a trailing comment that shares its line with code" {
  fixture_repo
  fixture_script 'true   # the three consumers below
true'
  run_linter
  [ "$status" -eq 0 ]
}

# --- fixture discrimination on the bats surface ----------------------------

# A suite writing the bad shape into a fixture file is documenting the class,
# not committing it. The shared library answers that, so this test is what
# proves this gate consults the answer rather than reporting the literal.
@test "a quoted heredoc body carrying the shape is not reported" {
  fixture_repo
  fixture_file probe.bats '@test "seeds a fixture" {
  cat > "$BATS_TEST_TMPDIR/f.sh" <<'"'"'EOF'"'"'
# the four callers all pass well-formed arguments
EOF
  true
}'
  run_linter
  [ "$status" -eq 0 ]
}

# --- the pragma ------------------------------------------------------------

@test "a pragma waives a test name beneath it in a bats suite" {
  fixture_repo
  fixture_file probe.bats "# gaia-lint-ignore lint-stale-cardinals: quoting the shape on purpose
$( at_test 'the write lands for all three members' )"
  run_linter
  [ "$status" -eq 0 ]
}

# The pragma's reach stops at a comment, and the reason is the shared library's
# block grammar rather than anything this gate decides: a comment line beneath a
# pragma CONTINUES its reason, and the target is the first non-comment line
# below the block. So a pragma can never sit above a comment as its target. This
# pins that, because the alternative reading -- that the waiver is available on
# every line this gate reports -- would be discovered only by someone writing
# one and watching it do nothing.
@test "a pragma does not waive an instance on a comment line" {
  fixture_repo
  fixture_file probe.bats "# gaia-lint-ignore lint-stale-cardinals: cannot reach the line below
# the four callers all pass well-formed arguments
$( at_test 'probe' )"
  run_linter
  [ "$status" -eq 1 ]
}

@test "an unused pragma in a bats suite is reported" {
  fixture_repo
  fixture_file probe.bats "# gaia-lint-ignore lint-stale-cardinals: nothing beneath this waives
$( at_test 'probe' )"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-lint-ignore" <<<"$output"
}

@test "a pragma on a shell script reports that it waives nothing there" {
  fixture_repo
  fixture_script '# gaia-lint-ignore lint-stale-cardinals: honored nowhere on this surface
true'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "honored only in *.bats" <<<"$output"
}

# --- the discovery sets fail loudly rather than passing empty ---------------

@test "an empty shell discovery set is an error, never a clean tree" {
  fixture_repo_bare
  fixture_file seed.bats '@test "seed" { true; }'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output"
}

@test "an empty bats surface is an error, never a clean tree" {
  fixture_repo_bare
  fixture_file check.sh 'true'
  run_linter
  [ "$status" -eq 1 ]
}
