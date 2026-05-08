#!/usr/bin/env bats
# Tests for `.github/forensics/handlers/*.sh`.
#
# Strategy: shim `gh` (and `git`, for handle-auto-fixable's ls-remote
# sanity check) with a thin wrapper that records its full argv to
# $GH_LOG / $GIT_LOG and exits 0. Each test asserts the recorded calls
# match the documented contract.
#
# Coverage targets:
#   UAT-002   handle-non-issue: close + label + comment, gaia-triaged last
#   UAT-003   handle-needs-human: label + @mention + reason-code, stays open
#   UAT-004   handle-auto-fixable: --draft PR, both fix labels, link comment
#   UAT-005   handle-needs-human reason-code gate-failure surface
#   UAT-006   handle-already-triaged: pure no-op, ::notice:: line
#   UAT-007   handle-needs-human reason-code out-of-scope surface
#   UAT-008   handle-auto-fixable never invokes gh pr ready / gh pr merge
#   UAT-013   handle-malformed-body: parser-output → comment, no LLM
#   UAT-014   handle-needs-human reason-code out-of-scope surface (default-deny)
#   UAT-015   handle-auto-fixable PR body is passed via --body-file (passthrough)

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  HANDLERS="$THIS_DIR/../handlers"

  # Per-test sandbox.
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/captured-bodies"
  GH_LOG="$SANDBOX/gh.log"
  GIT_LOG="$SANDBOX/git.log"
  CAPTURED_BODIES_DIR="$SANDBOX/captured-bodies"
  export GH_LOG GIT_LOG CAPTURED_BODIES_DIR

  # gh shim: records every invocation as one line per call AND snapshots
  # every --body-file <path> argument's content under $CAPTURED_BODIES_DIR
  # so tests can inspect the body even after the handler's trap cleans up
  # its tmpdir. Special-case `gh issue view --json title --jq .title` and
  # `gh pr create` to emit deterministic stdout.
  cat > "$SANDBOX/bin/gh" <<'SHIM'
#!/usr/bin/env bash
# argv recording: one line, NUL-free shell-quoted via printf %q.
{
  printf 'gh'
  for a in "$@"; do
    printf ' %q' "$a"
  done
  printf '\n'
} >> "$GH_LOG"

# Snapshot --body-file content (handler's tmpdir gets cleaned via trap
# before the test can read it).
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ] && [ -f "$a" ]; then
    snap="$CAPTURED_BODIES_DIR/body-$(printf '%s' "$$-$RANDOM-${#a}").md"
    cp "$a" "$snap"
    # Append a sidecar so tests can correlate this body to its gh call.
    printf '%s\n' "$snap" >> "$CAPTURED_BODIES_DIR/index.txt"
  fi
  prev="$a"
done

# Specific stub responses needed by the handlers.
case "$1 $2" in
  "issue view")
    # handle-auto-fixable: `gh issue view <num> --json title --jq .title`
    printf 'Test issue title\n'
    ;;
  "pr create")
    # handle-auto-fixable expects the URL on stdout.
    printf 'https://github.com/gaia-react/gaia/pull/999\n'
    ;;
esac
exit 0
SHIM
  chmod +x "$SANDBOX/bin/gh"

  # git shim: only the ls-remote heads call is exercised by these tests.
  # Default to "branch present" (exit 0). Tests that need "branch absent"
  # set GIT_LS_REMOTE_FAIL=1.
  cat > "$SANDBOX/bin/git" <<'SHIM'
#!/usr/bin/env bash
{
  printf 'git'
  for a in "$@"; do
    printf ' %q' "$a"
  done
  printf '\n'
} >> "$GIT_LOG"

if [ "$1" = "ls-remote" ]; then
  if [ "${GIT_LS_REMOTE_FAIL:-0}" = "1" ]; then
    exit 2
  fi
  printf 'deadbeefdeadbeef\trefs/heads/dummy\n'
  exit 0
fi

# Anything else: pass through to the real git so we don't break any
# helper that drifts in.
exec /usr/bin/env -u PATH PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" git "$@"
SHIM
  chmod +x "$SANDBOX/bin/git"

  PATH="$SANDBOX/bin:$PATH"
  export PATH
}

# Helper: count occurrences of a literal substring in $GH_LOG.
gh_log_count() {
  if [ ! -f "$GH_LOG" ]; then
    printf '0'
    return
  fi
  grep -cF -- "$1" "$GH_LOG" || true
}

# Helper: line-number of the first $GH_LOG line containing literal $1, or empty.
gh_log_line_no() {
  grep -nF -- "$1" "$GH_LOG" 2>/dev/null | head -1 | cut -d: -f1
}

# Helper: path to the first --body-file content captured by the gh shim.
# (Order matches the gh-shim invocation order; for the suites here all
# handlers post exactly one comment per run, so "first" == "the comment".)
first_captured_body() {
  head -1 "$CAPTURED_BODIES_DIR/index.txt"
}

# ---------------------------------------------------------------------------
# handle-non-issue.sh — UAT-002
# ---------------------------------------------------------------------------

@test "non-issue: usage error with no args" {
  run "$HANDLERS/handle-non-issue.sh"
  [ "$status" -eq 2 ]
}

@test "non-issue: missing reasoning file exits 2" {
  run "$HANDLERS/handle-non-issue.sh" 42 "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}

@test "non-issue: applies non-issue label" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'user mis-config; not a bug.\n' > "$reasoning"
  run "$HANDLERS/handle-non-issue.sh" 42 "$reasoning"
  [ "$status" -eq 0 ]
  [ "$(gh_log_count '--add-label non-issue')" -ge 1 ]
}

@test "non-issue: posts comment via --body-file (never inline)" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'user mis-config; not a bug.\n' > "$reasoning"
  run "$HANDLERS/handle-non-issue.sh" 42 "$reasoning"
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'gh issue comment 42 --body-file')" -ge 1 ]
  # No --body inline form anywhere (passthrough discipline).
  [ "$(gh_log_count 'gh issue comment 42 --body ')" -eq 0 ]
}

@test "non-issue: closes the issue" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'x\n' > "$reasoning"
  run "$HANDLERS/handle-non-issue.sh" 42 "$reasoning"
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'gh issue close 42')" -ge 1 ]
}

@test "non-issue: gaia-triaged is the LAST mutation" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'x\n' > "$reasoning"
  run "$HANDLERS/handle-non-issue.sh" 42 "$reasoning"
  [ "$status" -eq 0 ]
  triaged_line="$(gh_log_line_no '--add-label gaia-triaged')"
  total_lines="$(wc -l < "$GH_LOG" | tr -d ' ')"
  [ "$triaged_line" = "$total_lines" ]
}

@test "non-issue: comment body contains the verdict header and reasoning" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'sentinel-reason-line\n' > "$reasoning"
  run "$HANDLERS/handle-non-issue.sh" 42 "$reasoning"
  [ "$status" -eq 0 ]
  body_path="$(first_captured_body)"
  grep -qF 'verdict: non-issue' "$body_path"
  grep -qF 'sentinel-reason-line' "$body_path"
}

# ---------------------------------------------------------------------------
# handle-needs-human.sh — UAT-003 / UAT-005 / UAT-007 / UAT-014
# ---------------------------------------------------------------------------

@test "needs-human: usage error with too few args" {
  run "$HANDLERS/handle-needs-human.sh" 42
  [ "$status" -eq 2 ]
}

@test "needs-human: rejects unknown reason-code" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'x\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" not-a-real-reason
  [ "$status" -eq 2 ]
}

@test "needs-human: applies needs-human label" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'x\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" out-of-scope
  [ "$status" -eq 0 ]
  [ "$(gh_log_count '--add-label needs-human')" -ge 1 ]
}

@test "needs-human: never closes the issue" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'x\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" out-of-scope
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'gh issue close')" -eq 0 ]
}

@test "needs-human: comment mentions @stevensacks (UAT-003)" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'x\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" out-of-scope
  [ "$status" -eq 0 ]
  body_path="$(first_captured_body)"
  grep -qF '@stevensacks' "$body_path"
}

@test "needs-human: comment names the reason-code out-of-scope (UAT-007/UAT-014)" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'x\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" out-of-scope
  [ "$status" -eq 0 ]
  body_path="$(first_captured_body)"
  grep -qF 'out-of-scope' "$body_path"
  grep -qF 'UAT-007' "$body_path"
}

@test "needs-human: comment names the reason-code gate-failure (UAT-005)" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'gate failure detail\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" gate-failure
  [ "$status" -eq 0 ]
  body_path="$(first_captured_body)"
  grep -qF 'gate-failure' "$body_path"
  grep -qF 'UAT-005' "$body_path"
}

@test "needs-human: comment names the reason-code ambiguous-verdict (UAT-003b)" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'ambiguous\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" ambiguous-verdict
  [ "$status" -eq 0 ]
  body_path="$(first_captured_body)"
  grep -qF 'ambiguous-verdict' "$body_path"
}

@test "needs-human: comment names the reason-code deviation (UAT-010)" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'deviation detail\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" deviation
  [ "$status" -eq 0 ]
  body_path="$(first_captured_body)"
  grep -qF 'reason: `deviation`' "$body_path"
  grep -qF 'in-allowlist paths' "$body_path"
  grep -qF 'deviates from the classifier' "$body_path"
}

@test "needs-human: gaia-triaged is the LAST mutation" {
  reasoning="$BATS_TEST_TMPDIR/r.md"
  printf 'x\n' > "$reasoning"
  run "$HANDLERS/handle-needs-human.sh" 42 "$reasoning" out-of-scope
  [ "$status" -eq 0 ]
  triaged_line="$(gh_log_line_no '--add-label gaia-triaged')"
  total_lines="$(wc -l < "$GH_LOG" | tr -d ' ')"
  [ "$triaged_line" = "$total_lines" ]
}

# ---------------------------------------------------------------------------
# handle-auto-fixable.sh — UAT-004 / UAT-008 / UAT-015
# ---------------------------------------------------------------------------

@test "auto-fixable: usage error with too few args" {
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate
  [ "$status" -eq 2 ]
}

@test "auto-fixable: missing pr body file exits 2" {
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
}

@test "auto-fixable: missing remote branch exits 1" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf '## Capture\nverbatim\n' > "$body"
  GIT_LS_REMOTE_FAIL=1 run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 1 ]
  # No gh write calls when the sanity check fails — guard against
  # half-applied state.
  [ "$(gh_log_count 'gh issue edit')" -eq 0 ]
  [ "$(gh_log_count 'gh pr create')" -eq 0 ]
}

@test "auto-fixable: invokes gh pr create with --draft (UAT-008)" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf '## Capture\nverbatim\n' > "$body"
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'gh pr create')" -ge 1 ]
  [ "$(gh_log_count '--draft')" -ge 1 ]
}

@test "auto-fixable: pr create uses --base main and the supplied --head" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf 'x\n' > "$body"
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 0 ]
  pr_line="$(grep -F 'gh pr create' "$GH_LOG")"
  [[ "$pr_line" == *'--base main'* ]]
  [[ "$pr_line" == *'--head forensics/42-quality-gate'* ]]
}

@test "auto-fixable: pr body passed via --body-file (UAT-015 passthrough)" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf '## Capture\n```\napi_key: <redacted>\n```\n' > "$body"
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 0 ]
  pr_line="$(grep -F 'gh pr create' "$GH_LOG")"
  [[ "$pr_line" == *'--body-file'* ]]
  # Inline --body must NOT appear — passthrough goes through file only.
  [[ "$pr_line" != *'--body '* ]]
}

@test "auto-fixable: applies auto-fixable + gaia-bug-confirmed labels" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf 'x\n' > "$body"
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 0 ]
  [ "$(gh_log_count '--add-label auto-fixable')" -ge 1 ]
  [ "$(gh_log_count '--add-label gaia-bug-confirmed')" -ge 1 ]
}

@test "auto-fixable: posts a link-back comment via --body-file" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf 'x\n' > "$body"
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'gh issue comment 42 --body-file')" -ge 1 ]
}

@test "auto-fixable: gaia-triaged is the LAST mutation" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf 'x\n' > "$body"
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 0 ]
  triaged_line="$(gh_log_line_no '--add-label gaia-triaged')"
  total_lines="$(wc -l < "$GH_LOG" | tr -d ' ')"
  [ "$triaged_line" = "$total_lines" ]
}

@test "auto-fixable: never invokes gh pr merge or gh pr ready (UAT-008)" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf 'x\n' > "$body"
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 0 ]
  [ "$(gh_log_count 'gh pr merge')" -eq 0 ]
  [ "$(gh_log_count 'gh pr ready')" -eq 0 ]
}

@test "auto-fixable: never modifies the issue body (only labels and comments)" {
  body="$BATS_TEST_TMPDIR/pr.md"
  printf 'x\n' > "$body"
  run "$HANDLERS/handle-auto-fixable.sh" 42 quality-gate forensics/42-quality-gate "$body"
  [ "$status" -eq 0 ]
  # `gh issue edit --body` would be a body mutation; the only --body* we
  # tolerate on the issue is `gh issue comment --body-file`.
  [ "$(gh_log_count 'gh issue edit 42 --body')" -eq 0 ]
  [ "$(gh_log_count 'gh issue edit 42 --title')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# handle-malformed-body.sh — UAT-013
# ---------------------------------------------------------------------------

@test "malformed-body: usage error with no args" {
  run "$HANDLERS/handle-malformed-body.sh"
  [ "$status" -eq 2 ]
}

@test "malformed-body: missing parser output exits 2" {
  run "$HANDLERS/handle-malformed-body.sh" 42 "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
}

@test "malformed-body: applies needs-human label and stays open" {
  parser="$BATS_TEST_TMPDIR/p.json"
  printf '{"valid":false,"error":"missing-section","missing":["symptom"],"malformed":[]}\n' > "$parser"
  run "$HANDLERS/handle-malformed-body.sh" 42 "$parser"
  [ "$status" -eq 0 ]
  [ "$(gh_log_count '--add-label needs-human')" -ge 1 ]
  [ "$(gh_log_count 'gh issue close')" -eq 0 ]
}

@test "malformed-body: comment names missing sections from parser output" {
  parser="$BATS_TEST_TMPDIR/p.json"
  printf '{"valid":false,"error":"missing-section","missing":["symptom","capture"],"malformed":[]}\n' > "$parser"
  run "$HANDLERS/handle-malformed-body.sh" 42 "$parser"
  [ "$status" -eq 0 ]
  body_path="$(first_captured_body)"
  grep -qF 'symptom' "$body_path"
  grep -qF 'capture' "$body_path"
  grep -qF 'missing-section' "$body_path"
  grep -qF 'UAT-013' "$body_path"
}

@test "malformed-body: comment names malformed sections from parser output" {
  parser="$BATS_TEST_TMPDIR/p.json"
  printf '{"valid":false,"error":"malformed-frontmatter","missing":[],"malformed":["frontmatter"]}\n' > "$parser"
  run "$HANDLERS/handle-malformed-body.sh" 42 "$parser"
  [ "$status" -eq 0 ]
  body_path="$(first_captured_body)"
  grep -qF 'frontmatter' "$body_path"
  grep -qF 'malformed-frontmatter' "$body_path"
}

@test "malformed-body: gaia-triaged is the LAST mutation" {
  parser="$BATS_TEST_TMPDIR/p.json"
  printf '{"valid":false,"error":"missing-section","missing":["symptom"],"malformed":[]}\n' > "$parser"
  run "$HANDLERS/handle-malformed-body.sh" 42 "$parser"
  [ "$status" -eq 0 ]
  triaged_line="$(gh_log_line_no '--add-label gaia-triaged')"
  total_lines="$(wc -l < "$GH_LOG" | tr -d ' ')"
  [ "$triaged_line" = "$total_lines" ]
}

# ---------------------------------------------------------------------------
# handle-already-triaged.sh — UAT-006
# ---------------------------------------------------------------------------

@test "already-triaged: usage error with no args" {
  run "$HANDLERS/handle-already-triaged.sh"
  [ "$status" -eq 2 ]
}

@test "already-triaged: emits ::notice:: and exits 0" {
  run "$HANDLERS/handle-already-triaged.sh" 42
  [ "$status" -eq 0 ]
  [[ "$output" == *'::notice::'* ]]
  [[ "$output" == *'#42'* ]]
  [[ "$output" == *'already triaged'* ]]
}

@test "already-triaged: makes zero gh / git calls (no-op)" {
  run "$HANDLERS/handle-already-triaged.sh" 42
  [ "$status" -eq 0 ]
  # gh and git logs may not even exist — that's the no-op contract.
  if [ -f "$GH_LOG" ]; then
    [ "$(wc -l < "$GH_LOG" | tr -d ' ')" = "0" ]
  fi
  if [ -f "$GIT_LOG" ]; then
    [ "$(wc -l < "$GIT_LOG" | tr -d ' ')" = "0" ]
  fi
}
