#!/usr/bin/env bats

# Tests for .github/audit/write-audit-status.sh, the single GAIA-Audit commit
# status writer the five terminal paths in code-review-audit.yml route through
# (#1286).
#
# SCOPE, STATED SO NOBODY ADDS A SECOND COPY OF THE SANDBOX HARNESS HERE. This
# suite owns the writer's ARGUMENT CONTRACT and its pre-git guard: the surface
# that decides whether an invocation is well-formed at all. It deliberately owns
# nothing else, because .github/audit/tests/ci-status-member-gate.bats already
# executes this writer through every one of its five real call sites, against a
# git sandbox and a `gh` mock, with the member gate and the non-clobber read
# wired up for real. Duplicating that fixture to re-assert the same outcomes
# would be two instruments measuring one population and drifting apart.
#
# So: what a MALFORMED call does lives here. What a well-formed call does lives
# there. The split is by question, not by file size.
#
# Why the argument contract earns a suite of its own: it is the only part of
# this script no call site can reach. The callers all pass well-formed
# arguments by construction, so every refusal below is unreachable from the
# workflow and would otherwise ship untested. Each refusal exits 2 rather than
# 0, which is the fail-closed answer -- an ill-formed invocation is a bug in the
# workflow, and failing the step leaves the required GAIA-Audit context absent,
# which blocks the merge exactly as a `pending` would.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WRITER="$REPO_ROOT/.github/audit/write-audit-status.sh"
  [ -f "$WRITER" ] || skip "write-audit-status.sh not found"

  # Somewhere harmless to run from. Nothing below should reach a git command,
  # a `gh` call, or the filesystem at all -- the argument contract is decided
  # before any of that -- and running outside a repo is what proves it.
  WORKDIR="$BATS_TEST_TMPDIR/elsewhere"
  mkdir -p "$WORKDIR"

  # `gh` neutralized. If a refusal path ever grew a POST, it fails loudly here
  # rather than silently succeeding against a mock.
  #
  # A stub, not an empty directory: prepending an empty dir shadows nothing, so
  # a real `gh` further down PATH would still resolve, and on a runner (where
  # `gh` is preinstalled and GITHUB_REPOSITORY is set) that would make this
  # suite issue a REAL commit-status write instead of failing.
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "write-audit-status.bats: gh must never be reached from this suite" >&2' \
    'exit 127' > "$GH_BIN/gh"
  chmod +x "$GH_BIN/gh"
  PATH="$GH_BIN:$PATH"
  export PATH
}

run_writer() {
  ( cd "$WORKDIR" && bash "$WRITER" "$@" )
}

# -----------------------------------------------------------------------------
# Exactly one mode, always
# -----------------------------------------------------------------------------

@test "no arguments at all is refused, not treated as a default" {
  run run_writer
  [ "$status" -eq 2 ]
  grep -qF "exactly one of --base / --force-pending" <<<"$output"
}

@test "a sha with no mode is refused" {
  # The dangerous reading of a missing mode would be "no members pending,
  # therefore success". Refuse instead.
  run run_writer --sha deadbeef
  [ "$status" -eq 2 ]
  grep -qF "exactly one of --base / --force-pending" <<<"$output"
}

@test "both modes at once is refused rather than one silently winning" {
  run run_writer --sha deadbeef --base cafebabe --force-pending "local mode"
  [ "$status" -eq 2 ]
  grep -qF "exactly one of --base / --force-pending" <<<"$output"
}

@test "an EMPTY --force-pending is refused, because it would fall through to success" {
  # This is the one refusal with a live failure mode behind it rather than a
  # tidiness argument. --force-pending carries the pending description AND is
  # what makes the writer treat the path as pending at all, so an empty one --
  # a caller's unset variable -- would leave nothing pending, drop through to
  # the version guard, and STAMP THE GATE GREEN on a path whose whole purpose is
  # to hold it shut.
  run run_writer --sha deadbeef --force-pending ""
  [ "$status" -eq 2 ]
  grep -qF "requires a non-empty description" <<<"$output"
}

@test "a success-path modifier is refused in stand-down mode, not ignored" {
  # The modifier qualifies the success path and stand-down mode has none, so the
  # combination is meaningless. Refusing it keeps the flag space honest -- each
  # combination the parser accepts is one a caller actually uses -- and it
  # applies the same fail-closed reasoning the unrecognized-argument branch
  # already uses: this script decides whether a merge gate opens, so a
  # well-spelled nonsense combination should stop as surely as a typo does.
  run run_writer --sha deadbeef --force-pending "local mode" --require-marker
  [ "$status" -eq 2 ]
  grep -qF "meaningless with --force-pending" <<<"$output"

  # ...and it stays legal in the mode that has a success path.
  run run_writer --sha "" --base cafebabe --require-marker
  [ "$status" -eq 0 ]
}

@test "the retired non-fatality flag is refused, not silently accepted" {
  # #1296 settled POST fatality for every writer and removed the flag that
  # carried the divergence. A caller still passing it is running against an
  # understanding of this script that no longer holds, so the
  # unrecognized-argument branch must catch it rather than let it read as a
  # request the script honors. This is the fail-closed direction and the loud
  # one: the step fails immediately with the flag named, which is a one-line
  # repair, versus silently proceeding under a contract the caller misread.
  run run_writer --sha deadbeef --base cafebabe --success-post-non-fatal
  [ "$status" -eq 2 ]
  grep -qF "unrecognized argument" <<<"$output"
}

# -----------------------------------------------------------------------------
# Malformed arguments stop; they never become a different decision
# -----------------------------------------------------------------------------

@test "an unrecognized argument stops rather than being ignored" {
  # gate-pending-members.sh fails OPEN on a bad argument, and that is right for
  # a script whose answer is advisory. This one decides whether a merge gate
  # opens, so it fails CLOSED: a typo'd flag must not silently become a
  # different decision.
  run run_writer --sha deadbeef --base cafebabe --require-marker-typo
  [ "$status" -eq 2 ]
  grep -qF "unrecognized argument" <<<"$output"
}

@test "a flag missing its value is refused BY THE PARSER, not by a later guard" {
  # ASSERTING exit 2 ALONE IS NOT ENOUGH HERE, and writing it that way first is
  # how this test was caught being hollow. Every malformed call in this file
  # exits 2, so a parser that accepted `--sha` with no value would bind an empty
  # sha, fall through, and be refused a few lines later by the mode check --
  # exit 2 either way, green either way, and the reported problem would be the
  # wrong one. Mutation-proved: relaxing the `--sha` value check left the
  # status-only version of this test passing.
  #
  # So assert WHICH refusal fired. The parser prints usage and nothing else; the
  # later guards each print their own sentence.
  run run_writer --sha
  [ "$status" -eq 2 ]
  grep -qF "usage: write-audit-status.sh" <<<"$output"
  grep -qF "exactly one of" <<<"$output" && return 1

  run run_writer --sha deadbeef --base
  [ "$status" -eq 2 ]
  grep -qF "usage: write-audit-status.sh" <<<"$output"
  grep -qF "exactly one of" <<<"$output" && return 1

  run run_writer --sha deadbeef --force-pending
  [ "$status" -eq 2 ]
  grep -qF "usage: write-audit-status.sh" <<<"$output"
  # The empty-description guard must not be what catches this one either.
  grep -qF "requires a non-empty description" <<<"$output" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# The empty target sha: a skip, not a refusal
# -----------------------------------------------------------------------------

@test "an empty --sha skips quietly with exit 0, in EITHER mode" {
  # Distinct from every case above: an empty sha is an expected runtime state,
  # not a malformed call. Only the self-heal push path can produce one (its sha
  # comes from steps.push-fixes.outputs.audit_sha, unset when push-fixes
  # resolved none), and the workflow's answer there has always been to log and
  # move on rather than red the job. Exit 0, and nothing stamped.
  run run_writer --sha "" --base cafebabe
  [ "$status" -eq 0 ]
  grep -qF "no audit_sha to stamp" <<<"$output"

  run run_writer --sha "" --force-pending "local mode"
  [ "$status" -eq 0 ]
  grep -qF "no audit_sha to stamp" <<<"$output"
}

@test "the empty-sha skip happens before any git or gh work" {
  # Proven by there being no repo here and no `gh` on PATH: if the guard ran
  # late, the script would die on `git rev-parse` or `gh` long before printing
  # this, and the exit would not be 0.
  run run_writer --sha "" --base cafebabe
  [ "$status" -eq 0 ]
  grep -qF "no audit_sha to stamp" <<<"$output"
  # Nothing downstream ran: no digest complaint, no gate output, no POST error.
  grep -qF "frontend digest" <<<"$output" && return 1
  grep -qF "gate-pending-members" <<<"$output" && return 1
  return 0
}
