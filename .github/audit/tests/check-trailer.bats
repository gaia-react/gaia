#!/usr/bin/env bats

# Tests for .github/audit/check-trailer.sh.
#
# The helper is consumed by the code-review-audit CI workflow's
# "Check audit trailer" step: stdout is piped into `>> $GITHUB_OUTPUT`.
# The frozen contract lives in
# .gaia/local/plans/code-review-audit-ci/trailer-format.md ("CI skip
# logic (frozen)") and the README's "CI workflow check name" /
# "Adopter config knobs (frozen)" sections.
#
# Each test runs the script in an isolated `git init`'d temp dir so the
# script's `git rev-parse --show-toplevel` resolves to that fixture
# (and not the GAIA repo root, which already ships .gaia/VERSION).
#
# The status fallback path is exercised by mocking `gh` on a prepended
# PATH (see `install_gh_mock`). It runs only when HEAD has no GAIA-Audit
# trailer, the default sandbox commit gives that state.
#
# Coverage:
#   1. No trailer present                        → skip=false reason=no-trailer
#   2. Trailer matches version + tree            → skip=true  reason=trailer-matches
#   3. Trailer matches version, tree mismatch    → skip=false reason=tree-mismatch
#   4. Trailer matches tree, version mismatch    → skip=false reason=version-mismatch
#   5. Two trailers, last one matches            → skip=true
#   6. Two trailers, last one mismatches         → skip=false
#   7. Malformed trailer (truncated tree-sha)    → skip=false reason=no-trailer
#   8. .gaia/VERSION missing                     → skip=false reason=version-file-missing
#   9. .gaia/VERSION empty                       → skip=false reason=version-file-missing
#  10. Status present + matching                 → skip=true  reason=status-matches
#  11. Status present, version drift             → skip=false reason=status-version-mismatch
#  12. Status present, tree drift                → skip=false reason=status-tree-mismatch
#  13. Status API failure                        → skip=false reason=no-trailer
#  14. No GAIA-Audit status on HEAD              → skip=false reason=no-trailer
#  15. Malformed status description              → skip=false reason=no-trailer
#  16. Pending status, matching version+tree      → skip=false reason=no-trailer
#  17. Success status, matching version+tree      → skip=true  reason=status-matches
#  18. Pending + success both present             → skip=true  (success picked)

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../check-trailer.sh"
  [ -x "$SCRIPT" ] || skip "check-trailer.sh not executable"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"
  printf '1.2.3\n' > "$SANDBOX/.gaia/VERSION"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add .gaia/VERSION README.md
  git -C "$SANDBOX" commit --quiet -m "init"
}

# Run the script with cwd inside the sandbox so its
# `git rev-parse --show-toplevel` lookup hits the fixture.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" )
}

# Amend HEAD with one or more trailer key=value pairs.
# Each argument becomes a single `--trailer` flag.
amend_with_trailers() {
  local args=()
  for t in "$@"; do
    args+=( "--trailer" "$t" )
  done
  git -C "$SANDBOX" commit --amend --no-edit --no-verify "${args[@]}" >/dev/null
}

# Append a raw trailer line to HEAD's commit message via amend.
# Used for malformed-shape coverage where `--trailer` would refuse to
# write a non-conforming value.
amend_with_raw_message() {
  local body="$1"
  git -C "$SANDBOX" commit --amend --no-edit --no-verify -m "$body" >/dev/null
}

current_tree() {
  git -C "$SANDBOX" rev-parse "HEAD^{tree}"
}

# Install a fake `gh` on a prepended PATH to exercise the status fallback.
# The mock ignores `gh`'s args, the script's `--jq` expression runs
# server-side against the real API; the mock just emits the already-
# extracted GAIA-Audit description string directly.
#   $1 behavior:
#     fail   → exit 1 (API error)
#     empty  → print nothing (no GAIA-Audit status on HEAD)
#     *      → print $2 as the status description
#   $2 description string (for non-fail/non-empty behaviors).
# Also sets GH_TOKEN + GITHUB_REPOSITORY so check_status_fallback runs.
install_gh_mock() {
  local behavior="$1"
  local desc="${2:-}"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
case "$behavior" in
  fail)  exit 1 ;;
  empty) exit 0 ;;
  *)     printf '%s\n' "$desc" ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
  export GH_TOKEN="fake-token"
  export GITHUB_REPOSITORY="gaia-react/gaia"
}

# Install a fake `gh` that returns a full JSON statuses array and runs the
# script's real `--jq` expression against it. This exercises the production
# state filter (map(select(... and .state == "success"))), so the test sees
# exactly what the reader sees: a pending status is filtered out at the source,
# a success status survives, and a SHA carrying both is resolved to the success
# one regardless of array position. The mock parses its own argv for the value
# following `--jq` and pipes the crafted array through the real jq.
#   $1 JSON array string (the raw statuses payload the real API would return).
# Also sets GH_TOKEN + GITHUB_REPOSITORY so check_status_fallback runs.
install_gh_array_mock() {
  local payload="$1"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  printf '%s' "$payload" > "$BATS_TEST_TMPDIR/gh-statuses.json"
  cat > "$GH_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Mock `gh api ... --jq <expr>`: find the --jq expression in argv and run the
# real jq against the crafted statuses payload, mirroring gh's server-side jq.
jq_expr=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then jq_expr="$a"; break; fi
  prev="$a"
done
[ -n "$jq_expr" ] || { printf 'null\n'; exit 0; }
jq -r "$jq_expr" < "PAYLOAD_FILE"
EOF
  sed -i.bak "s#PAYLOAD_FILE#$BATS_TEST_TMPDIR/gh-statuses.json#" "$GH_BIN/gh"
  rm -f "$GH_BIN/gh.bak"
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
  export GH_TOKEN="fake-token"
  export GITHUB_REPOSITORY="gaia-react/gaia"
}

# -----------------------------------------------------------------------------
# 1. No trailer present
# -----------------------------------------------------------------------------

@test "no trailer on HEAD: skip=false reason=no-trailer" {
  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=no-trailer"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 2. Trailer matches version + tree
# -----------------------------------------------------------------------------

@test "trailer matches version + tree: skip=true reason=trailer-matches" {
  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 1.2.3 ${tree}"

  # Re-resolve tree post-amend (amend can change the tree only if the
  # commit body changes; --trailer adds to the body but tree stays the
  # same so this is just defensive).
  tree=$(current_tree)

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=true
matched_version=1.2.3
matched_tree=${tree}
reason=trailer-matches"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 3. Trailer version matches, tree mismatch
# -----------------------------------------------------------------------------

@test "trailer version match + tree mismatch: skip=false reason=tree-mismatch" {
  fake_tree="0000000000000000000000000000000000000000"
  amend_with_trailers "GAIA-Audit: 1.2.3 ${fake_tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=1.2.3
matched_tree=${fake_tree}
reason=tree-mismatch"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 4. Trailer tree matches, version mismatch
# -----------------------------------------------------------------------------

@test "trailer tree match + version mismatch: skip=false reason=version-mismatch" {
  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 9.9.9 ${tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=9.9.9
matched_tree=${tree}
reason=version-mismatch"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 5. Two trailers, last one matches → skip=true
# -----------------------------------------------------------------------------

@test "two trailers, last one matches: skip=true (last wins)" {
  fake_tree="1111111111111111111111111111111111111111"
  tree=$(current_tree)
  # First trailer is stale (wrong tree); second is the matching one.
  amend_with_trailers \
    "GAIA-Audit: 1.2.3 ${fake_tree}" \
    "GAIA-Audit: 1.2.3 ${tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=true
matched_version=1.2.3
matched_tree=${tree}
reason=trailer-matches"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 6. Two trailers, last one mismatches → skip=false
# -----------------------------------------------------------------------------

@test "two trailers, last one mismatches: skip=false (last wins, even when wrong)" {
  tree=$(current_tree)
  fake_tree="2222222222222222222222222222222222222222"
  # First trailer matches; second is stale. Last-wins → mismatch reported.
  amend_with_trailers \
    "GAIA-Audit: 1.2.3 ${tree}" \
    "GAIA-Audit: 1.2.3 ${fake_tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=1.2.3
matched_tree=${fake_tree}
reason=tree-mismatch"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 7. Malformed trailer (truncated tree-sha) is ignored as if absent
# -----------------------------------------------------------------------------

@test "malformed trailer (short sha) is ignored: skip=false reason=no-trailer" {
  # `git commit --trailer` would re-format the value but still write the
  # raw bytes; to guarantee a regex-non-conforming line in the message we
  # craft the body via `-m` directly.
  amend_with_raw_message "init

GAIA-Audit: 1.2.3 abc123
"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=no-trailer"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 8. .gaia/VERSION missing → skip=false reason=version-file-missing
# -----------------------------------------------------------------------------

@test ".gaia/VERSION missing: skip=false reason=version-file-missing" {
  rm "$SANDBOX/.gaia/VERSION"
  # Removing the file dirties the tree; commit so the script reads HEAD
  # cleanly. The current tree at that point no longer carries VERSION.
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "remove version"

  # Even if a stale matching trailer exists on this new HEAD, the
  # version-file-missing precondition trumps it (defensive default).
  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 1.2.3 ${tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=version-file-missing"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 9. .gaia/VERSION empty → also version-file-missing (defensive)
# -----------------------------------------------------------------------------

@test ".gaia/VERSION empty: skip=false reason=version-file-missing" {
  : > "$SANDBOX/.gaia/VERSION"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "blank version"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=version-file-missing"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 10. Status present + matching → skip=true reason=status-matches
# -----------------------------------------------------------------------------

@test "status present + matching → skip=true reason=status-matches" {
  tree=$(current_tree)
  install_gh_mock match "1.2.3 ${tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=true
matched_version=1.2.3
matched_tree=${tree}
reason=status-matches"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 11. Status present, version drift → skip=false reason=status-version-mismatch
# -----------------------------------------------------------------------------

@test "status present + version drift → skip=false reason=status-version-mismatch" {
  tree=$(current_tree)
  install_gh_mock verdrift "9.9.9 ${tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=9.9.9
matched_tree=${tree}
reason=status-version-mismatch"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 12. Status present, tree drift → skip=false reason=status-tree-mismatch
# -----------------------------------------------------------------------------

@test "status present + tree drift → skip=false reason=status-tree-mismatch" {
  fake_tree="0000000000000000000000000000000000000000"
  install_gh_mock treedrift "1.2.3 ${fake_tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=1.2.3
matched_tree=${fake_tree}
reason=status-tree-mismatch"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 13. Status API failure → skip=false reason=no-trailer (audit still runs)
# -----------------------------------------------------------------------------

@test "status API failure → skip=false reason=no-trailer (audit runs)" {
  install_gh_mock fail

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=no-trailer"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 14. No GAIA-Audit status on HEAD → skip=false reason=no-trailer
# -----------------------------------------------------------------------------

@test "no GAIA-Audit status on HEAD → skip=false reason=no-trailer" {
  install_gh_mock empty

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=no-trailer"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 15. Malformed status description (no tree token) → skip=false reason=no-trailer
# -----------------------------------------------------------------------------

@test "malformed status description (no tree token) → skip=false reason=no-trailer" {
  install_gh_mock match "1.2.3"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=no-trailer"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 16. Pending GAIA-Audit with matching version+tree does NOT skip
# -----------------------------------------------------------------------------

@test "status fallback: pending GAIA-Audit with matching version+tree does NOT skip" {
  tree=$(current_tree)
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"pending\",\"description\":\"1.2.3 ${tree}\"}]"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=no-trailer"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 17. Success GAIA-Audit with matching version+tree skips (no regression)
# -----------------------------------------------------------------------------

@test "status fallback: success GAIA-Audit with matching version+tree skips" {
  tree=$(current_tree)
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${tree}\"}]"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=true
matched_version=1.2.3
matched_tree=${tree}
reason=status-matches"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 18. Pending + success both present → success picked (skip=true)
# -----------------------------------------------------------------------------

@test "status fallback: pending+success both present picks success" {
  tree=$(current_tree)
  # Pending first, success last; both carry HEAD's version+tree. The
  # select-inside-map filter picks the success regardless of position.
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"pending\",\"description\":\"1.2.3 ${tree}\"},{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${tree}\"}]"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=true
matched_version=1.2.3
matched_tree=${tree}
reason=status-matches"
  [ "$output" = "$expected" ]
}
