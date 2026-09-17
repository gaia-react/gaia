#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so the `$` expansions inside it reach the fixture file as literal text. An
# unrooted path versus a `${BASH_SOURCE[0]}`-rooted one IS the distinction under
# test, so letting this shell expand one would delete the evidence.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-hook-cwd-relative-loads.sh: the static gate that
# flags a hook locating framework code by a bare repository-root-relative path,
# which resolves against the process working directory rather than against the
# hook checkout, so a single `cd` makes a moved working directory
# indistinguishable from a missing library and buys the fail-open written for
# the missing one.
#
# THIS SUITE IS THE BLOCKING RUNNER. shell-lint.sh invokes the gate a second,
# advisory way, but a gate run against a tree that is already clean reports
# clean whether its predicate works or not, so a broken predicate is
# indistinguishable from an honest tree there. Every test below drives the gate
# against a fixture tree shaped one way at a time.
#
# Three jobs. Prove the detector fires on each position the gate header
# enumerates; prove it stays quiet on every shape the header lists as
# deliberately not a hit, which for this gate includes the repair it advertises,
# since a gate that reds on its own advice cannot ship; and assert the real
# scanned tree is clean so a regression fails CI.
#
# The quiet tests carry more weight here than in a sibling gate, because this
# class is spelled the same way in code and in the prose that documents it. Each
# of the three context trackers (heredoc bodies, multi-line double-quoted
# strings, comment words) has a test naming the construct it protects, and the
# tree carries a live instance of each: without them the gate would red on the
# operator-facing deny messages that quote the very repair it recommends.
#
# One test is load-bearing beyond coverage. "reds against the historical
# red-verify-commit-check shape" carries the exact line gaia-react/gaia#1854 was
# filed against, so the gate is proven to reach the instance it was written for
# rather than a tidied stand-in.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The gate resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-hook-cwd-relative-loads.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_repo_bare: an initialized git repo in $TMP with an empty hooks
# directory and a COPY of the gate staged at its own repo-relative path, so the
# discovery comes back empty. Point a test that needs a short surface here.
#
# The staged copy is what makes every test below mean anything. The gate roots
# its scan surface at its OWN on-disk location rather than at the working
# directory, so running $LINTER with cwd set to the fixture would scan the real
# repository and report it clean, no matter what the fixture holds. Only a copy
# living inside the fixture reads the fixture. The empty `.claude/hooks` is
# deliberate too: the gate refuses (exit 2) when it cannot see that directory
# at its root, so creating it is what leaves the short-surface arm reachable.
fixture_repo_bare() {
  TMP="$(mktemp -d -t hookcwd-lint-XXXXXX)"
  git -C "$TMP" init -q .
  mkdir -p "$TMP/.claude/hooks" "$TMP/.gaia/scripts"
  STAGED_LINTER="$TMP/.gaia/scripts/lint-hook-cwd-relative-loads.sh"
  cp "$LINTER" "$STAGED_LINTER"
}

# fixture_repo: fixture_repo_bare plus enough benign tracked hooks to clear the
# gate own surface floor, so a test reaches class detection rather than the
# short-surface error. The seeds are named `seed-N.sh` so fixture_hook below can
# write `check.sh` without shrinking the surface. The count is read from the
# gate itself rather than restated, so raising the floor there cannot leave this
# helper seeding too few and every test failing for the wrong reason.
fixture_repo() {
  local floor n
  fixture_repo_bare
  floor="$( sed -n 's/^readonly SURFACE_FLOOR=\([0-9]*\)$/\1/p' "$LINTER" )"
  [ -n "$floor" ] || return 1
  mkdir -p "$TMP/.claude/hooks"
  n=0
  while [ "$n" -lt "$floor" ]; do
    printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/.claude/hooks/seed-$n.sh"
    n=$(( n + 1 ))
  done
  git -C "$TMP" add -A
}

# fixture_hook <body>: a tracked hook carrying <body>. Line 1 is the shebang and
# line 2 the `set`, so a one-line body reports at line 3.
fixture_hook() {
  mkdir -p "$TMP/.claude/hooks"
  printf '%s\n' "#!/usr/bin/env bash
set -uo pipefail
$1" > "$TMP/.claude/hooks/check.sh"
  git -C "$TMP" add -A
}

# run_linter: run the fixture's own staged copy of the gate. cwd is set to the
# fixture only so a failure here reads naturally; the gate no longer consults it.
run_linter() {
  run bash -c "cd '$TMP' && bash '$STAGED_LINTER' 2>&1"
}

# --- the class fires, one test per position the header enumerates -----------

@test "reds against the historical red-verify-commit-check shape" {
  fixture_repo
  fixture_hook '[ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh
type red_ledger_path >/dev/null 2>&1 || exit 0'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- "a file-test operand names a bare repo-relative path" <<<"$output"
}

@test "reds against the NEGATED spelling of the historical shape" {
  # The positive twin of the test above, and the idiomatic spelling of the
  # stand-down this gate exists to prevent: `[ ! -f <lib> ] && exit 0` reads a
  # moved working directory as a missing library exactly as the unnegated form
  # does. The `!` stands where the arm requires the test primary, so reaching it
  # takes an explicit optional negation rather than falling out of the unnegated
  # pattern. Both bracket forms and the quoted spelling ride this one test
  # because the negation is admitted once, ahead of the rest of the arm.
  fixture_repo
  fixture_hook '[ ! -f .claude/hooks/lib/red-ledger.sh ] && exit 0
[[ ! -f ".gaia/scripts/ledger-path-lib.sh" ]] && exit 0'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- ".claude/hooks/check.sh:4:" <<<"$output" || return 1
  grep -qF -- "a file-test operand names a bare repo-relative path" <<<"$output"
}

@test "flags a bare source operand" {
  fixture_repo
  fixture_hook '. .gaia/scripts/ledger-path-lib.sh'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- "a source operand names a bare repo-relative path" <<<"$output"
}

@test "flags an INDENTED source operand, the idiomatic spelling of the class" {
  fixture_repo
  fixture_hook 'if true; then
  . .claude/hooks/lib/red-ledger.sh
fi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:4:" <<<"$output" || return 1
  grep -qF -- "a source operand names a bare repo-relative path" <<<"$output"
}

@test "flags a TAB-indented source operand too" {
  fixture_repo
  fixture_hook "$(printf 'while :; do\n\tsource .gaia/scripts/ledger-path-lib.sh\ndone')"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:4:" <<<"$output" || return 1
  grep -qF -- "a source operand names a bare repo-relative path" <<<"$output"
}

@test "an indented VARIABLE-rooted load is still the repair, not a hit" {
  fixture_repo
  fixture_hook 'if true; then
  . "$_hook_dir/lib/red-ledger.sh"
fi'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "lint-hook-cwd-relative-loads: clean" <<<"$output"
}

@test "flags a bare interpreter argument" {
  fixture_repo
  fixture_hook 'bash .gaia/scripts/token-tally.sh --action review'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- "an interpreter argument names a bare repo-relative path" <<<"$output"
}

@test "flags an assignment naming a code file" {
  fixture_repo
  fixture_hook 'classifier=".gaia/scripts/classifier/classify-determinism.mjs"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- "this assignment names a bare repo-relative path to a code file" <<<"$output"
}

@test "flags the QUOTED spelling of each position, not only the bare one" {
  # The distinction is literal-versus-variable-rooted, never quoted-versus-
  # unquoted: a quoted literal resolves against the working directory exactly
  # as its bare spelling does. A gate that read only the bare form would report
  # clean over half its own class, and the tree carried a live quoted instance.
  fixture_repo
  fixture_hook '[ -f ".claude/hooks/lib/red-ledger.sh" ] && . ".claude/hooks/lib/red-ledger.sh"
bash ".gaia/scripts/token-tally.sh" --action review'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- ".claude/hooks/check.sh:4:" <<<"$output" || return 1
  grep -qF -- "a file-test operand names a bare repo-relative path" <<<"$output" || return 1
  grep -qF -- "an interpreter argument names a bare repo-relative path" <<<"$output"
}

@test "flags a single-quoted literal too" {
  fixture_repo
  fixture_hook ". '.gaia/scripts/ledger-path-lib.sh'"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "a source operand names a bare repo-relative path" <<<"$output"
}

@test "a quoted VARIABLE-rooted path is still the repair, not a hit" {
  # The negative control for the two tests above: adding the optional quote must
  # not turn the advertised repair into a finding.
  fixture_repo
  fixture_hook '_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _lib_dir=""
[ -f "$_lib_dir/red-ledger.sh" ] && . "$_lib_dir/red-ledger.sh"
bash "$_lib_dir/../../.gaia/scripts/token-tally.sh"'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "scans from its own root, not the working directory" {
  # The gate flags cwd-resolved paths, so it must not resolve its own surface
  # that way. Run from a subdirectory of the fixture it must still find the
  # planted hook rather than reporting an empty surface.
  fixture_repo
  fixture_hook '[ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh'
  mkdir -p "$TMP/app/components"
  run bash -c "cd '$TMP/app/components' && bash '$STAGED_LINTER' 2>&1"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output"
}

@test "reaches a hook under lib/, not only the top level" {
  fixture_repo
  mkdir -p "$TMP/.claude/hooks/lib"
  printf '%s\n' '#!/usr/bin/env bash
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh' \
    > "$TMP/.claude/hooks/lib/helper.sh"
  git -C "$TMP" add -A
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/lib/helper.sh:2:" <<<"$output"
}

# --- quiet on every shape the header lists as deliberately not a hit --------

@test "quiet on the BASH_SOURCE repair it advertises" {
  fixture_repo
  fixture_hook '_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _lib_dir=""
[ -n "$_lib_dir" ] && [ -f "$_lib_dir/red-ledger.sh" ] && . "$_lib_dir/red-ledger.sh"'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on the NEGATED spelling of the repair it advertises" {
  # The negative control for the widening: the arm admits a `!` in front of the
  # primary, so the variable-rooted repair written in the negated stand-down
  # style has to stay the repair rather than become a finding.
  fixture_repo
  fixture_hook '_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _lib_dir=""
[ ! -f "$_lib_dir/red-ledger.sh" ] && exit 0'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on a per-tree state path in ASSIGNMENT position" {
  fixture_repo
  fixture_hook 'marker=".claude/wiki-drift-checked"
config_path=".gaia/automation.json"'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on a per-tree state path in FILE TEST position" {
  # The sibling above pins the assignment arm, which reaches this shape only
  # because it is pinned to a code extension. The file-test arm is the other
  # position a state path is written in, and it needs the same pin for the same
  # reason: the remedy it hands out roots the operand at `${BASH_SOURCE[0]}`,
  # which is the root the gate's own header rules out for state, because a
  # `main-only` marker rooted at the script's directory follows a linked
  # worktree. Every live state site tests through a variable today, so this arm
  # is unexercised by the tree and only a fixture reaches it.
  fixture_repo
  fixture_hook '[ -f .claude/wiki-drift-checked ] || exit 0
[ -f ".gaia/automation.json" ] || exit 0'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on a NEGATED per-tree state path in FILE TEST position" {
  # The sibling above pins the unnegated spelling. Admitting a negation into the
  # arm must not re-open the misdirection that pin closed: a state path carries
  # no code extension in either spelling, so the negated form gives up the
  # operand for the same reason and the gate stays silent rather than
  # prescribing the `${BASH_SOURCE[0]}` root its own header rules out for state.
  fixture_repo
  fixture_hook '[ ! -f .claude/wiki-drift-checked ] && exit 0
[ ! -f ".gaia/automation.json" ] && exit 0'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on a git revision path, which git resolves from the repo root" {
  fixture_repo
  fixture_hook 'blob=$(git rev-parse "HEAD:.gaia/cli/templates/workflows/code-review-audit.yml.tmpl")'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on an interpreter argument the same line cds for" {
  fixture_repo
  fixture_hook 'members="$( cd "$tree_root" && bash .gaia/scripts/resolve-audit-members.sh )"'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on the class inside a heredoc body" {
  fixture_repo
  fixture_hook 'cat <<EOF
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
EOF'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on the class inside a multi-line double-quoted string" {
  fixture_repo
  fixture_hook 'reason="To unblock:
  1. Run the ledger writer per judged test:
       node .gaia/scripts/audit-ledger/append-worthiness.mjs <file>
  2. Retry gh pr merge."'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

@test "quiet on the class in a comment, whole-line and trailing" {
  fixture_repo
  fixture_hook '# Usage: [ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh
true  # Usage: [ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "check.sh" <<<"$output" && return 1
  true
}

# --- where the quiet arms stop, and the class reports again -----------------

@test "reports a mention inside a QUOTED span, which the # does not cut" {
  fixture_repo
  # The mention sits BEHIND the `#`, so only the quote tracker keeps it in the
  # scanned prefix: a cut at that `#` would drop it and report clean.
  fixture_hook 'msg="the shape is # [ -f .claude/hooks/lib/red-ledger.sh ]"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:3:" <<<"$output" || return 1
  grep -qF -- "a file-test operand names a bare repo-relative path" <<<"$output"
}

@test "a comment carrying an apostrophe does not blind the next line" {
  fixture_repo
  fixture_hook "# The gate own tracker must not read this apostrophe as a quote: don't.
[ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/check.sh:4:" <<<"$output"
}

# --- the discovery itself --------------------------------------------------

@test "errors rather than passing when the scan surface is short" {
  fixture_repo_bare
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "ERROR:" <<<"$output" || return 1
  grep -qF -- "fewer than the floor" <<<"$output"
}

@test "the real hook tree is clean" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER' 2>&1"
  [ "$status" -eq 0 ]
  grep -qF -- "lint-hook-cwd-relative-loads: clean" <<<"$output"
}
