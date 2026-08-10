#!/usr/bin/env bats
# Tests for .github/audit/cra-status-upsert.sh, the single-comment upsert helper
# every terminal status step in .github/workflows/code-review-audit.yml invokes.
#
# The script is fail-soft by design: the status comment is advisory and the merge
# gate is the `GAIA-Audit` commit status, so a comment failure must never red the
# job. That design makes its failure modes SILENT -- a regression degrades to
# "the comment stops updating" while CI stays green. These tests cover the two
# fail-soft branches specifically, since nothing else would catch a break there.
#
# `gh` is stubbed on PATH so no test touches the network. Each stub logs its
# invocation so the test can assert which API call the script chose.
#
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` and
# explicit `return 1`, so a false assertion fails on bash 3.2 too.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.github/audit/cra-status-upsert.sh"
  [ -f "$SCRIPT" ] || skip "cra-status-upsert.sh absent"

  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  mkdir -p "$STUB_DIR"
  : > "$GH_LOG"

  export GITHUB_REPOSITORY="owner/repo"
  export GH_LOG
}

# stub_gh <lookup-behavior> <write-behavior>
#   lookup-behavior: an id to return, "empty" for no match, or "fail" to exit 1.
#   write-behavior:  "ok" or "fail" for both the PATCH and the create path.
stub_gh() {
  cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GH_LOG"
case "\$1 \$2" in
  "api --paginate")
    case "$1" in
      fail)  exit 1 ;;
      empty) exit 0 ;;
      *)     printf '%s\n' "$1"; exit 0 ;;
    esac
    ;;
  "api --method")
    [ "$2" = ok ] || exit 1
    exit 0
    ;;
esac
case "\$1" in
  pr) [ "$2" = ok ] || exit 1; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/gh"
}

run_upsert() {
  PATH="$STUB_DIR:$PATH" run bash "$SCRIPT" "$@"
}

@test "upsert: no existing comment posts a new one" {
  stub_gh empty ok
  run_upsert 42 "audit complete"
  [ "$status" -eq 0 ]
  grep -qF 'pr comment 42' "$GH_LOG" || return 1
}

@test "upsert: an existing comment is PATCHed rather than duplicated" {
  stub_gh 99887766 ok
  run_upsert 42 "audit complete"
  [ "$status" -eq 0 ]
  grep -qF 'issues/comments/99887766' "$GH_LOG" || return 1
  # A PATCH path must never also post a fresh comment: that is the duplicate
  # this script exists to prevent.
  grep -qF 'pr comment' "$GH_LOG" && return 1
  true
}

@test "upsert: the body carries the marker the lookup keys on" {
  stub_gh empty ok
  run_upsert 42 "audit complete"
  [ "$status" -eq 0 ]
  # Without the marker on the posted body, the next run's lookup finds nothing
  # and appends a second comment instead of upserting the first.
  grep -qF '<!-- gaia:cra-status -->' "$GH_LOG" || return 1
  grep -qF 'audit complete' "$GH_LOG" || return 1
}

# ---------------------------------------------------------------------------
# The two fail-soft branches. Both must exit 0 (never red the job) AND explain
# themselves on stderr (the only signal a human gets that the comment is stale).
# ---------------------------------------------------------------------------

@test "upsert: a failed comment lookup skips the upsert instead of risking a duplicate" {
  # The lookup pipes through `| head -n1`, which always exits 0 regardless of
  # whether the `gh api --paginate` on its left side failed, so a transient
  # failure here would read as "no existing comment" and fall through to posting
  # a brand-new one blind. A duplicate `<!-- gaia:cra-status -->` comment can sit
  # on the PR indefinitely once that happens, and the marker lookup then has two
  # candidates forever. The script must skip the upsert entirely rather than
  # guess, which is why the failure is caught at the substitution rather than
  # left to the pipeline's exit status.
  stub_gh fail ok
  run_upsert 42 "audit complete"
  [ "$status" -eq 0 ]
  grep -qF 'comment lookup failed' <<<"$output" || return 1
  grep -qF 'non-fatal' <<<"$output" || return 1
  # No write of any kind may follow a failed lookup.
  grep -qE 'pr comment|--method PATCH' "$GH_LOG" && return 1
  true
}

@test "upsert: a failed PATCH is non-fatal" {
  stub_gh 99887766 fail
  run_upsert 42 "audit complete"
  [ "$status" -eq 0 ]
  grep -qF 'PATCH of comment 99887766 failed' <<<"$output" || return 1
}

@test "upsert: a failed create is non-fatal" {
  stub_gh empty fail
  run_upsert 42 "audit complete"
  [ "$status" -eq 0 ]
  grep -qF 'posting the status comment failed' <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# Wiring: the workflow must actually call this file. A committed script nothing
# invokes is exactly the invisible-breakage shape this extraction removes.
# ---------------------------------------------------------------------------

@test "upsert: the workflow invokes the committed script, not a temp copy" {
  local workflow="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$workflow" ] || skip "in-tree workflow absent (adopter clone)"

  grep -qF 'bash .github/audit/cra-status-upsert.sh' "$workflow" || return 1

  # No step may write the helper into RUNNER_TEMP any more: a temp copy is
  # invisible to shell-lint and to this suite, which is the defect being closed.
  grep -qF 'RUNNER_TEMP/cra-status-upsert' "$workflow" && return 1
  true
}

@test "upsert: every terminal status step reaches the committed script" {
  local workflow="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$workflow" ] || skip "in-tree workflow absent (adopter clone)"

  # One invocation per terminal status step at minimum. The count is a floor
  # rather than an equality because several steps branch internally and call it
  # from more than one arm.
  local calls
  calls="$( grep -cF 'bash .github/audit/cra-status-upsert.sh' "$workflow" )"
  [ "$calls" -ge 8 ]
}
