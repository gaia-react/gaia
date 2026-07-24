#!/usr/bin/env bats
# Tests for `.gaia/scripts/post-findings-block.sh`, the local producer's
# findings-block merge-and-post script. Merges every dispatched Code Audit
# Team member's `.gaia/local/audit/<base-sha>.<member>.findings.json`
# sidecar for one run into ONE rendered block and posts-or-updates exactly
# one PR comment carrying it (the local counterpart to the block CI's own
# workflow prompt already emits).
#
# Every test runs against an isolated sandbox with a stub `gh` on PATH, never
# a real network call.
#
# Assertion style (`.claude/rules/bats-assertions.md`): macOS's system bash
# 3.2 does not fail a bats @test on a false bare `[[ ... ]]` that is not the
# test's last command, so non-final checks use POSIX `[ ]`, `grep -qF`, or an
# explicit `return 1`, never a bare mid-test `[[ ]]` and never a non-final
# `!`-negation.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../post-findings-block.sh"
  [ -x "$SCRIPT" ] || skip "post-findings-block.sh not executable"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia/local/audit" "$SANDBOX/bin"
  # Pinned to "main" (unborn HEAD, no commit needed -- `git branch
  # --show-current` answers "main" immediately) so the sidecar tag this suite
  # writes is deterministic across machines rather than riding whatever
  # `init.defaultBranch` the host has configured.
  git -C "$SANDBOX" init --quiet --initial-branch=main
  AUDIT_DIR="$SANDBOX/.gaia/local/audit"
  BASE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # The real tag (gaia_audit_key, audit-key-lib.sh) is base-sha + branch
  # slug; "main" has nothing to percent-encode, so the slug is the branch
  # name verbatim.
  AUDIT_TAG="${BASE}.main"
  GH_LOG="$SANDBOX/gh.log"
}

# write_sidecar <member> <findings-json-array>
write_sidecar() {
  local member="$1" findings="$2"
  printf '{"schema":1,"member":"%s","findings":%s}\n' "$member" "$findings" \
    > "$AUDIT_DIR/${AUDIT_TAG}.${member}.findings.json"
}

# stub_gh <comments-json>: a fake `gh` supporting `auth status` (ok), `pr view`
# (echoes PR 42), `repo view` (echoes acme/widgets), and `api`: a call with no
# --method is a list, answered by applying the REAL --jq filter (via the real
# jq) against <comments-json>, exactly what a real `gh api --jq` would return;
# a call WITH --method records its method and the file behind `-f body=@...`
# for assertions, and always "succeeds" (prints a fake comment id). Every
# invocation is appended to GH_LOG.
stub_gh() {
  local comments_json="${1:-[]}"
  cat > "$SANDBOX/bin/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
case "\$1 \$2" in
  "auth status") exit 0 ;;
esac
case "\$1" in
  pr)
    [ "\$2" = "view" ] && echo 42
    ;;
  repo)
    echo "acme/widgets"
    ;;
  api)
    method=""
    filter=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "--method" ] && method="\$a"
      [ "\$prev" = "--jq" ] && filter="\$a"
      prev="\$a"
    done
    if [ -z "\$method" ]; then
      printf '%s' '$comments_json' | jq -r "\$filter"
    else
      for a in "\$@"; do
        case "\$a" in
          body=@*) cp "\${a#body=@}" "$SANDBOX/posted_body.txt" ;;
        esac
      done
      echo "\$method" > "$SANDBOX/last_method.txt"
      echo '{"id":999}'
    fi
    ;;
esac
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_no_auth: gh is present but `gh auth status` fails.
stub_gh_no_auth() {
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 1 ;;
esac
exit 1
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_no_pr: gh is present and authenticated, but `gh pr view` resolves
# to nothing (no PR for the current branch).
stub_gh_no_pr() {
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
esac
case "$1" in
  pr) ;; # view prints nothing
esac
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# minimal_path <omit>: builds a curated bin dir carrying only the named
# coreutils (never the host's real PATH), so a tool named in <omit> is
# genuinely absent, not merely shadowed. Mirrors the no-gh forensics fixture
# (.gaia/tests/forensics/07-gh-not-installed.bats), extended with the extra
# tools this script's own body needs (jq, git, mktemp, sort, dirname -- the
# last for sourcing audit-key-lib.sh, .gaia/scripts/audit-key-lib.sh).
minimal_path() {
  local omit="$1"
  local d="$SANDBOX/minimal-bin-${omit}"
  mkdir -p "$d"
  for cmd in bash jq git mktemp sort cat head sed rm mkdir printf gh dirname; do
    [ "$cmd" = "$omit" ] && continue
    local real
    real="$(command -v "$cmd" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "$d/$cmd"
  done
  printf '%s' "$d"
}

run_script() {
  ( cd "$SANDBOX" && PATH="$SANDBOX/bin:$PATH" "$SCRIPT" "$@" )
}

# extract_payload: the rendered block is always five lines (see the script's
# own render step); line 3 is the raw JSON payload inside the inner comment.
extract_payload() {
  sed -n '3p' "$SANDBOX/posted_body.txt"
}

# =============================================================================
# Usage
# =============================================================================

@test "usage: --help exits 0 with usage text" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  grep -qF "usage: post-findings-block.sh" <<<"$output"
}

@test "usage: missing --base exits 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  grep -qF "base is required" <<<"$output"
}

@test "usage: an unrecognized flag exits 2" {
  run bash "$SCRIPT" --base "$BASE" --bogus
  [ "$status" -eq 2 ]
}

# =============================================================================
# UAT-034: one block, every dispatched member's findings
# =============================================================================

@test "UAT-034: multiple sidecars merge into exactly one posted block carrying every member's findings" {
  write_sidecar code-audit-frontend '[{"finding_class":"holistic/swallowed-error","severity":"warning","area_tags":["app/services"]}]'
  write_sidecar code-audit-maintainer-shell '[{"finding_class":"holistic/secret-exposure","severity":"error","area_tags":[".gaia/scripts"]}]'
  stub_gh '[]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "findings: posted 2 finding(s) from 2 member(s) to PR #42" ]
  # Exactly one write call (a POST, no existing comment), never two.
  post_calls="$(grep -c -- '--method POST' "$GH_LOG")"
  [ "$post_calls" -eq 1 ]
  patch_calls="$(grep -c -- '--method PATCH' "$GH_LOG" || true)"
  [ "$patch_calls" -eq 0 ]
  payload="$(extract_payload)"
  [ "$(jq '.findings | length' <<<"$payload")" = "2" ]
}

# =============================================================================
# UAT-037: structural shape the tally's parser accepts
# =============================================================================

@test "UAT-037: the rendered block carries the sentinels and a structurally valid payload" {
  write_sidecar code-audit-frontend '[{"finding_class":"holistic/swallowed-error","severity":"warning","area_tags":["app/services"]}]'
  stub_gh '[]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  grep -qF "<!-- gaia-harden:findings:start -->" "$SANDBOX/posted_body.txt"
  grep -qF "<!-- gaia-harden:findings:end -->" "$SANDBOX/posted_body.txt"
  payload="$(extract_payload)"
  jq -e . <<<"$payload" >/dev/null
  [ "$(jq -r '.schema' <<<"$payload")" = "1" ]
  [ "$(jq -r '.pr_number' <<<"$payload")" = "42" ]
  [ "$(jq -r '.auditor' <<<"$payload")" = "local" ]
  [ "$(jq '(.findings | type) == "array"' <<<"$payload")" = "true" ]
  entry="$(jq -c '.findings[0]' <<<"$payload")"
  [ "$(jq 'has("finding_class")' <<<"$entry")" = "true" ]
  [ "$(jq 'has("severity")' <<<"$entry")" = "true" ]
  [ "$(jq 'has("area_tags")' <<<"$entry")" = "true" ]
}

# =============================================================================
# AC3: a second run with the same base updates, never duplicates
# =============================================================================

@test "a second run with the same base updates the existing comment rather than creating a second" {
  write_sidecar code-audit-frontend '[]'
  stub_gh '[{"id":5,"body":"unrelated comment"},{"id":7,"body":"prior findings <!-- gaia-harden:findings:start -->\nold\n<!-- gaia-harden:findings:end -->"}]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "findings: updated 0 finding(s) from 1 member(s) on PR #42" ]
  [ "$(cat "$SANDBOX/last_method.txt")" = "PATCH" ]
  grep -qF -- '--method POST' "$GH_LOG" && return 1
  return 0
}

# =============================================================================
# AC4: zero sidecars declines cleanly, before any gh call
# =============================================================================

@test "zero sidecars: declines cleanly, exit 0, nothing posted" {
  stub_gh '[]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "findings: declined: no sidecars" ]
  # Declined before gh was ever invoked (the glob check runs first).
  [ ! -e "$GH_LOG" ]
}

# =============================================================================
# AC5: every sidecar carries findings: [] -> still one meaningful post
# =============================================================================

@test "all sidecars carry findings: [] -> one block is still posted, with an empty array" {
  write_sidecar code-audit-frontend '[]'
  write_sidecar code-audit-maintainer-shell '[]'
  stub_gh '[]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "findings: posted 0 finding(s) from 2 member(s) to PR #42" ]
  payload="$(extract_payload)"
  [ "$(jq -c '.findings' <<<"$payload")" = "[]" ]
}

# =============================================================================
# AC6: a malformed sidecar is skipped, named, and never silently vanishes
# =============================================================================

@test "a malformed sidecar (invalid JSON) is skipped, named on stderr, and the rest still posts" {
  write_sidecar code-audit-frontend '[{"finding_class":"holistic/swallowed-error","severity":"warning","area_tags":["app/services"]}]'
  echo 'not json at all' > "$AUDIT_DIR/${AUDIT_TAG}.code-audit-maintainer-shell.findings.json"
  stub_gh '[]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  grep -qF "malformed sidecar" <<<"$output"
  grep -qF "code-audit-maintainer-shell.findings.json" <<<"$output"
  [ "$(tail -n 1 <<<"$output")" = "findings: posted 1 finding(s) from 1 member(s) to PR #42" ]
}

@test "a sidecar with a non-array findings field is malformed and skipped" {
  printf '{"schema":1,"member":"code-audit-maintainer-node","findings":"oops"}\n' \
    > "$AUDIT_DIR/${AUDIT_TAG}.code-audit-maintainer-node.findings.json"
  write_sidecar code-audit-frontend '[]'
  stub_gh '[]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  grep -qF "malformed sidecar" <<<"$output"
  [ "$(tail -n 1 <<<"$output")" = "findings: posted 0 finding(s) from 1 member(s) to PR #42" ]
}

@test "when every matched sidecar is malformed, declines no sidecars (each still named on stderr)" {
  echo 'not json' > "$AUDIT_DIR/${AUDIT_TAG}.code-audit-frontend.findings.json"
  stub_gh '[]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  grep -qF "malformed sidecar" <<<"$output"
  [ "$(tail -n 1 <<<"$output")" = "findings: declined: no sidecars" ]
  [ ! -e "$GH_LOG" ]
}

# =============================================================================
# AC7: gh absent / unauthenticated, fail-safe asymmetry
# =============================================================================

@test "gh absent: declines, exit 0, nothing touched" {
  write_sidecar code-audit-frontend '[]'
  path_no_gh="$(minimal_path gh)"
  run bash -c "cd '$SANDBOX' && PATH='$path_no_gh' bash '$SCRIPT' --base '$BASE'"
  [ "$status" -eq 0 ]
  [ "$output" = "findings: declined: gh absent" ]
}

@test "gh unauthenticated: declines, exit 0, nothing touched" {
  write_sidecar code-audit-frontend '[]'
  stub_gh_no_auth
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "findings: declined: gh unauthenticated" ]
}

@test "pr unresolved (no --pr, gh pr view empty): declines, exit 0" {
  write_sidecar code-audit-frontend '[]'
  stub_gh_no_pr
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "findings: declined: pr unresolved" ]
}

@test "--pr overrides the default gh pr view resolution" {
  write_sidecar code-audit-frontend '[]'
  stub_gh '[]'
  run run_script --base "$BASE" --pr 777
  [ "$status" -eq 0 ]
  grep -qF "PR #777" <<<"$output"
}

@test "jq absent: fails closed with a clear message" {
  write_sidecar code-audit-frontend '[]'
  path_no_jq="$(minimal_path jq)"
  run env PATH="$path_no_jq" bash "$SCRIPT" --base "$BASE"
  [ "$status" -ne 0 ]
  grep -qF "jq is required" <<<"$output"
}

# =============================================================================
# AC9: the sidecar glob is provably distinct from every clearance/marker key
# =============================================================================

@test "the sidecar glob never matches a clearance marker, refusal, dispositions sidecar, or rerun ledger" {
  # A marker/refusal/dispositions family is keyed to a 64-hex content DIGEST;
  # a findings sidecar is keyed to a 40-hex commit BASE-SHA. Placing
  # lookalikes at the exact BASE value this suite uses proves the glob
  # (`<base>.*.findings.json`) cannot pick any of them up, in either
  # direction: they neither get merged nor even get treated as a malformed
  # sidecar (they are never named on stderr, because the glob never matches
  # them at all).
  : > "$AUDIT_DIR/${BASE}.ok"
  : > "$AUDIT_DIR/${BASE}.refused"
  : > "$AUDIT_DIR/${BASE}.dispositions.json"
  : > "$AUDIT_DIR/${AUDIT_TAG}.rerun.json"
  write_sidecar code-audit-frontend '[]'
  stub_gh '[]'
  run run_script --base "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "findings: posted 0 finding(s) from 1 member(s) to PR #42" ]
  grep -qF "${BASE}.ok" <<<"$output" && return 1
  grep -qF "${BASE}.refused" <<<"$output" && return 1
  grep -qF "${BASE}.dispositions.json" <<<"$output" && return 1
  grep -qF "${AUDIT_TAG}.rerun.json" <<<"$output" && return 1
  return 0
}

# =============================================================================
# AC10/11: structural hygiene
# =============================================================================

@test "structural: never invokes cd, per .claude/rules/shell-cwd.md" {
  code_lines="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"
  grep -qE '(^|[^[:alnum:]_])cd([^[:alnum:]_]|$)' <<<"$code_lines" && return 1
  return 0
}

@test "structural: no hardcoded /Users or /home paths" {
  grep -E '/Users/|/home/' "$SCRIPT" && return 1
  return 0
}

@test "structural: shellcheck is clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  shellcheck "$SCRIPT"
}
