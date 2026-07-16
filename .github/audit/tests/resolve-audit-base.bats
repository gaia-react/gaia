#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0 (RT-006 coverage below uses `run --separate-stderr`).
bats_require_minimum_version 1.5.0

# Tests for .github/audit/resolve-audit-base.sh.
#
# The helper is consumed by the code-review-audit CI workflow's "Resolve
# audit base" step and by the agent on local runs. It emits a single line:
# the most recent PR ancestor of HEAD that passed a clean audit under the
# current .gaia/VERSION (proven by a GAIA-Audit commit trailer or commit
# status), or the main ref for a full-scope fallback.
#
# The base is gated by VERSION MATCH ALONE: the trailer/status shared with
# check-trailer.sh is the three-field C3 form ("<version> <frontend-digest>
# <tree>"); only the version (field 1) is read here. Once a version-matching
# candidate is found, RT-006 additionally requires that no gate-machinery
# file changed between that candidate and HEAD (via the classifier +
# machinery libs, sourced from the checkout); if one did, the helper resets
# to the full-scope main ref instead of the candidate.
#
# Each test runs the script in an isolated `git init`'d temp dir whose HEAD
# sits on a FEATURE branch off `main`, so the merge-base bound leaves the
# branch's own commits walkable (committing straight on main would make
# merge-base == HEAD and the candidate list empty). The classifier +
# machinery libs are provisioned on disk (not committed -- RT-006 only
# needs them loadable, never as digest input) so the RT-006 check actually
# runs; a dedicated test removes them to exercise the fail-open fallback.
#
# The commit-status path is exercised by mocking `gh` on a prepended PATH
# (see install_gh_mock), keyed by commit SHA so a multi-commit walk can
# return different statuses per commit.
#
# Coverage:
#   1.  No signal anywhere                         → main ref (fallback)
#   2.  Trailer on parent, version matches         → that parent SHA
#   3.  Trailer on parent, version mismatch        → main ref
#   4.  Newest of several audited commits wins     → newest matching SHA
#   5.  Status on parent, version matches          → that parent SHA
#   6.  Status on parent, version mismatch         → main ref
#   7.  Trailer beats older status (newest wins)   → newer trailer SHA
#   8.  .gaia/VERSION missing                      → main ref
#   9.  .gaia/VERSION empty                        → main ref
#   10. HEAD's own trailer is never the base       → main ref
#   11. Single-commit PR (only HEAD)               → main ref
#   12. Malformed trailer (short digest) ignored   → main ref
#   13. gh absent / no token (status unreachable)  → main ref
#   14. Pending status on ancestor → not a usable base → main ref
#   15. Success status on ancestor → usable base       → ancestor SHA
#   16. RT-006: machinery change between base and HEAD → main ref (reset)
#   17. RT-006: no machinery change → candidate still returned
#   18. RT-006: libs unavailable → fail-open, version-only selection

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCRIPT="$THIS_DIR/../resolve-audit-base.sh"
  [ -x "$SCRIPT" ] || skip "resolve-audit-base.sh not executable"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"
  printf '1.2.3\n' > "$SANDBOX/.gaia/VERSION"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  # Base commit on main; the PR branch diverges from here.
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add .gaia/VERSION README.md
  git -C "$SANDBOX" commit --quiet -m "init"

  git -C "$SANDBOX" checkout --quiet -b feature

  # Provision the classifier + machinery libs on disk (RT-006's
  # emit_base_or_reset sources them from "$repo_root/.claude/hooks/lib/").
  # NOT committed: RT-006 only needs them loadable for the diff-classify
  # check, never as digest input (this script computes no digest).
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$SANDBOX/.claude/hooks/lib/audit-scope.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" "$SANDBOX/.claude/hooks/lib/audit-machinery.sh"

  # The trailer/status digest field (C3 field 2) is never compared by this
  # script (only the version, field 1, gates the base), so every fixture
  # uses this fixed 64-hex placeholder rather than a recomputed real digest.
  DIGEST="$(printf '%064d' 0)"
}

# Run the script with cwd inside the sandbox so its
# `git rev-parse --show-toplevel` lookup hits the fixture.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" )
}

# Add a commit on the feature branch. $1 = file content marker (also the
# commit subject), making each commit's tree distinct.
add_commit() {
  local marker="$1"
  echo "$marker" > "$SANDBOX/${marker}.txt"
  git -C "$SANDBOX" add "${marker}.txt"
  git -C "$SANDBOX" commit --quiet -m "$marker"
}

# Add a commit touching a gate-machinery path (matches the `.claude/rules/**`
# machinery prefix), for RT-006 coverage. Deliberately NOT a path any single
# member owns exclusively, so the rotation is attributable to machinery.
add_machinery_commit() {
  mkdir -p "$SANDBOX/.claude/rules"
  echo "rule" > "$SANDBOX/.claude/rules/new-rule.md"
  git -C "$SANDBOX" add .claude/rules/new-rule.md
  git -C "$SANDBOX" commit --quiet -m "machinery change"
}

# Amend the given commit-ish (default HEAD) with one GAIA-Audit trailer.
# Only HEAD can be amended cheaply; for older commits the tests amend at the
# time the commit is HEAD, before stacking further commits.
amend_head_with_trailer() {
  git -C "$SANDBOX" commit --amend --no-edit --no-verify \
    --trailer "$1" >/dev/null
}

# Append a raw message to HEAD (for malformed-shape coverage where
# `--trailer` would normalize the value).
amend_head_with_raw_message() {
  git -C "$SANDBOX" commit --amend --no-edit --no-verify -m "$1" >/dev/null
}

sha_of() {
  git -C "$SANDBOX" rev-parse "$1"
}

main_sha() {
  git -C "$SANDBOX" rev-parse main
}

# Install a fake `gh` keyed by the commit SHA in the requested API path.
# Writes a SHA→description map file; the mock greps the path for each SHA.
# Any SHA not in the map returns an empty array (no GAIA-Audit status).
# $@ = "sha=description" pairs.
install_gh_mock() {
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  MAP="$BATS_TEST_TMPDIR/gh-status-map"
  mkdir -p "$GH_BIN"
  : > "$MAP"
  for pair in "$@"; do
    printf '%s\n' "$pair" >> "$MAP"
  done
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
# Mock: resolve-audit-base calls
#   gh api repos/<repo>/commits/<sha>/statuses --jq '... | last | .description'
# We echo the mapped description for whichever SHA appears in the args.
args="\$*"
while IFS= read -r line; do
  sha="\${line%%=*}"
  desc="\${line#*=}"
  case "\$args" in
    *"\$sha"*) printf '%s\n' "\$desc"; exit 0 ;;
  esac
done < "$MAP"
# No GAIA-Audit status for this commit → the real --jq would yield null.
printf 'null\n'
exit 0
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
  export GH_TOKEN="fake-token"
  export GITHUB_REPOSITORY="gaia-react/gaia"
}

# Install a fake `gh` keyed by commit SHA that returns a full JSON statuses
# array and runs the script's real `--jq` against it, exercising the production
# state filter (map(select(... and .state == "success"))). The mock finds the
# SHA in its argv, looks up that SHA's crafted array, and pipes it through the
# real jq with the script's own --jq expression, so a pending status is filtered
# out exactly as the resolver filters it. A SHA with no mapped array yields the
# empty-array result (null), the resolver's "no status" path.
#   $@ = "sha=<json-array>" pairs.
install_gh_array_mock() {
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  MAP_DIR="$BATS_TEST_TMPDIR/gh-array-map"
  mkdir -p "$GH_BIN" "$MAP_DIR"
  for pair in "$@"; do
    sha="${pair%%=*}"
    payload="${pair#*=}"
    printf '%s' "$payload" > "$MAP_DIR/$sha"
  done
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
# Mock \`gh api repos/<repo>/commits/<sha>/statuses --jq <expr>\`: pull the SHA
# and the --jq expression from argv, then run the real jq against the crafted
# array mapped for that SHA (empty array when unmapped).
map_dir="$MAP_DIR"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
jq_expr=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then jq_expr="$a"; break; fi
  prev="$a"
done
[ -n "$jq_expr" ] || { printf 'null\n'; exit 0; }
payload="[]"
for f in "$map_dir"/*; do
  [ -e "$f" ] || continue
  sha="$(basename "$f")"
  case "$*" in
    *"$sha"*) payload="$(cat "$f")"; break ;;
  esac
done
printf '%s' "$payload" | jq -r "$jq_expr"
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
  export GH_TOKEN="fake-token"
  export GITHUB_REPOSITORY="gaia-react/gaia"
}

# -----------------------------------------------------------------------------
# 1. No signal anywhere → main ref
# -----------------------------------------------------------------------------

@test "no audit signal on any PR commit → main ref" {
  add_commit a
  add_commit b
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 2. Trailer on the parent, version matches → that parent SHA
# -----------------------------------------------------------------------------

@test "trailer on parent with matching version → parent SHA" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  base="$(sha_of HEAD)"
  add_commit b
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
}

# -----------------------------------------------------------------------------
# 3. Trailer on the parent, version mismatch → main ref (full re-audit)
# -----------------------------------------------------------------------------

@test "trailer on parent with version mismatch → main ref" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 9.9.9 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  add_commit b
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 4. Newest of several audited commits wins
# -----------------------------------------------------------------------------

@test "newest audited commit wins over an older audited commit" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  older="$(sha_of HEAD)"
  add_commit b
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  newer="$(sha_of HEAD)"
  add_commit c
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$newer" ]
  [ "$output" != "$older" ]
}

# -----------------------------------------------------------------------------
# 5. Commit status on the parent, version matches → that parent SHA
# -----------------------------------------------------------------------------

@test "status on parent with matching version → parent SHA" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  install_gh_mock "${base}=1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse "${base}^{tree}")"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
}

# -----------------------------------------------------------------------------
# 6. Commit status on the parent, version mismatch → main ref
# -----------------------------------------------------------------------------

@test "status on parent with version mismatch → main ref" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  install_gh_mock "${base}=9.9.9 ${DIGEST} $(git -C "$SANDBOX" rev-parse "${base}^{tree}")"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 7. Newest signal wins regardless of kind (trailer newer than status)
# -----------------------------------------------------------------------------

@test "newer trailer beats an older status" {
  add_commit a
  status_sha="$(sha_of HEAD)"
  add_commit b
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  trailer_sha="$(sha_of HEAD)"
  add_commit c
  install_gh_mock "${status_sha}=1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse "${status_sha}^{tree}")"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$trailer_sha" ]
}

# -----------------------------------------------------------------------------
# 8. .gaia/VERSION missing → main ref
# -----------------------------------------------------------------------------

@test ".gaia/VERSION missing → main ref" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  add_commit b
  rm "$SANDBOX/.gaia/VERSION"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "remove version"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 9. .gaia/VERSION empty → main ref
# -----------------------------------------------------------------------------

@test ".gaia/VERSION empty → main ref" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  add_commit b
  : > "$SANDBOX/.gaia/VERSION"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "blank version"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 10. A matching trailer on HEAD itself is never chosen as the base
# -----------------------------------------------------------------------------

@test "matching trailer on HEAD is not used as its own base" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 11. Single-commit PR (HEAD is the only commit past merge-base) → main ref
# -----------------------------------------------------------------------------

@test "single-commit PR → main ref" {
  add_commit a
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 12. Malformed trailer (truncated digest) is ignored as if absent
# -----------------------------------------------------------------------------

@test "malformed trailer (short digest) on parent is ignored → main ref" {
  add_commit a
  amend_head_with_raw_message "a

GAIA-Audit: 1.2.3 abc123 $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')
"
  add_commit b
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 13. No gh / no token → status unreachable, trailer-only → main ref
# -----------------------------------------------------------------------------

@test "no GH_TOKEN → status path skipped, no trailer → main ref" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  # A status exists in principle, but without GH_TOKEN the helper never
  # queries it; with no trailer either, it falls back to main.
  unset GH_TOKEN || true
  unset GITHUB_REPOSITORY || true
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 14. A pending GAIA-Audit status on an ancestor is not a usable base
# -----------------------------------------------------------------------------

@test "status base: pending GAIA-Audit ancestor is not a usable base" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  base_tree="$(git -C "$SANDBOX" rev-parse "${base}^{tree}")"
  # The ancestor carries a pending status with the current version+digest. The
  # state filter rejects it, so it is not picked; the walk falls to main.
  install_gh_array_mock \
    "${base}=[{\"context\":\"GAIA-Audit\",\"state\":\"pending\",\"description\":\"1.2.3 ${DIGEST} ${base_tree}\"}]"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 15. A success GAIA-Audit status on an ancestor IS a usable base
# -----------------------------------------------------------------------------

@test "status base: success GAIA-Audit ancestor is a usable base" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  base_tree="$(git -C "$SANDBOX" rev-parse "${base}^{tree}")"
  install_gh_array_mock \
    "${base}=[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${DIGEST} ${base_tree}\"}]"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
}

# -----------------------------------------------------------------------------
# 16. RT-006: a machinery change between the version-matching base and HEAD
# resets to full scope, so a pre-base machinery change (a different classifier
# ruleset) is never left unreviewed by an incremental <base>..HEAD diff.
# -----------------------------------------------------------------------------

@test "RT-006: a machinery change between the version-matching base and HEAD resets to full scope" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  add_machinery_commit

  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  grep -qF "machinery changed" <<<"$stderr"
}

# -----------------------------------------------------------------------------
# 17. RT-006 regression: an ordinary (non-machinery) follow-up commit does NOT
# trigger the reset; the version-matching candidate is still returned.
# -----------------------------------------------------------------------------

@test "RT-006: a non-machinery follow-up commit does not reset the base" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  base="$(sha_of HEAD)"
  add_commit b

  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
  grep -qF "machinery changed" <<<"$stderr" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# 18. RT-006 fail-open: when the classifier/machinery libs cannot be loaded,
# the base-reset check is skipped (logged, not silent) and the version-only
# candidate is still returned -- reviewing less, never denying a legitimate
# incremental base outright.
# -----------------------------------------------------------------------------

@test "RT-006: classifier/machinery libs unavailable falls back to version-only base selection" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  base="$(sha_of HEAD)"
  add_machinery_commit
  rm -f "$SANDBOX/.claude/hooks/lib/audit-scope.sh" "$SANDBOX/.claude/hooks/lib/audit-machinery.sh"

  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
  grep -qF "libs unavailable" <<<"$stderr"
}
