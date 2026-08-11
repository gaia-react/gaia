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
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.github/audit/cra-status-upsert.sh"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  # A hard assertion, not the adopter-clone `skip` its sibling suites use for
  # the workflow: `.github/audit/tests` is release-excluded, so this suite never
  # runs on an adopter clone and the only way the script goes missing is a commit
  # deleting or renaming it. Skipping there would report the whole suite
  # green-by-absence in exactly the case it exists to catch.
  [ -f "$SCRIPT" ]

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

# terminal_status_steps: the job's `Status - *` step names, in file order.
terminal_status_steps() {
  awk '/^      - name: Status - / { print substr($0, index($0, "name: ") + 6) }' \
    "$WORKFLOW"
}

# step_body <step-name>: that step's `run:` block.
step_body() {
  awk -v want="$1" '
    /^      - name: / {
      cur = substr($0, index($0, "name: ") + 6)
      instep = (cur == want)
      inrun = 0
      next
    }
    !instep { next }
    /^        run: \|/ { inrun = 1; next }
    inrun && /^        [^[:space:]]/ { inrun = 0; next }
    inrun { print }
  ' "$WORKFLOW"
}

@test "upsert: the workflow invokes the committed script, not a temp copy" {
  [ -f "$WORKFLOW" ] || skip "in-tree workflow absent (adopter clone)"

  grep -qF 'bash .github/audit/cra-status-upsert.sh' "$WORKFLOW" || return 1

  # No step may write the helper into RUNNER_TEMP any more: a temp copy is
  # invisible to shell-lint and to this suite, which is the defect being closed.
  grep -qF 'RUNNER_TEMP/cra-status-upsert' "$WORKFLOW" && return 1
  true
}

@test "upsert: every terminal status step reaches the committed script" {
  [ -f "$WORKFLOW" ] || skip "in-tree workflow absent (adopter clone)"

  # Asserted per step, not as a total-count floor. A floor is satisfied by the
  # steps that do call the script, so dropping the call from any single step
  # leaves the count above the floor and the assertion green: exactly the step
  # whose comment then silently stops updating. Only a per-step check can see it.
  local step body missing count
  missing=""
  count=0
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    count=$(( count + 1 ))
    body="$( step_body "$step" )"
    if [ -z "$body" ]; then
      printf 'no run: body extracted for step: %s\n' "$step" >&2
      return 1
    fi
    printf '%s\n' "$body" \
      | grep -qF 'bash .github/audit/cra-status-upsert.sh' \
      || missing="${missing}${step}"$'\n'
  done <<EOF
$( terminal_status_steps )
EOF

  if [ -n "$missing" ]; then
    printf 'terminal status steps not reaching the committed script:\n%s' \
      "$missing" >&2
    return 1
  fi

  # Floor on the step count itself, so an extractor that silently matched
  # nothing cannot pass this test vacuously.
  [ "$count" -ge 8 ]
}
