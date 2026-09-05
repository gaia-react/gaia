#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/main-only-lib.sh (task 5.3): the shared
# main-only-flow refusal helper the classified flows source instead of each
# carrying its own copy-pasted detection. CALL_SITE_FILES below is the roster.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/main-only-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# Fixture idiom matched from main-root-lib.bats (make_repo / make_worktree,
# canonicalized via `pwd -P` since macOS resolves /tmp -> /private/tmp inside
# `git rev-parse` and outputs are compared byte-for-byte) and link-worktree.bats
# (a run_in helper that cds into a tree and runs a script).

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/main-only-lib.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLEANUP_DIRS=()
}

teardown() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

git_identity() {
  git -C "$1" config user.email gaia-test@example.com
  git -C "$1" config user.name "GAIA Test"
  git -C "$1" config commit.gpgsign false
}

# make_repo: an ordinary clone. Sets REPO.
make_repo() {
  local raw
  raw=$(mktemp -d -t gaia-mol-repo-XXXXXX)
  REPO="$(cd "$raw" && pwd -P)"
  CLEANUP_DIRS+=("$REPO")
  git -C "$REPO" init -q --initial-branch=main
  git_identity "$REPO"
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
}

# make_worktree <repo> <rel> <branch>: a real linked worktree under
# <repo>/.claude/worktrees/<rel>, mirroring how GAIA creates plan/debt
# worktrees. Sets WT to the worktree's absolute path.
make_worktree() {
  local repo="$1" rel="$2" br="$3"
  git -C "$repo" branch "$br"
  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/$rel" "$br"
  WT="$repo/.claude/worktrees/$rel"
}

# run_in <dir> -- <bash args...>: runs a command with cwd=<dir>.
run_in() {
  local dir="$1"
  shift
  [ "$1" = "--" ] && shift
  ( cd "$dir" && "$@" )
}

# ---------- not a linked worktree ----------

@test "not a linked worktree: returns 0 and prints nothing" {
  make_repo
  run run_in "$REPO" -- bash -c '. "$1"; gaia_refuse_if_worktree "/x"' _ "$LIB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- linked worktree, resolvable main ----------

@test "linked worktree with resolvable main: returns 1, message names both roots, no state_line_fn given" {
  make_repo
  make_worktree "$REPO" w wtbranch1
  run run_in "$WT" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release"' _ "$LIB"
  [ "$status" -eq 1 ]
  grep -qF -- "/gaia-release must run from the main checkout, not a worktree." <<<"$output" || return 1
  grep -qF -- "Worktree:       $WT" <<<"$output" || return 1
  grep -qF -- "Main checkout:  $REPO" <<<"$output" || return 1
  grep -qF -- "Run \`cd $REPO\` then re-invoke /gaia-release." <<<"$output" || return 1
}

@test "linked worktree, no state_line_fn supplied: no state paragraph at all" {
  make_repo
  make_worktree "$REPO" w wtbranch2
  run run_in "$WT" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release" 2>/dev/null' _ "$LIB"
  [ "$status" -eq 1 ]
  # Byte-exact: no state paragraph, and exactly one blank line separates the
  # roots block from the "Run \`cd\`" line -- not $lines-based, bats' $lines
  # splitting silently drops blank-line entries so it can't prove this.
  local expected
  expected="/gaia-release must run from the main checkout, not a worktree.

Worktree:       $WT
Main checkout:  $REPO

Run \`cd $REPO\` then re-invoke /gaia-release."
  [ "$output" = "$expected" ]
}

@test "linked worktree, state_line_fn prints a line: that line is in the message" {
  make_repo
  make_worktree "$REPO" w wtbranch3
  run run_in "$WT" -- bash -c '
. "$1"
my_state() { printf "Cached on main: GAIA 1.2.3 installed; latest 1.2.3 (update not-available).\n"; }
gaia_refuse_if_worktree "/update-gaia" my_state
' _ "$LIB"
  [ "$status" -eq 1 ]
  grep -qF -- "Cached on main: GAIA 1.2.3 installed; latest 1.2.3 (update not-available)." <<<"$output" || return 1
  # Per .claude/rules/bats-assertions.md: a `<positive> && return 1` absence
  # check is only safe on a non-final line -- as the test's LAST line its own
  # (good-case) exit status of 1 would fail the test. The explicit `return 0`
  # makes the success path's exit status deterministic.
  grep -qF -- "Cached state unavailable" <<<"$output" && return 1
  return 0
}

@test "linked worktree, state_line_fn supplied but prints nothing: shared fallback line is used" {
  make_repo
  make_worktree "$REPO" w wtbranch4
  run run_in "$WT" -- bash -c '
. "$1"
my_state() { :; }
gaia_refuse_if_worktree "/update-deps" my_state
' _ "$LIB"
  [ "$status" -eq 1 ]
  grep -qF -- 'Cached state unavailable on main; symlinks may be broken, run `.gaia/cli/gaia setup link-worktree` to repair.' <<<"$output" || return 1
}

@test "linked worktree, state_line_fn's own cache_file argument is main's cache path, not the worktree's" {
  make_repo
  make_worktree "$REPO" w wtbranch5
  local captured="$BATS_TEST_TMPDIR/cache_file_arg"
  run run_in "$WT" -- bash -c '
. "$1"
captured_path="$2"
my_state() { printf "%s" "$1" > "$captured_path"; }
gaia_refuse_if_worktree "/update-gaia" my_state
' _ "$LIB" "$captured"
  [ "$status" -eq 1 ]
  [ "$(cat "$captured")" = "$REPO/.gaia/local/cache/shared/update-check.json" ]
}

# ---------- unresolvable main (fail-open) ----------

@test "linked worktree, unresolvable main: fails open, returns 0, prints nothing" {
  make_repo
  make_worktree "$REPO" w wtbranch6
  local common_config
  common_config="$(cd "$REPO/.git" && pwd -P)/config"
  git config --file "$common_config" core.worktree "/nonexistent/evil/path"
  # bats' `run` merges stdout+stderr by default, and the resolver's own
  # contract (main-root-lib.sh) writes one diagnostic line to STDERR on this
  # exact failure -- expected, and not this helper's stdout contract. Discard
  # it here (matching main-root-lib.bats' `resolve()` helper) so $output
  # reflects gaia_refuse_if_worktree's own stdout only.
  run run_in "$WT" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release" 2>/dev/null' _ "$LIB"
  git config --file "$common_config" --unset core.worktree || true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- structural ----------

@test "structural: main-only-lib.sh is executable" {
  [ -x "$LIB" ]
}

@test "structural: sourcing the library defines gaia_refuse_if_worktree and the resolver functions, with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_refuse_if_worktree >/dev/null
    type gaia_resolve_main_root >/dev/null
    type gaia_is_linked_worktree >/dev/null
    type gaia_resolve_tree_root >/dev/null
    echo OK
  ' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- as the call sites actually invoke it ----------
#
# Every test above sources $LIB by ABSOLUTE path under bash. The call sites
# do neither: they are markdown blocks an agent runs through its shell
# tool, so the sourcing shell is that machine's login shell (zsh on a stock
# Mac, not bash as a settings.json-registered hook gets), and the line they run
# is the repo-relative `. .gaia/scripts/main-only-lib.sh` from a checkout root.
#
# Both halves of that matter, and each hid the other. Under zsh BASH_SOURCE is
# unset and `declare -F` declares a float and succeeds, so the sibling resolver
# was never sourced and every refusal returned 0 -- the flow continuing, from a
# worktree, with no refusal printed. And under `zsh -c` a relative `.` drops
# the directory from $0, so a test that sources by absolute path greens while
# the real relative-path call stays dead.
#
# install_libs copies both libraries into the fixture at the same repo-relative
# path a real checkout has them, and commits them before the worktree is cut so
# both trees carry them.
install_libs() {
  local repo="$1" src
  src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$repo/.gaia/scripts"
  cp "$src/main-only-lib.sh" "$src/main-root-lib.sh" "$repo/.gaia/scripts/"
  git -C "$repo" add .gaia/scripts
  git -C "$repo" commit -q -m "libs"
}

@test "as invoked: relative source from a worktree root refuses out loud, under zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_repo
  install_libs "$REPO"
  make_worktree "$REPO" w wtbranchzsh1
  run run_in "$WT" -- zsh -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/gaia-release"'
  [ "$status" -eq 1 ]
  grep -qF -- "/gaia-release must run from the main checkout, not a worktree." <<<"$output" || return 1
  grep -qF -- "Main checkout:  $REPO" <<<"$output" || return 1
  # The failure this test exists for was near-silent: no refusal, and a stray
  # shell error in its place.
  grep -qF -- "command not found" <<<"$output" && return 1
  return 0
}

@test "as invoked: relative source from a worktree root refuses out loud, under bash" {
  make_repo
  install_libs "$REPO"
  make_worktree "$REPO" w wtbranchrel1
  run run_in "$WT" -- bash -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/gaia-release"'
  [ "$status" -eq 1 ]
  grep -qF -- "/gaia-release must run from the main checkout, not a worktree." <<<"$output" || return 1
}

@test "as invoked: relative source from the main checkout returns 0 and prints nothing, under zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_repo
  install_libs "$REPO"
  run run_in "$REPO" -- zsh -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/gaia-release"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "structural: sourcing main-root-lib.sh first, then this file, does not error (guarded re-source)" {
  local mrl
  mrl="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/main-root-lib.sh"
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    # shellcheck disable=SC1090
    source "$2"
    type gaia_refuse_if_worktree >/dev/null
    echo OK
  ' _ "$mrl" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- the call-site meter ----------
#
# main-only-lib.sh's own header (:65-102) records the Milestone 5 false
# green: the refusal is shell an agent runs through its shell tool, zsh on a
# stock Mac, not the bash a settings-registered hook gets, and for most of
# that milestone the refusal was dead under zsh while a bash-only meter read
# green. This section is what keeps the hardening honest as the call-site
# count grows. It tests the block AS WRITTEN in each file, under the shell
# the call site really uses, from a REAL linked worktree, not a copy
# hand-transcribed into this suite.
#
# Classification of which flows carry the refusal and which do not lives in
# .gaia/local/plans/worktree-program-next/RUNBOOK.md, which is machine-local
# and gitignored; this test cannot read it, so the two lists below are
# hardcoded here instead, with this comment naming where the classification
# itself lives.

# The classified flows that carry the refusal, and each one's flow-name
# literal at the same array index. Order matches the RUNBOOK.md
# classification's own ordering, not alphabetical.
CALL_SITE_FILES=(
  ".claude/commands/gaia-audit.md"
  ".claude/commands/gaia-debt.md"
  ".claude/commands/gaia-fitness.md"
  ".claude/commands/gaia-harden.md"
  ".claude/commands/gaia-release.md"
  ".claude/commands/gaia-serena-sync.md"
  ".claude/commands/health-audit.md"
  ".claude/commands/setup-gaia.md"
  ".claude/skills/gaia-wiki/SKILL.md"
  ".claude/skills/gaia-react-perf/SKILL.md"
  ".claude/skills/release-notes/SKILL.md"
  ".claude/skills/update-deps/SKILL.md"
  ".claude/skills/update-gaia/SKILL.md"
)
CALL_SITE_FLOW_NAMES=(
  "/gaia-audit"
  "/gaia-debt"
  "/gaia-fitness"
  "/gaia-harden"
  "/gaia-release"
  "/gaia-serena-sync"
  "/health-audit"
  "/setup-gaia"
  "/gaia-wiki"
  "/gaia-react-perf"
  "/release-notes"
  "/update-deps"
  "/update-gaia"
)

# The flows that must never carry the refusal: each provisions or drives
# its own worktree mid-flow (gaia-plan, gaia-debt's fix path) or must stay
# reachable from inside one (gaia-spec, gaia-forensics, gaia-handoff,
# gaia-pickup, file-tech-debt). This half is what catches a future drive-by
# adding the refusal to one of these, e.g. onto /gaia-plan, which would break
# plan execution the moment the flow enters the worktree it just created.
#
# distribution-audit joins them on a different warrant, and one worth stating
# because the refusal did sit on it. What decides it is what the flow writes:
# /distribution-audit writes `.gaia/manifest.json` and `.gaia/release-exclude`,
# git-tracked branch-scoped files a linked worktree isolates correctly, and it
# writes nothing under `.gaia/local`, so a worktree run collides with no shared
# state. Meanwhile the `gh pr create` distribution pre-flight demands that
# answer land on the worktree's own branch, which the main checkout cannot
# supply, so a refusal here made the hook's own remediation unfollowable. The
# release path's main-only property is enforced at /gaia-release's own call
# site above, not here.
#
# Deliberately not resting that on main-only-lib.sh's docblock, which reads as
# the criterion and is not one: three flows above (/gaia-serena-sync,
# /gaia-react-perf, /gaia-fitness) carry the refusal while matching none of the
# limbs it names. CALL_SITE_FILES is the roster; the docblock records the
# original motivating case.
NO_CALL_SITE_FILES=(
  ".claude/commands/distribution-audit.md"
  ".claude/commands/gaia-plan.md"
  ".claude/commands/gaia-spec.md"
  ".claude/commands/gaia-forensics.md"
  ".claude/skills/gaia-handoff/SKILL.md"
  ".claude/skills/gaia-pickup/SKILL.md"
  ".claude/skills/file-tech-debt/SKILL.md"
)

# Seven of the call-site roster are thin dispatchers: a "Read `.claude/..." line
# sends the agent to a reference file, and a refusal call placed BELOW that
# line greps as present but never runs, because the agent follows the
# reference instead of reading the rest of the file. This is the frozen set
# FC-2 names; the placement test below derives its own split at runtime
# rather than trusting this list, and fails when the two disagree.
EXPECTED_DISPATCHER_FILES=(
  ".claude/commands/gaia-audit.md"
  ".claude/commands/gaia-debt.md"
  ".claude/commands/gaia-fitness.md"
  ".claude/commands/gaia-harden.md"
  ".claude/commands/gaia-serena-sync.md"
  ".claude/skills/gaia-wiki/SKILL.md"
  ".claude/skills/gaia-react-perf/SKILL.md"
)

# extract_block <file>: pulls the fenced code block (```...```) that
# contains the gaia_refuse_if_worktree invocation, verbatim, exclusive of
# the fences. An awk state machine over the file rather than a
# hand-maintained copy of each block, because a hand-maintained copy is
# exactly the thing that drifts from the file it claims to test.
extract_block() {
  awk '
    /^```/ {
      if (in_block) {
        if (found) { printf "%s", buf; exit }
        in_block = 0; buf = ""; found = 0
      } else {
        in_block = 1; buf = ""
      }
      next
    }
    in_block {
      buf = buf $0 "\n"
      if ($0 ~ /gaia_refuse_if_worktree "/) found = 1
    }
  ' "$1"
}

# ---------- roster census ----------

@test "call-site roster: every classified flow carries exactly one line-anchored invocation" {
  local f count
  for f in "${CALL_SITE_FILES[@]}"; do
    count=$(grep -c '^[[:space:]]*gaia_refuse_if_worktree "' "$REPO_ROOT/$f" || true)
    [ "$count" -eq 1 ] || { echo "expected exactly one gaia_refuse_if_worktree invocation in $f, found $count" >&2; return 1; }
  done
}

@test "call-site roster: the worktree-callable flows carry none" {
  local f count
  for f in "${NO_CALL_SITE_FILES[@]}"; do
    count=$(grep -c '^[[:space:]]*gaia_refuse_if_worktree "' "$REPO_ROOT/$f" || true)
    [ "$count" -eq 0 ] || { echo "expected no gaia_refuse_if_worktree invocation in $f, found $count" >&2; return 1; }
  done
}

# ---------- placement ----------

@test "call-site placement: the invocation precedes the file's own dispatch line, in every thin dispatcher" {
  local f dispatch_line invoke_line measured=() sorted_measured sorted_expected
  for f in "${CALL_SITE_FILES[@]}"; do
    dispatch_line=$(grep -n 'Read `\.claude/' "$REPO_ROOT/$f" | head -1 | cut -d: -f1)
    [ -n "$dispatch_line" ] || continue # exempt: no dispatch line to sit ahead of
    measured+=("$f")
    invoke_line=$(grep -n '^[[:space:]]*gaia_refuse_if_worktree "' "$REPO_ROOT/$f" | head -1 | cut -d: -f1)
    [ "$invoke_line" -lt "$dispatch_line" ] || { echo "$f: invocation at line $invoke_line does not precede dispatch line $dispatch_line" >&2; return 1; }
  done
  # Report and enforce the measured split against FC-2's frozen seven: a
  # difference is a finding, not something to accommodate.
  sorted_measured="$(printf '%s\n' "${measured[@]}" | sort)"
  sorted_expected="$(printf '%s\n' "${EXPECTED_DISPATCHER_FILES[@]}" | sort)"
  echo "measured dispatchers (${#measured[@]}): $sorted_measured" >&2
  [ "$sorted_measured" = "$sorted_expected" ] || { echo "dispatcher split drifted from FC-2's seven; measured vs expected above" >&2; return 1; }
}

# ---------- per-call-site execution, under the shell the call site really uses ----------

@test "call-site execution: every extracted block refuses correctly under bash, from a real linked worktree" {
  make_repo
  install_libs "$REPO"
  make_worktree "$REPO" mol-bash mol-bash-branch
  local i=0 f flow block
  for f in "${CALL_SITE_FILES[@]}"; do
    flow="${CALL_SITE_FLOW_NAMES[$i]}"
    i=$((i + 1))
    block="$(extract_block "$REPO_ROOT/$f")"
    [ -n "$block" ] || { echo "$f: extractor found no fenced block containing the invocation" >&2; return 1; }
    run run_in "$WT" -- bash -c "$block"
    [ "$status" -eq 1 ] || { echo "$f (bash): expected exit 1, got $status; output: $output" >&2; return 1; }
    grep -qF -- "$flow must run from the main checkout, not a worktree." <<<"$output" || { echo "$f (bash): missing refusal line" >&2; return 1; }
    grep -qF -- "Main checkout:  $REPO" <<<"$output" || { echo "$f (bash): missing main checkout line" >&2; return 1; }
    grep -qF -- "Run \`cd $REPO\` then re-invoke $flow." <<<"$output" || { echo "$f (bash): missing re-invoke line" >&2; return 1; }
    # The Milestone 5 failure was near-silent: no refusal, and a stray shell
    # error in its place.
    grep -qF -- "command not found" <<<"$output" && { echo "$f (bash): stray shell error in output" >&2; return 1; }
  done
  # Explicit and deterministic: without this, the loop's own exit status is
  # the LAST command's, and the good case of the final `&&`-guarded absence
  # check above exits 1 (grep found no match), which would otherwise leak
  # through as this function's own return status.
  return 0
}

@test "call-site execution: every extracted block refuses correctly under zsh, from a real linked worktree" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_repo
  install_libs "$REPO"
  make_worktree "$REPO" mol-zsh mol-zsh-branch
  local i=0 f flow block
  for f in "${CALL_SITE_FILES[@]}"; do
    flow="${CALL_SITE_FLOW_NAMES[$i]}"
    i=$((i + 1))
    block="$(extract_block "$REPO_ROOT/$f")"
    [ -n "$block" ] || { echo "$f: extractor found no fenced block containing the invocation" >&2; return 1; }
    run run_in "$WT" -- zsh -c "$block"
    [ "$status" -eq 1 ] || { echo "$f (zsh): expected exit 1, got $status; output: $output" >&2; return 1; }
    grep -qF -- "$flow must run from the main checkout, not a worktree." <<<"$output" || { echo "$f (zsh): missing refusal line" >&2; return 1; }
    grep -qF -- "Main checkout:  $REPO" <<<"$output" || { echo "$f (zsh): missing main checkout line" >&2; return 1; }
    grep -qF -- "Run \`cd $REPO\` then re-invoke $flow." <<<"$output" || { echo "$f (zsh): missing re-invoke line" >&2; return 1; }
    # Under zsh, BASH_SOURCE is unset and `declare -F` declares a float and
    # succeeds instead of answering whether a function exists; that hazard
    # is exactly what a "command not found" in the output would reveal.
    grep -qF -- "command not found" <<<"$output" && { echo "$f (zsh): stray shell error in output" >&2; return 1; }
  done
  # See the bash test above: without this, the loop's own exit status is the
  # last iteration's last command, whose good case exits 1.
  return 0
}

@test "call-site execution: extracted blocks are silent no-ops from the main checkout" {
  make_repo
  install_libs "$REPO"
  local f block
  # One file with no state_line_fn, one with: both idiom shapes get the
  # mirror-case proof, not just the no-arg one.
  for f in ".claude/commands/gaia-release.md" ".claude/skills/update-deps/SKILL.md"; do
    block="$(extract_block "$REPO_ROOT/$f")"
    run run_in "$REPO" -- bash -c "$block"
    [ "$status" -eq 0 ] || { echo "$f: expected exit 0 from the main checkout, got $status; output: $output" >&2; return 1; }
    [ -z "$output" ] || { echo "$f: expected empty output from the main checkout, got: $output" >&2; return 1; }
  done
}

# ---------- the /setup-gaia composition ----------

@test "setup-gaia composition: the refusal half names cd back to main" {
  # /setup-gaia is main-only AND the one statusline nudge that still renders
  # outside main: the nudge tells a worktree session setup is owed, the
  # refusal tells it where to go. The rendering half is asserted in
  # .gaia/tests/statusline/statusline-worktree.bats, in the test named
  # "an incomplete setup is reported from a worktree too". This suite has no
  # statusline fixture, so only the refusal half's composing sentence is
  # asserted here; duplicating the render assertion would be a second copy
  # of a suite that already exists.
  make_repo
  install_libs "$REPO"
  make_worktree "$REPO" mol-setup mol-setup-branch
  local block
  block="$(extract_block "$REPO_ROOT/.claude/commands/setup-gaia.md")"
  run run_in "$WT" -- bash -c "$block"
  [ "$status" -eq 1 ]
  grep -qF -- "Run \`cd $REPO\` then re-invoke /setup-gaia." <<<"$output"
}
