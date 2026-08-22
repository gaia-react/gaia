#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/capability-oracle-lib.sh itself -- the
# lexical half that answers "what does this file reach for". The sibling suite
# check-script-capabilities.bats covers the reconciliation built on top of it;
# nothing here reads a manifest.
#
# Three subjects, in order:
#
#   1. `_gaia_capcheck_strip_tests` terminates. A logical line may carry a `]]`
#      or a `))` that closes nothing ahead of a later complete pair, and
#      splicing the tail from the first closer anywhere retains that token in
#      the head and re-appends it every pass, so the string grows and the loop
#      never ends. The red is asserted against a VENDORED copy of the pre-change
#      body, so it reproduces at any HEAD with no wall-clock race.
#
#   2. The detectors do not read prose as code. A command name inside a
#      double-quoted message, a `.` that is jq's identity filter, an operand
#      carrying a backtick, a `>` comparison inside an embedded program: each
#      is asserted absent, and each is paired with a companion asserting the
#      SAME shape in real executable code is still emitted. The companion half
#      is what keeps a suppression from blinding the oracle.
#
#   3. The resolution idioms reduce a derived target to a repo-relative path.
#      Each carries a positive fixture and a negative one where the derivation
#      is genuinely unresolvable and the site stays unresolved.
#
# Every fixture is a throwaway tree under $BATS_TEST_TMPDIR handed to the oracle
# as its <repo_root>, so no test reads this repository's own files. The fixture
# paths sit two directories deep because the own-directory hop joins `/../..`
# and a shallower tree makes that escape the root.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/capability-oracle-termination.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ORACLE="$SCRIPT_DIR/capability-oracle-lib.sh"
  PRE_CHANGE="$SCRIPT_DIR/tests/fixtures/capability-oracle/pre-change-oracle.sh"
  # shellcheck source=.gaia/scripts/capability-oracle-lib.sh
  source "$ORACLE"
  FIX="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$FIX/.claude/hooks/lib" "$FIX/.gaia/scripts"
  : >"$FIX/.gaia/scripts/main-root-lib.sh"
  : >"$FIX/.gaia/scripts/state-registry-lib.sh"
  : >"$FIX/.claude/hooks/lib/helper.sh"
}

# STATED WALL-CLOCK BOUND, in seconds, for a single _gaia_capcheck_strip_tests
# call. The post-change body returns far inside it; the vendored pre-change copy
# must exceed it on every hanging shape. It is a bound on a non-terminating
# loop, not a performance assertion, so it is deliberately loose.
STRIP_TESTS_BOUND=5

# run_bounded <seconds> <command...>: 0 if the command finished inside the
# bound, 1 if it was killed at the bound. `timeout(1)` is absent on macOS, so
# the bound is enforced by backgrounding and polling.
#
# Two details are load-bearing when the bound actually fires, and both were
# observed: the whole suite hangs without them.
#
# `3>&-` closes bats' own TAP stream in the child. A background job inherits
# every descriptor, and one killed at the bound would otherwise be reaped by
# init still holding fd 3 open, so bats never reads EOF on the stream it is
# waiting for and the run never ends -- long after the test itself passed.
#
# `pkill -P` reaps the child's own children before it is killed. Killing a
# process that has forked leaves the fork orphaned and spinning at full CPU,
# which is the same leak by another route.
run_bounded() {
  local limit="$1" i pid
  shift
  "$@" >/dev/null 2>&1 3>&- &
  pid=$!
  for ((i = 0; i < limit; i++)); do
    kill -0 "$pid" 2>/dev/null || {
      wait "$pid" 2>/dev/null
      return 0
    }
    sleep 1
  done
  pkill -9 -P "$pid" 2>/dev/null || true
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  return 1
}

# write_hook <rel>: fixture body on stdin, written under the fixture tree's
# .claude/hooks/.
write_hook() {
  cat >"$FIX/.claude/hooks/$1"
}

# sites <rel>: every capability record one fixture file reaches for on its own.
sites() {
  _gaia_capcheck_file_sites "$FIX" "$1"
}

# strip_every_line <rel>: run _gaia_capcheck_strip_tests over every logical line
# of a fixture, which is what the write scanner does. Driving it through the
# real line joiner rather than a hand-built string is the point: the hanging
# shape only exists once the backslash continuation is joined.
strip_every_line() {
  local lineno text
  # The middle field is the line's `# shellcheck source=` annotation, which
  # only the invocation resolver reads.
  while IFS=$'\t' read -r lineno _ text; do
    [ -n "$lineno" ] || continue
    _gaia_capcheck_strip_tests "$text"
  done < <(_gaia_capcheck_logical_lines "$FIX/.claude/hooks/$1")
}

# strip_every_line_pre <rel>: the same walk with the VENDORED pre-change bodies
# in force.
#
# Deliberately NOT a subshell function. It is only ever reached through
# run_bounded, which has already forked, and a subshell body would fork a second
# time; the bound then kills the outer process and leaves the inner one spinning
# with no parent. Calling it anywhere else would redefine the oracle in the
# caller's own shell, so do not.
strip_every_line_pre() {
  # shellcheck source=.gaia/scripts/tests/fixtures/capability-oracle/pre-change-oracle.sh
  source "$PRE_CHANGE"
  strip_every_line "$1"
}

# sites_pre <rel>: one fixture's records as the pre-change oracle read them.
# The class-(a) and class-(b) tests use it to prove each fixture is a real red
# rather than a shape the oracle never had an opinion about.
sites_pre() (
  # shellcheck source=.gaia/scripts/tests/fixtures/capability-oracle/pre-change-oracle.sh
  source "$PRE_CHANGE"
  _gaia_capcheck_file_sites "$FIX" "$1"
)

# The two hanging shapes, each in its own fixture.
#
# hang_continued mirrors the live instance: a backslash-continued conditional
# whose FIRST span ends `]]` and whose earlier POSIX bracket expression
# `[[:space:]]` supplies a `]]` that closes nothing.
write_hang_continued() {
  write_hook hang-continued.sh <<'EOF'
norm="$1"
if [[ "$norm" =~ git[[:space:]]+push ]] \
   && [[ "$norm" =~ (--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)) ]]; then
  mkdir -p "lib/blocked"
fi
EOF
}

# hang_bare carries no POSIX bracket expression at all, which is what proves the
# defect is a stray closer rather than a nested character class.
write_hang_bare() {
  write_hook hang-bare.sh <<'EOF'
echo ]] ; if [[ "$b" == y ]]; then
  mkdir -p "lib/bare"
fi
EOF
}

# hang_arith is the same asymmetry in the `((`/`))` arm. A `case` pattern
# matching a literal `)` spells `*\))`, which puts a stray `))` ahead of a later
# complete arithmetic span on one logical line.
write_hang_arith() {
  write_hook hang-arith.sh <<'EOF'
n=0
case "$tok" in *\)) (( n++ )) ;; esac
EOF
}

# not_the_defect is the shape explicitly ruled out: ONE bracket test whose
# regular expression contains a nested POSIX bracket expression. It terminates
# against both bodies, and a fix that made it hang would be over-broad.
write_not_the_defect() {
  write_hook not-the-defect.sh <<'EOF'
if [[ "$x" =~ ^[[:alpha:]]+$ ]]; then
  mkdir -p "lib/ok"
fi
EOF
}

# ---------------------------------------------------------------------------
# 1. Termination
# ---------------------------------------------------------------------------

@test "termination: the continued shape returns inside the stated bound" {
  write_hang_continued
  run_bounded "$STRIP_TESTS_BOUND" strip_every_line hang-continued.sh
}

@test "termination: the bare shape returns inside the stated bound" {
  write_hang_bare
  run_bounded "$STRIP_TESTS_BOUND" strip_every_line hang-bare.sh
}

@test "termination: the arithmetic shape returns inside the stated bound" {
  write_hang_arith
  run_bounded "$STRIP_TESTS_BOUND" strip_every_line hang-arith.sh
}

@test "termination: the vendored pre-change body exceeds the bound on the continued shape" {
  write_hang_continued
  run_bounded "$STRIP_TESTS_BOUND" strip_every_line_pre hang-continued.sh && return 1
  true
}

@test "termination: the vendored pre-change body exceeds the bound on the bare shape" {
  write_hang_bare
  run_bounded "$STRIP_TESTS_BOUND" strip_every_line_pre hang-bare.sh && return 1
  true
}

@test "termination: the vendored pre-change body exceeds the bound on the arithmetic shape" {
  write_hang_arith
  run_bounded "$STRIP_TESTS_BOUND" strip_every_line_pre hang-arith.sh && return 1
  true
}

@test "termination: a nested POSIX bracket expression terminates against both bodies" {
  write_not_the_defect
  run_bounded "$STRIP_TESTS_BOUND" strip_every_line not-the-defect.sh
  run_bounded "$STRIP_TESTS_BOUND" strip_every_line_pre not-the-defect.sh
}

@test "termination: the span is removed and the surrounding text survives" {
  write_hang_bare
  # Bounded first, then called for its result. A body that does not terminate
  # would hang this test forever otherwise, and a required check that hangs
  # tells a reader nothing; the bound turns it into a failure.
  run_bounded "$STRIP_TESTS_BOUND" _gaia_capcheck_strip_tests 'echo ]] ; if [[ "$b" == y ]]; then'
  _gaia_capcheck_strip_tests 'echo ]] ; if [[ "$b" == y ]]; then'
  # The conditional's contents are gone, so a `>` inside one can never read as a
  # redirect; everything outside it stays, so a real reach on the same line
  # still reaches the detectors.
  grep -qF -- '"$b" == y' <<<"$_GAIA_CAPCHECK_RET" && return 1
  grep -qF -- 'echo' <<<"$_GAIA_CAPCHECK_RET"
  grep -qF -- 'then' <<<"$_GAIA_CAPCHECK_RET"
}

@test "termination: the whole-file walk over both hanging shapes returns their real reach" {
  write_hang_continued
  write_hang_bare
  run_bounded "$STRIP_TESTS_BOUND" sites .claude/hooks/hang-continued.sh
  run sites .claude/hooks/hang-continued.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:lib/blocked' <<<"$output"
  run sites .claude/hooks/hang-bare.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:lib/bare' <<<"$output"
}

# ---------------------------------------------------------------------------
# 2. Detectors: prose is not code
# ---------------------------------------------------------------------------

@test "detectors: a command word inside a double-quoted message reaches nothing" {
  write_hook quoted-message.sh <<'EOF'
deny "BLOCKED: rm -rf of .git is forbidden."
mkdir -p "lib/out"
EOF
  run sites .claude/hooks/quoted-message.sh
  [ "$status" -eq 0 ]
  # The message's own words are not write targets.
  grep -qF -- 'fs-write:forbidden.' <<<"$output" && return 1
  grep -qF -- 'fs-write:.git' <<<"$output" && return 1
  # The real reach on the next line still is.
  grep -qF -- 'fs-write:lib/out' <<<"$output"
}

@test "detectors: the same message DID reach through the pre-change oracle" {
  write_hook quoted-message.sh <<'EOF'
deny "BLOCKED: rm -rf of .git is forbidden."
mkdir -p "lib/out"
EOF
  run sites_pre .claude/hooks/quoted-message.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:forbidden.' <<<"$output"
}

@test "detectors: an operand inside a double-quoted span is still a write target" {
  write_hook quoted-operand.sh <<'EOF'
mkdir -p "lib/kept"
EOF
  run sites .claude/hooks/quoted-operand.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:lib/kept' <<<"$output"
}

@test "detectors: a command substitution inside double quotes is still code" {
  write_hook cmdsub.sh <<'EOF'
members="$( cd "$root" && bash .claude/hooks/lib/helper.sh 2>/dev/null )"
EOF
  run sites .claude/hooks/cmdsub.sh
  [ "$status" -eq 0 ]
  # The nesting puts ` && bash ` between two quote characters. Reading that as
  # prose blinds the oracle to a live invocation, which is the failure mode the
  # command-substitution skip exists to prevent.
  grep -qF -- 'CALL	.claude/hooks/lib/helper.sh' <<<"$output"
}

@test "detectors: a bare dot after a flag is jq's identity filter, not the source builtin" {
  write_hook dot-filter.sh <<'EOF'
jq -e . "$sidecar" >/dev/null 2>&1 || return 0
EOF
  run sites .claude/hooks/dot-filter.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detectors: a bare dot in command position is still the source builtin" {
  write_hook dot-source.sh <<'EOF'
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
. "$SELF_DIR/lib/helper.sh"
[ -f "$SELF_DIR/lib/helper.sh" ] && . "$SELF_DIR/lib/helper.sh"
EOF
  run sites .claude/hooks/dot-source.sh
  [ "$status" -eq 0 ]
  # Both spellings: opening the line, and behind an `&&`.
  [ "$(grep -cF -- 'CALL	.claude/hooks/lib/helper.sh' <<<"$output")" -eq 2 ]
}

@test "detectors: the dot filter DID resolve as an invocation through the pre-change oracle" {
  write_hook dot-filter.sh <<'EOF'
jq -e . "$sidecar" >/dev/null 2>&1 || return 0
EOF
  run sites_pre .claude/hooks/dot-filter.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRESC' <<<"$output"
}

@test "detectors: an operand carrying a backtick is prose, not a path" {
  write_hook backtick.sh <<'EOF'
printf "1. Run \`bash .claude/hooks/lib/helper.sh\` from the tree above"
bash .claude/hooks/lib/helper.sh
EOF
  run sites .claude/hooks/backtick.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRESC' <<<"$output" && return 1
  # The real invocation on the next line survives.
  grep -qF -- 'CALL	.claude/hooks/lib/helper.sh' <<<"$output"
}

@test "detectors: an unquoted slashless redirect operand is a comparison, not a target" {
  write_hook jq-compare.sh <<'EOF'
elif ($n - $epoch) > $ttl then empty
printf 'x' > "$out_file"
printf 'x' > lib/out.txt
EOF
  run sites .claude/hooks/jq-compare.sh
  [ "$status" -eq 0 ]
  # The jq comparison reaches nothing.
  grep -qF -- '$ttl' <<<"$output" && return 1
  # Both real redirects still do: one quoted through a variable, one a literal
  # path. Only the shape that is neither is dropped.
  grep -qF -- 'UNRES	.claude/hooks/jq-compare.sh:2' <<<"$output"
  grep -qF -- 'fs-write:lib/out.txt' <<<"$output"
}

# ---------------------------------------------------------------------------
# 3. Resolution idioms
# ---------------------------------------------------------------------------

@test "idiom: the two-step self-append resolves to the joined directory" {
  write_hook self-append.sh <<'EOF'
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0
EOF
  run sites .claude/hooks/self-append.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'CALL	.gaia/scripts/main-root-lib.sh' <<<"$output"
  # Criterion: every idiom's output is normalized before anything compares it,
  # so the `..` the derivation traverses never survives into the target.
  grep -qF -- '..' <<<"$output" && return 1
  true
}

@test "idiom: a self-append whose suffix carries an unresolved variable stays unresolved" {
  write_hook self-append-neg.sh <<'EOF'
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/$sub"
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0
EOF
  run sites .claude/hooks/self-append-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRESC' <<<"$output"
}

@test "idiom: the own-directory hop joins the literal run following the substitution" {
  write_hook dirhop-outer.sh <<'EOF'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.gaia/scripts/state-registry-lib.sh"
EOF
  run sites .claude/hooks/dirhop-outer.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'CALL	.gaia/scripts/state-registry-lib.sh' <<<"$output"
}

@test "idiom: an own-directory hop onto a file the tree lacks stays unresolved" {
  write_hook dirhop-outer-neg.sh <<'EOF'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.gaia/scripts/absent-lib.sh"
EOF
  run sites .claude/hooks/dirhop-outer-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRESC' <<<"$output"
}

@test "idiom: a file-valued variable resolves one hop further in" {
  write_hook file-var.sh <<'EOF'
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LIB="$SELF_DIR/lib/helper.sh"
. "$LIB"
EOF
  run sites .claude/hooks/file-var.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'CALL	.claude/hooks/lib/helper.sh' <<<"$output"
}

@test "idiom: a file-valued variable naming an absent file stays unresolved" {
  write_hook file-var-neg.sh <<'EOF'
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LIB="$SELF_DIR/lib/absent.sh"
. "$LIB"
EOF
  run sites .claude/hooks/file-var-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRESC' <<<"$output"
}

@test "idiom: the main-checkout resolver reduces an anchored write to a repo-relative path" {
  write_hook main-root.sh <<'EOF'
main_root="$(gaia_resolve_main_root 2>/dev/null || true)"
mkdir -p "$main_root/.gaia/local/debt"
EOF
  run sites .claude/hooks/main-root.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:.gaia/local/debt' <<<"$output"
}

@test "idiom: a resolver outside the closed set does not reduce" {
  write_hook main-root-neg.sh <<'EOF'
main_root="$(some_other_resolver 2>/dev/null || true)"
mkdir -p "$main_root/.gaia/local/debt"
EOF
  run sites .claude/hooks/main-root-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRES	' <<<"$output"
}

@test "idiom: a git-directory derivation reduces to .git" {
  write_hook git-dir.sh <<'EOF'
git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null || true)
touch "$git_dir/FETCH_HEAD.lock"
EOF
  run sites .claude/hooks/git-dir.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:.git/FETCH_HEAD.lock' <<<"$output"
}

@test "idiom: --show-toplevel names the checkout, so a write under it is repo-relative" {
  write_hook top-level.sh <<'EOF'
top=$(git rev-parse --show-toplevel 2>/dev/null || true)
touch "$top/.gaia/local/probe.lock"
EOF
  run sites .claude/hooks/top-level.sh
  [ "$status" -eq 0 ]
  # The checkout root, not the git directory: reading it as `.git` would name a
  # path beside the repository that this write never touches.
  grep -qF -- 'fs-write:.git/' <<<"$output" && return 1
  grep -qF -- 'fs-write:.gaia/local/probe.lock' <<<"$output"
}

@test "idiom: a rev-parse flag outside the two closed sets does not reduce" {
  write_hook top-level-neg.sh <<'EOF'
top=$(git rev-parse --verify HEAD 2>/dev/null || true)
touch "$top/probe.lock"
EOF
  run sites .claude/hooks/top-level-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:probe.lock' <<<"$output" && return 1
  grep -qF -- 'UNRES	' <<<"$output"
}

@test "idiom: a write rooted at the system temp directory is the tmp term and nothing else" {
  write_hook tmpdir.sh <<'EOF'
scratch=$(mktemp "${TMPDIR:-/tmp}/probe.XXXXXX" 2>/dev/null) || scratch=""
EOF
  run sites .claude/hooks/tmpdir.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'TERM	tmp' <<<"$output"
  grep -qF -- 'fs-write' <<<"$output" && return 1
  grep -qF -- 'UNRES' <<<"$output" && return 1
  true
}

@test "idiom: an mktemp template inside the repo is still a write" {
  write_hook tmpdir-neg.sh <<'EOF'
scratch=$(mktemp "lib/probe.XXXXXX" 2>/dev/null) || scratch=""
EOF
  run sites .claude/hooks/tmpdir-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:lib/**' <<<"$output"
}

@test "idiom: the assert-non-empty operator names the same variable a bare reference does" {
  write_hook assert-op.sh <<'EOF'
main_root="$(gaia_resolve_main_root 2>/dev/null || true)"
mkdir -p "${main_root:?}/.gaia/local/telemetry"
EOF
  run sites .claude/hooks/assert-op.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:.gaia/local/telemetry' <<<"$output"
}

@test "idiom: a default-value operator carries a second value and stays unresolved" {
  write_hook assert-op-neg.sh <<'EOF'
main_root="$(gaia_resolve_main_root 2>/dev/null || true)"
mkdir -p "${main_root:-/fallback}/.gaia/local/telemetry"
EOF
  run sites .claude/hooks/assert-op-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRES	' <<<"$output"
}

@test "idiom: a literal joined inside one segment resolves through the reference in front of it" {
  write_hook same-segment.sh <<'EOF'
main_root="$(gaia_resolve_main_root 2>/dev/null || true)"
state_file="$main_root/.gaia/local/cache/probe.state"
scratch="${state_file}.tmp.$$"
printf 'x' > "$scratch"
EOF
  run sites .claude/hooks/same-segment.sh
  [ "$status" -eq 0 ]
  # The `$$` in the tail leaves the last segment non-literal, so the honest term
  # is the parent directory's glob rather than a filename nothing ever has.
  grep -qF -- 'fs-write:.gaia/local/cache/**' <<<"$output"
}

@test "idiom: a same-segment literal on an unresolvable base stays unresolved" {
  write_hook same-segment-neg.sh <<'EOF'
scratch="${unknown_base}.tmp"
printf 'x' > "$scratch"
EOF
  run sites .claude/hooks/same-segment-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRES	' <<<"$output"
}

@test "idiom: a home-anchored write is never reported as a repo-relative one" {
  write_hook home-rooted.sh <<'EOF'
home_dir="${HOME:-}"
project_dir="$home_dir/.claude/projects/probe"
mkdir -p "$project_dir/gaia"
EOF
  run sites .claude/hooks/home-rooted.sh
  [ "$status" -eq 0 ]
  # The write lands outside the checkout entirely. Reading the home directory as
  # the repo root would report it as a write into THIS repo's .claude/projects/,
  # a path the script never touches. The `~` root is what keeps the reach
  # declarable without ever spelling it as one of this repository's own paths.
  grep -qxF -- 'TERM	fs-write:.claude/projects/**	.claude/hooks/home-rooted.sh:3' <<<"$output" && return 1
  grep -qF -- 'fs-write:~/.claude/projects/probe/gaia' <<<"$output"
}

@test "idiom: a home directory the home hop cannot see stays unresolved" {
  write_hook home-rooted-neg.sh <<'EOF'
home_dir="$(getent passwd "$USER" | cut -d: -f6)"
mkdir -p "$home_dir/.claude/projects/probe"
EOF
  run sites .claude/hooks/home-rooted-neg.sh
  [ "$status" -eq 0 ]
  # The guard, not the hop, answers here: an unrecognized home derivation must
  # not fall through to the root reading and be claimed as this repository.
  grep -qF -- 'fs-write:.claude/projects' <<<"$output" && return 1
  grep -qF -- 'fs-write:~' <<<"$output" && return 1
  true
}

@test "idiom: a variable assigned a root plus a literal is not itself read as the root" {
  write_hook root-plus-literal.sh <<'EOF'
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
local_dir="$root/.gaia/local"
cache_dir="$local_dir/cache"
mkdir -p "$cache_dir"
EOF
  run sites .claude/hooks/root-plus-literal.sh
  [ "$status" -eq 0 ]
  # `cache_dir` is root + `.gaia/local/cache`, so answering `cache` would name a
  # directory at the repo root that nothing writes. A shorter, wrong path is
  # worse than the full one, because it reaches the manifest.
  grep -qxF -- 'TERM	fs-write:cache	.claude/hooks/root-plus-literal.sh:4' <<<"$output" && return 1
  grep -qF -- 'fs-write:.gaia/local/cache' <<<"$output"
}

@test "idiom: a checkout-root hop joined to a caller-named remainder is the caller's, not a path" {
  write_hook root-plus-arg.sh <<'EOF'
raw="$1"
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
target="$root/$raw"
rm -rf -- "$target"
EOF
  run sites .claude/hooks/root-plus-arg.sh
  [ "$status" -eq 0 ]
  # The hop contributes no literal prefix of its own, so joining a reference
  # onto it leaves a first segment that is not a path. `**` is the term for a
  # directory the caller designates; anything narrower would be invented.
  grep -qF -- 'fs-write:**' <<<"$output"
}

@test "idiom: the ledger resolver reduces an anchored write to a repo-relative path" {
  write_hook ledger-resolver.sh <<'EOF'
ledger="$(gaia_resolve_ledger_path "$LEDGER_OVERRIDE")"
mv "$ledger" "$ledger.bak"
EOF
  run sites .claude/hooks/ledger-resolver.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:.gaia/local/telemetry/cost.jsonl.bak' <<<"$output"
}

@test "idiom: the red-ledger resolver reduces to its keyed directory's glob" {
  write_hook red-ledger-resolver.sh <<'EOF'
ledger=$(red_ledger_path "$tree_root") || exit 0
touch "$ledger"
EOF
  run sites .claude/hooks/red-ledger-resolver.sh
  [ "$status" -eq 0 ]
  # The per-tree key segment is chosen at run time, so the honest term
  # generalizes from the literal prefix in front of it.
  grep -qF -- 'fs-write:.gaia/local/red-ledger/**' <<<"$output"
}

@test "idiom: a dirname substitution takes the directory of a target the file locates" {
  write_hook dirname-hop.sh <<'EOF'
ledger="$(gaia_resolve_ledger_path "")"
ledger_dir="$(dirname "$ledger")"
mv "$ledger_dir/tokens.jsonl" "$ledger_dir/tokens.jsonl.bak"
EOF
  run sites .claude/hooks/dirname-hop.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:.gaia/local/telemetry/tokens.jsonl.bak' <<<"$output"
}

@test "idiom: a dirname substitution over an unresolvable operand stays unresolved" {
  write_hook dirname-hop-neg.sh <<'EOF'
ledger="$(some_unknown_resolver)"
ledger_dir="$(dirname "$ledger")"
touch "$ledger_dir/tokens.jsonl.bak"
EOF
  run sites .claude/hooks/dirname-hop-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:tokens.jsonl.bak' <<<"$output" && return 1
  grep -qF -- 'UNRES	' <<<"$output"
}

@test "idiom: a cd-and-pwd substitution reads as its own operand" {
  write_hook cd-pwd.sh <<'EOF'
repo_root="$(cd "${1%/}" 2>/dev/null && pwd -P)" || exit 0
sentinel="$repo_root/.gaia/local/.swept"
touch "$sentinel"
EOF
  run sites .claude/hooks/cd-pwd.sh
  [ "$status" -eq 0 ]
  # The operand is a positional, so the caller-supplied test decides: the
  # literal remainder names a path this tree has, which is what tells a
  # checkout root from a caller-designated directory.
  grep -qF -- 'fs-write:.gaia/local/.swept' <<<"$output"
}

@test "idiom: a cd-and-pwd substitution onto a caller-named remainder stays the caller's" {
  write_hook cd-pwd-neg.sh <<'EOF'
lock_dir="$(cd "${1%/}" 2>/dev/null && pwd -P)" || exit 0
touch "$lock_dir/no-such-top-level/probe.lock"
EOF
  run sites .claude/hooks/cd-pwd-neg.sh
  [ "$status" -eq 0 ]
  # The literal remainder names nothing this tree has, so the operand is a
  # directory the caller picked rather than a checkout root.
  grep -qF -- 'fs-write:no-such-top-level' <<<"$output" && return 1
  grep -qF -- 'fs-write:**' <<<"$output"
}

@test "idiom: a variable bound by a for-loop over a glob resolves to the glob's own root" {
  write_hook loop-for.sh <<'EOF'
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
audit_dir="$root/.gaia/local/audit"
for marker in "$audit_dir"/*.ok "$audit_dir"/*.refused; do
  rm -f -- "$marker"
done
EOF
  run sites .claude/hooks/loop-for.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:.gaia/local/audit/**' <<<"$output"
}

@test "idiom: a for-loop over a command substitution binds nothing the oracle can read" {
  write_hook loop-for-neg.sh <<'EOF'
for marker in $(list_markers); do
  rm -f -- "$marker"
done
EOF
  run sites .claude/hooks/loop-for-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:.gaia' <<<"$output" && return 1
  grep -qF -- 'UNRES	' <<<"$output"
}

@test "idiom: a variable bound by a find piped into read resolves to the find root's glob" {
  write_hook loop-read.sh <<'EOF'
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cache_dir="$root/.gaia/local/cache"
find "$cache_dir" -maxdepth 2 -name 'renders.json' -print 2>/dev/null | \
  while IFS= read -r hit; do
    rm -rf -- "$(dirname "$hit")"
  done
EOF
  run sites .claude/hooks/loop-read.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:.gaia/local/cache/**' <<<"$output"
}

@test "idiom: a read loop fed by anything but a find binds nothing the oracle can read" {
  write_hook loop-read-neg.sh <<'EOF'
jq -r '.paths[]' manifest.json | \
  while IFS= read -r hit; do
    rm -rf -- "$hit"
  done
EOF
  run sites .claude/hooks/loop-read-neg.sh
  [ "$status" -eq 0 ]
  grep -qF -- 'UNRES	' <<<"$output"
}

@test "idiom: a caller-supplied root the oracle cannot parse still reduces to its literal remainder" {
  write_hook caller-root.sh <<'EOF'
repo_root="${args[0]%/}"
local_cache="${repo_root}/.gaia/local/cache"
touch "${local_cache}/gate1-probe.json"
EOF
  run sites .claude/hooks/caller-root.sh
  [ "$status" -eq 0 ]
  # The value pins nothing about what the variable is NOT, so the root reduction
  # holds and the literal remainder is the repo-relative answer.
  grep -qF -- 'fs-write:.gaia/local/cache/gate1-probe.json' <<<"$output"
}

@test "idiom: a mutually sourcing pair terminates, visiting each file once" {
  write_hook cycle-a.sh <<'EOF'
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
. "$SELF_DIR/cycle-b.sh"
mkdir -p "lib/a"
EOF
  write_hook cycle-b.sh <<'EOF'
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
. "$SELF_DIR/cycle-a.sh"
mkdir -p "lib/b"
EOF
  run_bounded "$STRIP_TESTS_BOUND" _gaia_capcheck_closure "$FIX" .claude/hooks/cycle-a.sh ""
  run _gaia_capcheck_closure "$FIX" .claude/hooks/cycle-a.sh ""
  [ "$status" -eq 0 ]
  grep -qF -- 'fs-write:lib/a' <<<"$output"
  grep -qF -- 'fs-write:lib/b' <<<"$output"
  # Each file is entered at most once, so neither write is reported twice.
  [ "$(grep -cF -- 'fs-write:lib/a' <<<"$output")" -eq 1 ]
  [ "$(grep -cF -- 'fs-write:lib/b' <<<"$output")" -eq 1 ]
}

# ========== The bash-version backstop ==========
#
# Lexical, not behavioural: the runners are bash 5, so there is no bash 3.2 to
# drive the refusal on. Under 3.2 the scan loop ends early inside a file and
# under-reports reach, which is the direction that cannot surface as a finding,
# so each executable entry point re-execs under a bash 5 and this library
# refuses outright for any consumer that sources it without a guard of its own.
# That refusal is the only structural defence a future consumer inherits, and
# deleting it leaves every other test in the tree green, so it is pinned here.

@test "backstop: the oracle refuses to be sourced under a bash older than 5" {
  grep -qE -- '^if \[ "\$\{BASH_VERSINFO\[0\]\}" -lt 5 \]; then' "$ORACLE"
  grep -qE -- '^  exit 2$' "$ORACLE"
}

@test "backstop: both executable entry points guard themselves before sourcing the oracle" {
  local check guard_line source_line
  for check in check-script-capabilities.sh check-hook-capabilities.sh; do
    grep -qE -- '\$\{BASH_VERSINFO\[0\]\}" -lt 5' "$SCRIPT_DIR/$check" || return 1
    grep -qF -- 'exec "$_gaia' "$SCRIPT_DIR/$check" || return 1
    # The guard has to run BEFORE the source, or the library's own refusal
    # fires first and the entry point never gets to re-exec.
    guard_line="$(grep -nE -- '\$\{BASH_VERSINFO\[0\]\}" -lt 5' "$SCRIPT_DIR/$check" | head -1 | cut -d: -f1)"
    source_line="$(grep -nF -- '. "$_gaia' "$SCRIPT_DIR/$check" | head -1 | cut -d: -f1)"
    [ -n "$guard_line" ] || return 1
    [ -n "$source_line" ] || return 1
    [ "$guard_line" -lt "$source_line" ] || return 1
  done
  true
}
