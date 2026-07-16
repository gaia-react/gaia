#!/usr/bin/env bats

# Tests for .github/audit/check-trailer.sh.
#
# The helper is consumed by the code-review-audit CI workflow's
# "Check audit trailer" step: stdout is piped into `>> $GITHUB_OUTPUT`.
# The trailer/status format is the frozen three-field contract C3:
# "<version> <frontend-digest> <tree>" (digest 64-hex, tree 40-hex). The
# script recomputes the frontend member's content digest (C1) through the
# classifier libs and compares it (and the version) against the parsed
# field; the tree field is data, never the compared validity key.
#
# Each test runs the script in an isolated `git init`'d temp dir so the
# script's `git rev-parse --show-toplevel` resolves to that fixture
# (and not the GAIA repo root, which already ships .gaia/VERSION), and
# provisions the digest engine (audit-digest.sh, audit-member-digest.sh) plus
# its classifier/machinery siblings on disk (not committed -- the digest
# walk hashes the sandbox's OWN tracked content, never the provisioning
# files) so the recompute the script performs actually resolves.
#
# The status fallback path is exercised by mocking `gh` on a prepended
# PATH (see `install_gh_mock`). It runs only when HEAD has no GAIA-Audit
# trailer, the default sandbox commit gives that state.
#
# Coverage:
#   1. No trailer present                          → skip=false reason=no-trailer
#   2. Trailer matches version + digest             → skip=true  reason=trailer-matches
#   3. Trailer matches version, digest mismatch     → skip=false reason=digest-mismatch
#   4. Trailer matches digest, version mismatch     → skip=false reason=version-mismatch
#   5. Two trailers, last one matches               → skip=true
#   6. Two trailers, last one mismatches             → skip=false
#   7. Malformed trailer (truncated digest)          → skip=false reason=no-trailer
#   8. .gaia/VERSION missing                         → skip=false reason=version-file-missing
#   9. .gaia/VERSION empty                           → skip=false reason=version-file-missing
#  10. Status present + matching                     → skip=true  reason=status-matches
#  11. Status present, version drift                 → skip=false reason=status-version-mismatch
#  12. Status present, digest drift                  → skip=false reason=status-digest-mismatch
#  13. Status API failure                            → skip=false reason=no-trailer
#  14. No GAIA-Audit status on HEAD                   → skip=false reason=no-trailer
#  15. Malformed status description                  → skip=false reason=no-trailer
#  16. Pending status, matching version+digest        → skip=false reason=no-trailer
#  17. Success status, matching version+digest        → skip=true  reason=status-matches
#  18. Newest = success, older failure present        → skip=true  (newest wins)
#  19. Newest = failure, older success present        → skip=false (newest shadows)
#  20. Out-of-glob change leaves the digest unchanged → skip=true still (UAT-014)
#  21. Digest recompute unavailable                   → skip=false reason=digest-recompute-failed

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
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

  # Provision the digest engine and its classifier/machinery siblings on
  # disk so the script's `bash .gaia/scripts/audit-member-digest.sh --root
  # "$repo_root" --member code-audit-frontend` recompute actually resolves.
  # NOT committed: the digest walk hashes the sandbox's own tracked content
  # (git ls-tree at HEAD), never these provisioning files, so leaving them
  # untracked keeps the fixture's input set exactly {.gaia/VERSION,
  # README.md} plus whatever a test commits.
  mkdir -p "$SANDBOX/.claude/hooks/lib" "$SANDBOX/.gaia/scripts"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$SANDBOX/.claude/hooks/lib/audit-scope.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" "$SANDBOX/.claude/hooks/lib/audit-machinery.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-digest.sh" "$SANDBOX/.claude/hooks/lib/audit-digest.sh"
  cp "$REPO_ROOT/.gaia/scripts/audit-member-digest.sh" "$SANDBOX/.gaia/scripts/audit-member-digest.sh"
  chmod +x "$SANDBOX/.gaia/scripts/audit-member-digest.sh"
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

# The frontend member's content digest (C1) at the sandbox's current HEAD,
# computed via the exact same CLI entrypoint check-trailer.sh calls
# internally, so a fabricated trailer/status embeds a value the script will
# actually recompute and match.
current_digest() {
  bash "$SANDBOX/.gaia/scripts/audit-member-digest.sh" \
    --root "$SANDBOX" --member code-audit-frontend
}

# A 64-hex digest that (with overwhelming probability) never matches a real
# digest, for mismatch fixtures. Built rather than hand-typed to avoid an
# off-by-one in a 64-character literal.
fake_digest_zeros() { printf '%064d' 0; }
fake_digest_ones() { printf '%064d' 0 | tr '0' '1'; }

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
# newest-per-context filter (map(select(.context == ...)) | first | select(.state
# == "success")), so the test sees exactly what the reader sees: the array's
# FIRST entry (the list is newest-first) is the only one considered, and it
# must itself be state:success, an older success elsewhere in the array never
# rescues a newer non-success entry. The mock parses its own argv for the
# value following `--jq` and pipes the crafted array through the real jq.
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
# 2. Trailer matches version + digest
# -----------------------------------------------------------------------------

@test "trailer matches version + digest: skip=true reason=trailer-matches" {
  digest=$(current_digest)
  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 1.2.3 ${digest} ${tree}"

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
# 3. Trailer version matches, digest mismatch
# -----------------------------------------------------------------------------

@test "trailer version match + digest mismatch: skip=false reason=digest-mismatch" {
  fake_digest="$(fake_digest_zeros)"
  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 1.2.3 ${fake_digest} ${tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=1.2.3
matched_tree=${tree}
reason=digest-mismatch"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 4. Trailer digest matches, version mismatch
# -----------------------------------------------------------------------------

@test "trailer digest match + version mismatch: skip=false reason=version-mismatch" {
  digest=$(current_digest)
  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 9.9.9 ${digest} ${tree}"

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
  fake_digest="$(fake_digest_ones)"
  digest=$(current_digest)
  tree=$(current_tree)
  # First trailer is stale (wrong digest); second is the matching one.
  amend_with_trailers \
    "GAIA-Audit: 1.2.3 ${fake_digest} ${tree}" \
    "GAIA-Audit: 1.2.3 ${digest} ${tree}"
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
# 6. Two trailers, last one mismatches → skip=false
# -----------------------------------------------------------------------------

@test "two trailers, last one mismatches: skip=false (last wins, even when wrong)" {
  digest=$(current_digest)
  tree=$(current_tree)
  fake_digest="$(fake_digest_ones)"
  # First trailer matches; second is stale. Last-wins → mismatch reported.
  amend_with_trailers \
    "GAIA-Audit: 1.2.3 ${digest} ${tree}" \
    "GAIA-Audit: 1.2.3 ${fake_digest} ${tree}"
  tree=$(current_tree)

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=1.2.3
matched_tree=${tree}
reason=digest-mismatch"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 7. Malformed trailer (truncated digest) is ignored as if absent
# -----------------------------------------------------------------------------

@test "malformed trailer (short digest) is ignored: skip=false reason=no-trailer" {
  # `git commit --trailer` would re-format the value but still write the
  # raw bytes; to guarantee a regex-non-conforming line in the message we
  # craft the body via `-m` directly.
  amend_with_raw_message "init

GAIA-Audit: 1.2.3 abc123 0000000000000000000000000000000000000000
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
  digest=$(current_digest)
  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 1.2.3 ${digest} ${tree}"

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
  digest=$(current_digest)
  tree=$(current_tree)
  install_gh_mock match "1.2.3 ${digest} ${tree}"

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
  digest=$(current_digest)
  tree=$(current_tree)
  install_gh_mock verdrift "9.9.9 ${digest} ${tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=9.9.9
matched_tree=${tree}
reason=status-version-mismatch"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 12. Status present, digest drift → skip=false reason=status-digest-mismatch
# -----------------------------------------------------------------------------

@test "status present + digest drift → skip=false reason=status-digest-mismatch" {
  fake_digest="$(fake_digest_zeros)"
  tree=$(current_tree)
  install_gh_mock digestdrift "1.2.3 ${fake_digest} ${tree}"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=1.2.3
matched_tree=${tree}
reason=status-digest-mismatch"
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
# 15. Malformed status description (no digest/tree tokens) → skip=false reason=no-trailer
# -----------------------------------------------------------------------------

@test "malformed status description (no digest/tree tokens) → skip=false reason=no-trailer" {
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
# 16. Pending GAIA-Audit with matching version+digest does NOT skip
# -----------------------------------------------------------------------------

@test "status fallback: pending GAIA-Audit with matching version+digest does NOT skip" {
  digest=$(current_digest)
  tree=$(current_tree)
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"pending\",\"description\":\"1.2.3 ${digest} ${tree}\"}]"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=no-trailer"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 17. Success GAIA-Audit with matching version+digest skips (no regression)
# -----------------------------------------------------------------------------

@test "status fallback: success GAIA-Audit with matching version+digest skips" {
  digest=$(current_digest)
  tree=$(current_tree)
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${digest} ${tree}\"}]"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=true
matched_version=1.2.3
matched_tree=${tree}
reason=status-matches"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 18. Newest = success, older failure present → skip=true (newest wins)
# -----------------------------------------------------------------------------

@test "status fallback: newest success with older failure present skips" {
  digest=$(current_digest)
  tree=$(current_tree)
  # Array is newest-first: the failure is older (listed second), the
  # matching success is newest (listed first). The newest entry is
  # state:success, so it clears the audit.
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${digest} ${tree}\"},{\"context\":\"GAIA-Audit\",\"state\":\"failure\",\"description\":\"1.2.3 ${digest} ${tree}\"}]"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=true
matched_version=1.2.3
matched_tree=${tree}
reason=status-matches"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 19. Newest = failure/pending, older success present → skip=false (shadowed)
# -----------------------------------------------------------------------------

@test "status fallback: newest failure with older success present does NOT skip" {
  digest=$(current_digest)
  tree=$(current_tree)
  # Array is newest-first: the failure is newest (listed first), the
  # matching success is older (listed second). A newer non-success entry
  # shadows the older success; the audit is NOT skipped.
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"failure\",\"description\":\"1.2.3 ${digest} ${tree}\"},{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${digest} ${tree}\"}]"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=no-trailer"
  [ "$output" = "$expected" ]
}

# -----------------------------------------------------------------------------
# 20. UAT-014: an out-of-glob-only change leaves the frontend digest
# unchanged, so a trailer carrying that still-current digest skips even
# though HEAD's tree (data only) no longer matches what it was when the
# digest was first computed.
# -----------------------------------------------------------------------------

@test "out-of-glob change leaves the frontend digest unchanged: skip=true still resolves" {
  digest_before="$(current_digest)"

  # README.md is out-of-scope-allowlisted (a root *.md file), not machinery,
  # and not in the frontend's auditable-base set, so it is excluded from the
  # frontend digest's input set entirely; only .gaia/VERSION (machinery)
  # contributes. Editing it rotates the tree but must NOT rotate the digest.
  echo "docs change" >> "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit --quiet -m "docs: out-of-glob change"

  digest_after="$(current_digest)"
  [ "$digest_after" = "$digest_before" ]

  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 1.2.3 ${digest_after} ${tree}"
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
# 21. RT-007/CPL-004: the digest cannot be recomputed (classifier lib
# unavailable) → fail-open toward re-audit, never a false skip.
# -----------------------------------------------------------------------------

@test "digest recompute unavailable: skip=false reason=digest-recompute-failed" {
  digest=$(current_digest)
  tree=$(current_tree)
  amend_with_trailers "GAIA-Audit: 1.2.3 ${digest} ${tree}"
  tree=$(current_tree)
  rm -f "$SANDBOX/.gaia/scripts/audit-member-digest.sh"

  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="skip=false
matched_version=
matched_tree=
reason=digest-recompute-failed"
  [ "$output" = "$expected" ]
}
