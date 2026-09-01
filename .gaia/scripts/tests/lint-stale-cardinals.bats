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

# fixture_repo: fixture_repo_bare with a benign tracked file on EVERY surface
# already seeded. The gate hard-errors on an empty *.sh discovery set and on an
# empty C-family one, and gaia_guard_bats_files hard-errors on an empty *.bats
# surface, so an ordinary fixture needs one of each in place to reach the class
# detection at all -- seeding only the surface a given test exercises trades
# that test's real verdict for another surface's ERROR, which carries the same
# exit status.
fixture_repo() {
  fixture_repo_bare
  fixture_file seed.bats '@test "seed" { true; }'
  fixture_file seed.sh 'true'
  fixture_file app/seed.ts 'export const seed = 1;'
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
  fixture_file app/seed.ts 'export const seed = 1;'
  run_linter
  [ "$status" -eq 1 ]
  # Both empty-discovery arms end in "nothing was scanned", so the needle has to
  # be the half that names the surface, or the assertion passes on either.
  grep -qF -- "no tracked shell scripts" <<<"$output"
}

@test "an empty bats surface is an error, never a clean tree" {
  fixture_repo_bare
  fixture_file check.sh 'true'
  fixture_file app/seed.ts 'export const seed = 1;'
  run_linter
  [ "$status" -eq 1 ]
}

@test "an empty C-family discovery set is an error, never a clean tree" {
  fixture_repo_bare
  fixture_file seed.bats '@test "seed" { true; }'
  fixture_file check.sh 'true'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "no tracked C-family sources" <<<"$output"
}

# --- the C-family surface --------------------------------------------------
#
# The `#` reader above and the `//` / `/* */` reader below share one predicate,
# so the vocabulary, window and clause-ender tests above cover both. What is
# tested here is only what the second reader adds: which lines it decides are
# prose, and which it decides are code.

@test "reds on a full-line // comment" {
  fixture_repo
  fixture_file app/probe.ts '// Widening this set moves all three consumers at once.
export const probe = 1;'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "app/probe.ts:1:" <<<"$output"
  grep -qF -- "states a count of a set nothing recounts" <<<"$output"
}

@test "reds inside a block comment carrying a JSDoc leader" {
  fixture_repo
  fixture_file app/probe.tsx '/**
 * The denial its five siblings already give.
 */
export const probe = 1;'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "app/probe.tsx:2:" <<<"$output"
}

@test "reds on a block comment opened and closed on one line" {
  fixture_repo
  fixture_file .storybook/probe.ts '/* These four tests pin the record field. */
export const probe = 1;'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".storybook/probe.ts:1:" <<<"$output"
}

# The JSX comment container. `{/* ... */}` is the ordinary way to comment inside
# a render body, so a `.tsx` surface that cannot read it is read in name only.
# Both shapes are pinned: the single-line container, and the multi-line one whose
# opener and closer sit on different lines.
@test "reds inside a single-line JSX comment container" {
  fixture_repo
  fixture_file app/probe.tsx '{/* Widening this set moves all three consumers at once. */}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "app/probe.tsx:1:" <<<"$output"
}

@test "reds inside a multi-line JSX comment container" {
  fixture_repo
  fixture_file app/probe.tsx '{/* The denial
    its five siblings already give. */}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "app/probe.tsx:2:" <<<"$output"
}

# Stripping the container brace must not turn an ordinary braced code line into
# prose: only a brace standing immediately before a comment opener is consumed.
@test "a braced code line is not read as a JSX comment" {
  fixture_repo
  fixture_file app/probe.tsx '{allThreeConsumers}
{"all three consumers"}'
  run_linter
  [ "$status" -eq 0 ]
}

@test "stays quiet on a trailing // comment that shares its line with code" {
  fixture_repo
  fixture_file app/probe.ts 'export const probe = 1; // the three consumers below'
  run_linter
  [ "$status" -eq 0 ]
}

@test "stays quiet on a C-family code line carrying the same words" {
  fixture_repo
  fixture_file app/probe.ts 'export const label = "the three consumers";'
  run_linter
  [ "$status" -eq 0 ]
}

# The string-literal control, and the whole reason the reader takes only a
# comment that OWNS its line. A `/*` written inside a string sits behind the
# quote that opened it, so it never opens a block and the lines below it are
# never read as prose.
@test "a block opener inside a string literal opens no comment" {
  fixture_repo
  fixture_file app/probe.ts 'export const opener = "/*";
export const claim = "all three consumers";
export const closer = "*/";'
  run_linter
  [ "$status" -eq 0 ]
}

# The other half of the same rule: a block that a line of CODE opened is never
# entered, so its continuation lines are not read either. That is a fail-open
# the header records, and it is pinned here so the direction stays deliberate.
@test "a block opened after code on its line is not entered" {
  fixture_repo
  fixture_file app/probe.ts 'export const probe = 1; /* opened after code
the four callers all pass well-formed arguments
*/'
  run_linter
  [ "$status" -eq 0 ]
}

# Closing a block mid-line must stop the prose there rather than handing the
# rest of the line to the predicate as if it were comment text.
@test "code after a block close on the same line is not scanned" {
  fixture_repo
  fixture_file app/probe.ts '/* opened
   still prose */ export const all = ["three", "consumers"];'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a pragma on a C-family source reports that it waives nothing there" {
  fixture_repo
  fixture_file app/probe.ts '// gaia-lint-ignore lint-stale-cardinals: honored nowhere on this surface
export const probe = 1;'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "honored only in *.bats" <<<"$output"
}

# The block spelling is the dominant one on this surface, and the arm that reads
# the pragma compares a whole word rather than tokenizing, so the JSDoc leader
# reaches it where it never reaches the class predicate. Both spellings are
# pinned, since only one of them was silent.
@test "a C-family pragma inside a JSDoc block reports that it waives nothing" {
  fixture_repo
  fixture_file app/probe.ts '/**
 * gaia-lint-ignore lint-stale-cardinals: honored nowhere on this surface
 */
export const probe = 1;'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "honored only in *.bats" <<<"$output"
}

# The report names this guard and asserts this guard's honoring rule, so it must
# fire only for a pragma naming this guard. The `#` reader gets that from the
# shared library, which takes the guard name; the C-family arm has no library and
# has to make the same discrimination itself.
@test "a C-family pragma naming a different guard is not reported by this one" {
  fixture_repo
  fixture_file app/probe.ts '// gaia-lint-ignore lint-git-path-quoting: a sibling guard, not this one
export const probe = 1;'
  run_linter
  [ "$status" -eq 0 ]
}

# The documented FAIL-CLOSED direction, pinned so the header's disclosure is
# enforced rather than asserted. A template-literal line opening with `/*` raises
# the block state, and nothing inside a literal lowers it, so every line to the
# end of the file is read as prose. The finding below lands on executable code
# OUTSIDE the literal, which is the part the header has to state honestly.
@test "a block opener inside a template literal runs on to the end of the file" {
  fixture_repo
  fixture_file app/probe.ts 'export const tpl = `
/* opened inside a template literal
`;
export const label = "all three consumers";'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "app/probe.ts:4:" <<<"$output"
}

@test "a real tracked C-family file with one instance injected reds" {
  fixture_repo
  local real
  # Captured and asserted rather than substituted straight into the argument: a
  # failed command substitution there does not abort under `set -e`, so a moved
  # or renamed source would leave the fixture holding the appended line alone.
  # The gate still reds on it and the test still passes, having stopped
  # exercising the real tracked file its own name rests on.
  real="$( cat "$REPO_ROOT/.gaia/cli/src/labels/index.ts" )"
  [ -n "$real" ]
  fixture_file app/real.ts "$real
// and the seven files below are granted to nobody"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "app/real.ts:" <<<"$output"
}

# --- the C-family pathspecs match the rule they arm ------------------------
#
# .claude/rules/guards-must-fail.md, "Derive the arming condition from the
# surface the rule governs": CFAM_GLOBS is a hand transcription of
# code-comments.md's own glob list, so the two are written separately and a
# check that they still agree is owed. A glob added to the rule and not to the
# gate is a governed surface nothing reads, and it reports clean.

# rule_globs_expanded: every glob code-comments.md binds, brace lists expanded.
# The expansion is done by hand rather than by the shell, which would also try
# to match the result against the cwd and delete an entry nothing on disk
# satisfies.
rule_globs_expanded() {
  local entry prefix inner suffix
  while IFS= read -r entry; do
    case "$entry" in
      *'{'*)
        prefix="${entry%%\{*}"
        inner="${entry#*\{}"
        inner="${inner%\}*}"
        while [ -n "$inner" ]; do
          case "$inner" in
            *,*) suffix="${inner%%,*}"; inner="${inner#*,}" ;;
            *)   suffix="$inner"; inner="" ;;
          esac
          printf '%s%s\n' "$prefix" "$suffix"
        done
        ;;
      *) printf '%s\n' "$entry" ;;
    esac
  done < <(
    sed -n '/^paths:/,/^---/p' "$REPO_ROOT/.claude/rules/code-comments.md" \
      | sed -n "s/^[[:space:]]*- '\(.*\)'[[:space:]]*\$/\1/p"
  )
}

# The half of that list the C-family reader owns: everything the `#` reader
# does not, which is every entry that is not a shell script or a bats suite.
cfam_globs_governed() {
  rule_globs_expanded | grep -v -e '\.sh$' -e '\.bats$' | LC_ALL=C sort
}

# The pathspecs the gate declares, with the `:(glob)` magic prefix and the shell
# quoting stripped back off.
cfam_globs_declared() {
  sed -n '/^CFAM_GLOBS=(/,/^)/p' "$REPO_ROOT/.gaia/scripts/lint-stale-cardinals.sh" \
    | sed -n "s/^[[:space:]]*':(glob)\(.*\)'[[:space:]]*\$/\1/p" \
    | LC_ALL=C sort
}

# fixture_path_for <glob>: the concrete file a glob of the shape
# `<dir>/**/*.<ext>` matches, which is every entry the rule binds.
fixture_path_for() {
  printf '%s\n' "$1" | sed 's|\*\*/\*|probe|'
}

# rule_cfam_raw: the rule's C-family entries UNEXPANDED, in the brace form the
# rule file writes them, which is the form the workflow filter copies. The
# expansion cfam_globs_governed does is what the gate's own pathspecs need; the
# filter needs the source spelling instead.
rule_cfam_raw() {
  sed -n '/^paths:/,/^---/p' "$REPO_ROOT/.claude/rules/code-comments.md" \
    | sed -n "s/^[[:space:]]*- '\(.*\)'[[:space:]]*\$/\1/p" \
    | grep -v -e "\.sh\$" -e "\.bats\$" \
    | LC_ALL=C sort
}

# workflow_shell_filter_globs: the globs the FIRST `shell:` paths-filter block in
# shell-lint.yml lists. First rather than every block: the macos leg carries a
# deliberately narrower filter for a run that returns before the folded guards,
# and folding the two together would let that leg satisfy an assertion about the
# ubuntu one.
workflow_shell_filter_globs() {
  awk '
    done_blk { next }
    !inblk && $0 ~ /^[[:space:]]*shell:[[:space:]]*$/ { inblk = 1; next }
    inblk {
      if ($0 ~ /^[[:space:]]*$/) next
      match($0, /^[[:space:]]*/)
      if (RLENGTH < 14) { inblk = 0; done_blk = 1; next }
      if ($0 ~ /^[[:space:]]*- /) {
        line = $0
        sub(/^[[:space:]]*- /, "", line)
        gsub(/^\047|\047$/, "", line)
        print line
      }
    }
  ' "$REPO_ROOT/.github/workflows/shell-lint.yml"
}

@test "the gate's C-family pathspecs are exactly the globs the rule binds outside shell and bats" {
  local declared governed
  declared="$(cfam_globs_declared)"
  governed="$(cfam_globs_governed)"
  [ -n "$declared" ]
  [ -n "$governed" ]
  [ "$declared" = "$governed" ]
}

# Two derivations that both come back empty compare equal, and two that both
# come back SHORT compare equal as well, so the check above needs a control that
# each side really read its own file. Counts rather than a copied entry, so
# nothing here rots when the rule's list changes: the rule must yield more globs
# than the C-family half keeps, which is true only if the frontmatter parsed AND
# the shell/bats filter removed something, and the half kept must not be empty.
@test "each side of the pathspec parity check reads its own source" {
  local all kept declared
  all="$(rule_globs_expanded | grep -c '')"
  kept="$(cfam_globs_governed | grep -c '')"
  declared="$(cfam_globs_declared | grep -c '')"
  [ "$kept" -gt 0 ]
  [ "$all" -gt "$kept" ]
  [ "$declared" -eq "$kept" ]
}

# Every glob the rule binds earns its own proof that the scan really reaches it.
# A complete transcription behind a correct reader still leaves a surface unread
# when one pathspec is malformed, and a pathspec that matches nothing is silent
# in exactly the voice of a clean file. Driven per element off the rule's own
# list rather than off a copy of it, per .claude/rules/bats-assertions.md.
@test "the scan reaches every C-family glob the rule binds" {
  fixture_repo
  local glob rel
  while IFS= read -r glob; do
    rel="$( fixture_path_for "$glob" )"
    fixture_file "$rel" '/* Widening this set moves all three consumers at once. */'
  done < <(cfam_globs_governed)

  run_linter
  [ "$status" -eq 1 ]

  while IFS= read -r glob; do
    rel="$( fixture_path_for "$glob" )"
    grep -qF -- "$rel:1:" <<<"$output" || { echo "$rel: never scanned" >&2; return 1; }
  done < <(cfam_globs_governed)
}

# The third transcription, and the one whose absence is silent. The gate reads
# its own pathspecs and the tests above hold those to the rule, but CI decides
# whether the gate RUNS at all from a fourth list in shell-lint.yml. A glob added
# to the rule and to the gate, and not to that filter, leaves a pull request
# touching only the new surface resolving `shell=false`: the job skips the gate
# and reports green having scanned nothing, which is the same fail-open the gate
# itself exists to close, one layer up. workflow-filter-coverage.bats does not
# reach it, its own header puts a gated step's transitive inputs out of scope.
#
# A subset rather than an equality: the filter legitimately carries globs that
# have nothing to do with this gate (the husky hooks, the workflow tree, every
# tracked markdown file), and each of those is owned by whichever guard put it
# there. What is owed here is that the filter carries EVERY glob this rule binds.
@test "shell-lint.yml's paths filter carries every C-family glob the rule binds" {
  local glob filter
  filter="$(workflow_shell_filter_globs)"
  [ -n "$filter" ]
  while IFS= read -r glob; do
    grep -qxF -- "$glob" <<<"$filter" \
      || { echo "$glob: bound by the rule, absent from shell-lint.yml's filter" >&2; return 1; }
  done < <(rule_cfam_raw)
}

# Non-vacuity for the check above, every side derived so nothing here rots. The
# rule must yield C-family entries at all, and the filter block must be read as a
# strict superset of them. The third comparison is what pins the READ REGION: a
# terminator that never fires swallows the macos leg's filter too, which only
# widens the set, so both of the first two assertions survive it while the
# subset check silently starts accepting a glob that is present in that leg
# alone. Reading from the first `shell:` to end of file must therefore yield
# strictly more entries than the single-block read does.
@test "the workflow filter parity check reads one block and a non-empty rule half" {
  local raw filter to_eof
  raw="$(rule_cfam_raw | grep -c '')"
  filter="$(workflow_shell_filter_globs | grep -c '')"
  to_eof="$(
    sed -n "/^[[:space:]]*shell:[[:space:]]*\$/,\$p" "$REPO_ROOT/.github/workflows/shell-lint.yml" \
      | sed -n "s/^[[:space:]]*- '\(.*\)'[[:space:]]*\$/\1/p" | grep -c ''
  )"
  [ "$raw" -gt 0 ]
  [ "$filter" -gt "$raw" ]
  [ "$to_eof" -gt "$filter" ]
}
