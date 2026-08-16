#!/usr/bin/env bats
#
# Every test uses `run --separate-stderr`: the resolver writes one decision
# line to stderr on every path, and bats' plain `run` folds stderr into
# $output.
bats_require_minimum_version 1.5.0

# Tests for .github/audit/resolve-audit-base.sh.
#
# The helper is consumed by the code-review-audit CI workflow's "Resolve
# audit base" step, by the merge-time findings hook, and by the Code Audit
# Team's agent definitions on local runs. Two invocation forms:
#
#   argument-less   ONE stdout line: the most recent PR ancestor of HEAD that
#                   passed a clean whole-team audit under the current
#                   .gaia/VERSION (proven by a GAIA-Audit commit trailer or
#                   commit status), or the main ref for a full-scope fallback.
#   --member <name> FOUR stdout lines: the per-member review base, the reason
#                   token, the shared pull-request-wide base (byte-identical
#                   to what the argument-less form prints on the same
#                   fixture), and the recorded tree of the clearance that
#                   anchored the answer.
#
# The base is gated by VERSION MATCH ALONE on both anchor arms: the
# trailer/status shared with check-trailer.sh is the three-field C3 form
# ("<version> <frontend-digest> <tree>"), of which only the version (field 1)
# is read here, and a per-member clearance is usable only when its recorded
# version equals the current one. Once an anchor is found, the delta between
# it and HEAD decides whether it survives: the argument-less form applies the
# flat machinery test (RT-006), the --member form applies the two-tier rules
# test (global rules reset every member, a member's own agent definition
# resets only that member, merely-shared machinery resets nobody).
#
# Each test runs the script in an isolated `git init`'d temp dir whose HEAD
# sits on a FEATURE branch off `main`, so the merge-base bound leaves the
# branch's own commits walkable (committing straight on main would make
# merge-base == HEAD and the candidate list empty). The four predicate libs
# are provisioned on disk (not committed -- the resolver only needs them
# loadable, never as digest input); their absence now DECIDES the answer, so
# dedicated tests remove them one at a time.
#
# The commit-status path is exercised by mocking `gh` on a prepended PATH
# (see install_gh_mock), keyed by commit SHA so a multi-commit walk can
# return different statuses per commit.
#
# Reason-token reachability lives in its own section at the foot of the file:
# one test per token in the closed set of eight.
#

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

  # The clearance store is gitignored in a real checkout; keep it out of the
  # index here too, so a fixture's `git add -A` cannot commit a marker and
  # turn the store into diff content.
  mkdir -p "$SANDBOX/.git/info"
  printf '.gaia/local/\n' > "$SANDBOX/.git/info/exclude"

  # Base commit on main; the PR branch diverges from here.
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add .gaia/VERSION README.md
  git -C "$SANDBOX" commit --quiet -m "init"

  git -C "$SANDBOX" checkout --quiet -b feature

  # Provision the predicate libs on disk (the resolver sources them from
  # "$repo_root/.claude/hooks/lib/"). NOT committed: they only have to be
  # loadable, never digest input (this script computes no digest). All five
  # are provisioned because all five now decide the answer: without the
  # classifier, the machinery matcher, the rules-tier predicate or the version
  # normalizer the resolver resets to full scope, and without the clearance
  # reader the per-member anchor arm is disabled.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$SANDBOX/.claude/hooks/lib/audit-scope.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" "$SANDBOX/.claude/hooks/lib/audit-machinery.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh" "$SANDBOX/.claude/hooks/lib/audit-rules-changed.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-clearance.sh" "$SANDBOX/.claude/hooks/lib/audit-clearance.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-version.sh" "$SANDBOX/.claude/hooks/lib/gaia-version.sh"

  # The trailer/status digest field (C3 field 2) is never compared by this
  # script (only the version, field 1, gates the base), so every fixture
  # uses this fixed 64-hex placeholder rather than a recomputed real digest.
  DIGEST="$(printf '%064d' 0)"

  # The clearance reader gives the default member the infix-free filename
  # family and every other member a ".<member>" infix, so fixtures need one
  # of each.
  DEFAULT_MEMBER="code-audit-frontend"
  OTHER_MEMBER="code-audit-maintainer-shell"

  MEMBER_OUT="$BATS_TEST_TMPDIR/member.out"
  CLEARANCE_SEQ=0
}

# Run the script with cwd inside the sandbox so its
# `git rev-parse --show-toplevel` lookup hits the fixture.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" )
}

# Run the --member form with stdout captured to a FILE. bats strips trailing
# newlines from $output, so a four-line output whose fourth line is empty (the
# normal case for every reason but member-clearance) shows up there as three
# lines and a shape assertion written against $output passes vacuously.
# Stderr still flows to bats, so `run --separate-stderr run_member <name>`
# fills $stderr and $status as usual.
run_member() {
  ( cd "$SANDBOX" && "$SCRIPT" --member "$1" ) > "$MEMBER_OUT"
}

# Field accessors over the filed stdout of the last run_member call.
m_base() { sed -n 1p "$MEMBER_OUT"; }
m_reason() { sed -n 2p "$MEMBER_OUT"; }
m_key() { sed -n 3p "$MEMBER_OUT"; }
m_tree() { sed -n 4p "$MEMBER_OUT"; }
m_lines() { wc -l < "$MEMBER_OUT" | tr -d ' '; }

require_jq() {
  command -v jq >/dev/null 2>&1 || skip "jq not available (the clearance reader requires it)"
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
# member owns exclusively, so the rotation is attributable to machinery. The
# path is merely-shared rather than global, which is what the flat machinery
# arm wants: a global path would trip both arms and stop isolating this one.
add_machinery_commit() {
  mkdir -p "$SANDBOX/.claude/rules"
  echo "rule" > "$SANDBOX/.claude/rules/new-rule.md"
  git -C "$SANDBOX" add .claude/rules/new-rule.md
  git -C "$SANDBOX" commit --quiet -m "machinery change"
}

# Add a commit touching a GLOBAL-tier path, for the per-member reset arm.
add_global_rules_commit() {
  mkdir -p "$SANDBOX/.claude/rules"
  echo "gate rule" > "$SANDBOX/.claude/rules/quality-gate.md"
  git -C "$SANDBOX" add .claude/rules/quality-gate.md
  git -C "$SANDBOX" commit --quiet -m "global rules change"
}

# Add a machinery commit whose PATH carries a non-ASCII byte. Under git's
# default core.quotePath, `git diff --name-only` C-quotes such a path: it wraps
# the token in literal double quotes and backslash-escapes the offending bytes,
# and `audit_delta_has_machinery` matches its prefixes literally, so a quoted
# token prefix-matches nothing and the reset silently does not fire. Same
# machinery prefix as add_machinery_commit, so the two differ in the path's
# bytes and nothing else.
add_non_ascii_machinery_commit() {
  mkdir -p "$SANDBOX/.claude/rules"
  echo "rule" > "$SANDBOX/.claude/rules/règle.md"
  git -C "$SANDBOX" add ".claude/rules/règle.md"
  git -C "$SANDBOX" commit --quiet -m "machinery change on a non-ASCII path"
}

# Commit an APPEND to <path>. Appending rather than rewriting is load-bearing
# for two of the fixtures: .gaia/VERSION must keep its version line first (the
# resolver reads the first non-empty line, and a rewritten file would make the
# current version disagree with the anchor's recorded one, so the walk would
# find no candidate and the reason under test would never be reached), and the
# provisioned libs must stay sourceable or the run degrades instead.
commit_append() {
  local path="$1"
  mkdir -p "$(dirname "$SANDBOX/$path")"
  printf '\n# touched\n' >> "$SANDBOX/$path"
  git -C "$SANDBOX" add "$path"
  git -C "$SANDBOX" commit --quiet -m "touch $path"
}

# Amend the given commit-ish (default HEAD) with one GAIA-Audit trailer.
# Only HEAD can be amended cheaply; for older commits the tests amend at the
# time the commit is HEAD, before stacking further commits.
amend_head_with_trailer() {
  git -C "$SANDBOX" commit --amend --no-edit --no-verify \
    --trailer "$1" >/dev/null
}

# Stamp HEAD with a version-matching whole-team trailer and echo its sha: the
# clean-round anchor most fixtures below build from.
stamp_anchor() {
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  sha_of HEAD
}

# Append a raw message to HEAD (for malformed-shape coverage where
# `--trailer` would normalize the value).
amend_head_with_raw_message() {
  git -C "$SANDBOX" commit --amend --no-edit --no-verify -m "$1" >/dev/null
}

sha_of() {
  git -C "$SANDBOX" rev-parse "$1"
}

tree_of() {
  git -C "$SANDBOX" rev-parse "${1}^{tree}"
}

main_sha() {
  git -C "$SANDBOX" rev-parse main
}

# Write a writer-shaped clearance record into the sandbox's local audit store.
#   $1 member   $2 provenance (earned|refused)   $3 recorded tree
#   $4 recorded version (irrelevant for a refusal, which is version-blind)
# The digest is a per-call counter padded to the writer's 64-hex width: the
# reader only requires the body's digest to equal the filename stem, so a
# printf-built value keeps this off `shasum`, whose flags differ between BSD
# and GNU. The recorded sha is deliberately whatever HEAD is at write time,
# because the anchor is matched on the tree and never on the sha.
write_clearance() {
  local member="$1" provenance="$2" tree="$3" version="$4" ext digest name dir
  dir="$SANDBOX/.gaia/local/audit"
  mkdir -p "$dir"
  CLEARANCE_SEQ=$(( CLEARANCE_SEQ + 1 ))
  digest="$(printf '%064d' "$CLEARANCE_SEQ")"
  case "$provenance" in
    earned) ext="ok" ;;
    *) ext="refused" ;;
  esac
  if [ "$member" = "$DEFAULT_MEMBER" ]; then
    name="${digest}.${ext}"
  else
    name="${digest}.${member}.${ext}"
  fi
  printf '{"version":"%s","schema":4,"member":"%s","provenance":"%s","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z"}\n' \
    "$version" "$member" "$provenance" "$digest" "$tree" "$(sha_of HEAD)" \
    > "$dir/$name"
  printf '%s\n' "$dir/$name"
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

# =============================================================================
# The argument-less form. Its resolution is unchanged by the per-member layer
# on every input except the degraded arm, which inverted deliberately.
# =============================================================================

@test "no audit signal on any PR commit → main ref" {
  add_commit a
  add_commit b
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# Which ref the full-scope fallback names. A pull request stacked on a branch
# other than the default one must fall back to ITS OWN base, not to the
# repository default: falling back to the default hands the audit the base
# branch's entire divergence as if this pull request had introduced it, and
# findings raised against that history are indistinguishable, in the member's
# output, from findings against the pull request's own code
# (gaia-react/gaia#1057).
#
# `git init` leaves the sandbox with no remote at all, which is why every other
# test here sees the bare local `main`. These write remote-tracking refs by
# hand so an `origin/<ref>` can resolve.
# -----------------------------------------------------------------------------

set_origin_ref() {
  git -C "$SANDBOX" update-ref "refs/remotes/origin/$1" "$(git -C "$SANDBOX" rev-parse "$2")"
}

@test "the pull request's own base ref wins over the repository default" {
  add_commit a
  add_commit b
  set_origin_ref main main
  set_origin_ref release main
  export GITHUB_BASE_REF=release
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "origin/release" ]
}

@test "no base ref declared → the repository default" {
  add_commit a
  add_commit b
  set_origin_ref main main
  unset GITHUB_BASE_REF
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]
}

@test "a base ref naming no remote branch → the repository default" {
  add_commit a
  add_commit b
  set_origin_ref main main
  export GITHUB_BASE_REF=deleted-branch
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]
}

@test "trailer on parent with matching version → parent SHA" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  base="$(sha_of HEAD)"
  add_commit b
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
}

@test "trailer on parent with version mismatch → main ref" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 9.9.9 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  add_commit b
  run --separate-stderr run_in_sandbox
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
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$newer" ]
  [ "$output" != "$older" ]
}

@test "status on parent with matching version → parent SHA" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  install_gh_mock "${base}=1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse "${base}^{tree}")"
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
}

@test "status on parent with version mismatch → main ref" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  install_gh_mock "${base}=9.9.9 ${DIGEST} $(git -C "$SANDBOX" rev-parse "${base}^{tree}")"
  run --separate-stderr run_in_sandbox
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
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$trailer_sha" ]
}

@test ".gaia/VERSION missing → main ref" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  add_commit b
  rm "$SANDBOX/.gaia/VERSION"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "remove version"
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test ".gaia/VERSION empty → main ref" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  add_commit b
  : > "$SANDBOX/.gaia/VERSION"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "blank version"
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "matching trailer on HEAD is not used as its own base" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 11. Single-commit PR (HEAD is the only commit past merge-base) → main ref
# -----------------------------------------------------------------------------

@test "single-commit PR → main ref" {
  add_commit a
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "malformed trailer (short digest) on parent is ignored → main ref" {
  add_commit a
  amend_head_with_raw_message "a

GAIA-Audit: 1.2.3 abc123 $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')
"
  add_commit b
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "no GH_TOKEN → status path skipped, no trailer → main ref" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  # A status exists in principle, but without GH_TOKEN the helper never
  # queries it; with no trailer either, it falls back to main.
  unset GH_TOKEN || true
  unset GITHUB_REPOSITORY || true
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "status base: pending GAIA-Audit ancestor is not a usable base" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  base_tree="$(git -C "$SANDBOX" rev-parse "${base}^{tree}")"
  # The ancestor carries a pending status with the current version+digest. The
  # state filter rejects it, so it is not picked; the walk falls to main.
  install_gh_array_mock \
    "${base}=[{\"context\":\"GAIA-Audit\",\"state\":\"pending\",\"description\":\"1.2.3 ${DIGEST} ${base_tree}\"}]"
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "status base: success GAIA-Audit ancestor is a usable base" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  base_tree="$(git -C "$SANDBOX" rev-parse "${base}^{tree}")"
  install_gh_array_mock \
    "${base}=[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${DIGEST} ${base_tree}\"}]"
  run --separate-stderr run_in_sandbox
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
# 18. The fail direction INVERTED. This arm used to skip the base-reset check
# and return the version-only candidate (fail-open toward reviewing LESS). It
# now resets to full scope: with the predicate libs unloadable neither reset
# tier can be evaluated, so the anchor's soundness for the resolving member
# cannot be established at all, and the merge gate already denies outright on
# the same input.
# -----------------------------------------------------------------------------

@test "classifier/machinery libs unavailable resets to full scope" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  base="$(sha_of HEAD)"
  add_machinery_commit
  rm -f "$SANDBOX/.claude/hooks/lib/audit-scope.sh" \
    "$SANDBOX/.claude/hooks/lib/audit-machinery.sh" \
    "$SANDBOX/.claude/hooks/lib/audit-rules-changed.sh"

  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ "$output" != "$base" ]
  grep -qF "libs unavailable" <<<"$stderr"
}

# -----------------------------------------------------------------------------
# 19. RT-006 encoding: the reset fires for a machinery path carrying non-ASCII
# bytes, exactly as it does for test 16's ASCII one. The classifier reads the
# names `git diff` prints, so letting git C-quote them turns a machinery change
# into a machinery-free delta -- and a delta with no machinery in it is the
# ordinary case, so nothing anywhere reports that the reset was skipped. This
# is the encoding half of test 16, which the ASCII path cannot reach.
# -----------------------------------------------------------------------------

@test "RT-006: a machinery change on a non-ASCII path resets to full scope" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(git -C "$SANDBOX" rev-parse 'HEAD^{tree}')"
  add_non_ascii_machinery_commit

  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  grep -qF "machinery changed" <<<"$stderr"
}

# =============================================================================
# The per-member form: a second anchor arm over the same walk.
# =============================================================================

@test "two members resolve different bases from the same invocation shape" {
  require_jq
  add_commit a
  c1="$(stamp_anchor)"
  add_commit b
  c2="$(sha_of HEAD)"
  c2_tree="$(tree_of HEAD)"
  write_clearance "$OTHER_MEMBER" earned "$c2_tree" 1.2.3 >/dev/null
  add_commit c

  # The member holding a clearance at C2 anchors there, though no whole-team
  # signal ever certified C2 (a sibling was pending in that round).
  run --separate-stderr run_member "$OTHER_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_lines)" -eq 4 ]
  [ "$(m_base)" = "$c2" ]
  [ "$(m_reason)" = "member-clearance" ]
  [ "$(m_tree)" = "$c2_tree" ]

  # A member holding no clearance newer than C1 falls back to the floor.
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_lines)" -eq 4 ]
  [ "$(m_base)" = "$c1" ]
  [ "$(m_reason)" = "team-signal" ]
  [ -z "$(m_tree)" ]
}

@test "a member clearance newer than the whole-team signal wins the walk" {
  require_jq
  add_commit a
  c1="$(stamp_anchor)"
  add_commit b
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  c2="$(sha_of HEAD)"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$c2" ]
  [ "$(m_base)" != "$c1" ]
  [ "$(m_reason)" = "member-clearance" ]
}

@test "a whole-team signal newer than the member clearance wins the walk" {
  require_jq
  add_commit a
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  c1="$(sha_of HEAD)"
  add_commit b
  c2="$(stamp_anchor)"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$c2" ]
  [ "$(m_base)" != "$c1" ]
  [ "$(m_reason)" = "team-signal" ]
}

# -----------------------------------------------------------------------------
# The global tier: one commit touching one global-rules path between the anchor
# and HEAD resets every member. Four representative paths, one fixture each,
# because a delta accumulates: a second path tested in the same fixture would
# be masked by the first.
# -----------------------------------------------------------------------------

# Stamp an anchor, commit an append to <path>, and assert the member form reset
# globally and named the path.
assert_global_reset_for() {
  local path="$1" base
  add_commit a
  base="$(stamp_anchor)"
  commit_append "$path"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ] || return 1
  [ "$(m_lines)" -eq 4 ] || return 1
  [ "$(m_base)" = "main" ] || return 1
  [ "$(m_base)" != "$base" ] || return 1
  [ "$(m_reason)" = "rules-reset-global" ] || return 1
  [ -z "$(m_tree)" ] || return 1
  grep -qF "$path" <<<"$stderr" || return 1
  return 0
}

@test "global tier: a gate-governing rule change resets the member" {
  assert_global_reset_for ".claude/rules/quality-gate.md"
}

@test "global tier: an ownership classifier change resets the member" {
  assert_global_reset_for ".claude/hooks/lib/audit-scope.sh"
}

@test "global tier: a base resolver change resets the member" {
  assert_global_reset_for ".github/audit/resolve-audit-base.sh"
}

@test "global tier: a version file change resets the member" {
  assert_global_reset_for ".gaia/VERSION"
}

# -----------------------------------------------------------------------------
# The member tier and the merely-shared carve-out.
# -----------------------------------------------------------------------------

@test "member tier: a member's own agent definition resets only that member" {
  add_commit a
  base="$(stamp_anchor)"
  commit_append ".claude/agents/${DEFAULT_MEMBER}.md"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "main" ]
  [ "$(m_reason)" = "rules-reset-member" ]
  grep -qF ".claude/agents/${DEFAULT_MEMBER}.md" <<<"$stderr"

  run --separate-stderr run_member "$OTHER_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$base" ]
  [ "$(m_reason)" = "team-signal" ]
}

@test "merely-shared machinery resets nobody in the member form" {
  add_commit a
  base="$(stamp_anchor)"
  commit_append ".claude/hooks/local-janitor.sh"
  commit_append ".github/workflows/code-review-audit.yml"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$base" ]
  [ "$(m_reason)" = "team-signal" ]

  # The same delta legitimately resets the SHARED key base, which keeps the
  # flat machinery test. Lines 1 and 3 diverging is what the two-base split is
  # for, not a defect.
  [ "$(m_key)" = "main" ]
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ "$output" = "$(m_key)" ]
}

# A coding-convention rule is machinery, so it still rotates every digest and
# still resets the shared base; what it must NOT do is discard a member's
# incremental anchor. Held global, this one path re-scoped the entire roster to
# full review on any convention edit, which is the cost that made rule edits
# get deferred rather than made.
@test "a coding-convention rule under .claude/rules/ resets nobody in the member form" {
  add_commit a
  base="$(stamp_anchor)"
  commit_append ".claude/rules/tailwind.md"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$base" ]
  [ "$(m_reason)" = "team-signal" ]
  grep -qF "rules-reset-global" <<<"$stderr" && return 1

  run --separate-stderr run_member "$OTHER_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$base" ]
  [ "$(m_reason)" = "team-signal" ]
}

# -----------------------------------------------------------------------------
# Both signal arms drive the reset. Only the trailer arm was covered before, so
# the status arm could have regressed with the suite green.
# -----------------------------------------------------------------------------

@test "the reset fires on the commit-status arm exactly as on the trailer arm" {
  add_commit a
  base="$(sha_of HEAD)"
  base_tree="$(tree_of HEAD)"
  install_gh_array_mock \
    "${base}=[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${DIGEST} ${base_tree}\"}]"
  commit_append ".claude/rules/quality-gate.md"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "main" ]
  [ "$(m_base)" != "$base" ]
  [ "$(m_reason)" = "rules-reset-global" ]
  grep -qF ".claude/rules/quality-gate.md" <<<"$stderr"
}

@test "the status arm anchors the member form when no trailer exists" {
  add_commit a
  base="$(sha_of HEAD)"
  base_tree="$(tree_of HEAD)"
  add_commit b
  install_gh_array_mock \
    "${base}=[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${DIGEST} ${base_tree}\"}]"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$base" ]
  [ "$(m_reason)" = "team-signal" ]
}

# -----------------------------------------------------------------------------
# The four ways a clearance is unusable. Each falls back to the newest usable
# whole-team signal, or to the main ref when there is none, and never emits the
# candidate the unusable clearance points at.
# -----------------------------------------------------------------------------

@test "unusable clearance: a stale recorded version is not an anchor" {
  require_jq
  add_commit a
  c1="$(stamp_anchor)"
  add_commit b
  c2="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 9.9.9 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$c1" ]
  [ "$(m_base)" != "$c2" ]
  [ "$(m_reason)" = "team-signal" ]
}

@test "unusable clearance: a recorded tree matching no candidate is not an anchor" {
  require_jq
  add_commit a
  c1="$(stamp_anchor)"
  add_commit b
  c2="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(printf '%040d' 7)" 1.2.3 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$c1" ]
  [ "$(m_base)" != "$c2" ]
  [ "$(m_reason)" = "team-signal" ]
}

@test "unusable clearance: a pruned record is not an anchor" {
  require_jq
  add_commit a
  c1="$(stamp_anchor)"
  add_commit b
  c2="$(sha_of HEAD)"
  marker="$(write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3)"
  rm -f "$marker"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$c1" ]
  [ "$(m_base)" != "$c2" ]
  [ "$(m_reason)" = "team-signal" ]
}

@test "unusable clearance: no whole-team signal in range yields the main ref" {
  require_jq
  add_commit a
  add_commit b
  c2="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 9.9.9 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "main" ]
  [ "$(m_base)" != "$c2" ]
  [ "$(m_reason)" = "no-anchor" ]
}

@test "another member's clearance is not readable as this member's anchor" {
  require_jq
  add_commit a
  add_commit b
  c2="$(sha_of HEAD)"
  write_clearance "$OTHER_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "main" ]
  [ "$(m_base)" != "$c2" ]
  [ "$(m_reason)" = "no-anchor" ]
}

# -----------------------------------------------------------------------------
# The clean-round stamp amends HEAD, rewriting the sha a moments-old clearance
# recorded while preserving the tree. Matching on the tree is what survives it.
# -----------------------------------------------------------------------------

@test "a clearance still anchors after an amend rewrites the commit sha" {
  require_jq
  add_commit a
  c1="$(stamp_anchor)"
  add_commit b
  c2_before="$(sha_of HEAD)"
  c2_tree="$(tree_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$c2_tree" 1.2.3 >/dev/null
  GIT_COMMITTER_DATE="2026-01-02T00:00:00" git -C "$SANDBOX" commit \
    --amend --no-edit --no-verify --date="2026-01-02T00:00:00" >/dev/null
  c2_after="$(sha_of HEAD)"
  # The fixture is only meaningful if the amend really moved the sha.
  [ "$c2_after" != "$c2_before" ]
  [ "$(tree_of HEAD)" = "$c2_tree" ]
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$c2_after" ]
  [ "$(m_base)" != "$c1" ]
  [ "$(m_reason)" = "member-clearance" ]
  [ "$(m_tree)" = "$c2_tree" ]
}

# -----------------------------------------------------------------------------
# Refusal precedence. A member can neither anchor on content it refused nor
# anchor past that refusal, so the refusal is a whole-range pre-scan rather
# than a per-candidate test: the walk meets the newer earned clearance first.
# -----------------------------------------------------------------------------

@test "a refusal in range disables the member arm entirely" {
  require_jq
  add_commit a
  c1="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" refused "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit b
  c2="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "main" ]
  [ "$(m_base)" != "$c1" ]
  [ "$(m_base)" != "$c2" ]
  [ "$(m_reason)" = "no-anchor" ]
  grep -qF "refused content" <<<"$stderr"
}

# The whole-team floor is deliberately NOT disabled by a refusal, and this
# probe pins that as decided rather than accidental. The trailer and the status
# are each stamped only when no dispatched member is pending, and a member
# holding a live refusal IS pending, so a whole-team signal at or newer than
# the refused commit is evidence the refusal was already resolved (superseded
# by its author, or retired by a digest rotation).
@test "a whole-team signal newer than a refusal still anchors the member" {
  require_jq
  add_commit a
  write_clearance "$DEFAULT_MEMBER" refused "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit b
  c2="$(stamp_anchor)"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$c2" ]
  [ "$(m_reason)" = "team-signal" ]
  [ -z "$(m_tree)" ]
}

# -----------------------------------------------------------------------------
# Library availability. Four libs decide the answer and their absence resets
# to full scope; the clearance reader's absence is the CONTRAST, because it is
# the same condition as the empty store every continuous-integration run has.
# -----------------------------------------------------------------------------

# Remove one provisioned lib, then assert the member form degraded rather than
# emitting the candidate it would otherwise have anchored on.
assert_degraded_without() {
  local lib="$1" base
  add_commit a
  base="$(stamp_anchor)"
  add_commit b
  rm -f "$SANDBOX/.claude/hooks/lib/${lib}"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ] || return 1
  [ "$(m_lines)" -eq 4 ] || return 1
  [ "$(m_base)" = "main" ] || return 1
  [ "$(m_base)" != "$base" ] || return 1
  [ "$(m_reason)" = "degraded" ] || return 1
  [ "$(m_key)" = "main" ] || return 1
  grep -qF "$lib" <<<"$stderr" || return 1
  return 0
}

@test "degraded: the ownership classifier cannot be sourced" {
  assert_degraded_without "audit-scope.sh"
}

@test "degraded: the machinery matcher cannot be sourced" {
  assert_degraded_without "audit-machinery.sh"
}

@test "degraded: the rules-tier predicate cannot be sourced" {
  assert_degraded_without "audit-rules-changed.sh"
}

# The version normalizer is sourced ahead of the library block the other three
# share, because the version gate answers before the walk starts. Folding it
# down into that block would put its `command -v` probe below the call it
# guards, where an absent lib is a command-not-found that aborts the resolver
# under `set -euo pipefail` instead of degrading it.
@test "degraded: the version normalizer cannot be sourced" {
  assert_degraded_without "gaia-version.sh"
}

@test "an absent clearance reader falls back to the floor rather than degrading" {
  add_commit a
  base="$(stamp_anchor)"
  add_commit b
  rm -f "$SANDBOX/.claude/hooks/lib/audit-clearance.sh"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$base" ]
  [ "$(m_reason)" = "team-signal" ]
  grep -qF "reason=degraded" <<<"$stderr" && return 1
  return 0
}

@test "an empty clearance store resolves through the whole-team signal" {
  add_commit a
  base="$(stamp_anchor)"
  add_commit b
  [ ! -d "$SANDBOX/.gaia/local/audit" ]

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_base)" = "$base" ]
  [ "$(m_reason)" = "team-signal" ]
  [ -z "$(m_tree)" ]
}

# -----------------------------------------------------------------------------
# Output shape. Line 3 is the argument-less resolution, produced by the same
# code path, which is what makes review-time and merge-time key agreement
# structural. Line counts are taken from a FILE: bats strips trailing newlines
# from $output, so the empty fourth line vanishes there.
# -----------------------------------------------------------------------------

@test "the argument-less form prints exactly one line on every fixture shape" {
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]

  add_machinery_commit
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]

  : > "$SANDBOX/.gaia/VERSION"
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "the member form prints four lines and line 3 matches the argument-less form" {
  require_jq
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_lines)" -eq 4 ]
  [ "$(m_reason)" = "member-clearance" ]
  [ -n "$(m_tree)" ]
  key="$(m_key)"

  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$key" ]
}

@test "the member form prints four lines on the no-version path" {
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  : > "$SANDBOX/.gaia/VERSION"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_lines)" -eq 4 ]
  [ "$(m_base)" = "main" ]
  [ "$(m_reason)" = "no-version" ]
  [ "$(m_key)" = "main" ]
  [ -z "$(m_tree)" ]
}

@test "the member form prints four lines on a reset path" {
  add_commit a
  stamp_anchor >/dev/null
  add_global_rules_commit

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_lines)" -eq 4 ]
  [ "$(m_reason)" = "rules-reset-global" ]
  [ -z "$(m_tree)" ]
}

@test "every path writes exactly one decision line to stderr" {
  add_commit a
  base="$(stamp_anchor)"
  add_commit b

  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$(grep -c 'resolve-audit-base: member=' <<<"$stderr")" -eq 1 ]
  grep -qF "member=- base=${base} reason=team-signal anchor_tree=-" <<<"$stderr"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'resolve-audit-base: member=' <<<"$stderr")" -eq 1 ]
  grep -qF "member=${DEFAULT_MEMBER} base=${base} reason=team-signal anchor_tree=-" <<<"$stderr"
}

# -----------------------------------------------------------------------------
# Argument handling. A mis-invocation cannot be trusted to be a member call
# site, so it degrades to the argument-less full-scope shape -- and still
# exits 0, because a non-zero exit degrades the agent call sites to an EMPTY
# review scope rather than a full one.
# -----------------------------------------------------------------------------

@test "an unknown argument resolves full scope and exits 0" {
  add_commit a
  base="$(stamp_anchor)"
  add_commit b

  run --separate-stderr bash -c "cd '$SANDBOX' && '$SCRIPT' --bogus"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ "$output" != "$base" ]
  grep -qF "unknown argument" <<<"$stderr"
}

@test "--member with an empty value resolves full scope and exits 0" {
  add_commit a
  base="$(stamp_anchor)"
  add_commit b

  run --separate-stderr bash -c "cd '$SANDBOX' && '$SCRIPT' --member ''"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ "$output" != "$base" ]
  grep -qF "non-empty value" <<<"$stderr"
}

@test "--member with no value at all resolves full scope and exits 0" {
  add_commit a
  stamp_anchor >/dev/null
  add_commit b

  run --separate-stderr bash -c "cd '$SANDBOX' && '$SCRIPT' --member"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  grep -qF "requires a value" <<<"$stderr"
}

# =============================================================================
# Reason-token reachability: the closed set is eight tokens, and each one must
# be emitted on at least one input. The tests above assert richer behavior on
# these same paths; this section exists so the set is enumerated in one place
# and a ninth token cannot be introduced unnoticed.
# =============================================================================

@test "reason token: member-clearance" {
  require_jq
  add_commit a
  add_commit b
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit c
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_reason)" = "member-clearance" ]
}

@test "reason token: team-signal" {
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_reason)" = "team-signal" ]
}

@test "reason token: no-anchor" {
  add_commit a
  add_commit b
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_reason)" = "no-anchor" ]
}

@test "reason token: rules-reset-global" {
  add_commit a
  stamp_anchor >/dev/null
  add_global_rules_commit
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_reason)" = "rules-reset-global" ]
}

@test "reason token: rules-reset-member" {
  add_commit a
  stamp_anchor >/dev/null
  commit_append ".claude/agents/${DEFAULT_MEMBER}.md"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_reason)" = "rules-reset-member" ]
}

@test "reason token: machinery-reset" {
  add_commit a
  stamp_anchor >/dev/null
  commit_append ".claude/hooks/local-janitor.sh"
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  grep -qF "reason=machinery-reset" <<<"$stderr"
}

@test "reason token: degraded" {
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  rm -f "$SANDBOX/.claude/hooks/lib/audit-rules-changed.sh"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_reason)" = "degraded" ]
}

@test "reason token: no-version" {
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  rm -f "$SANDBOX/.gaia/VERSION"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(m_reason)" = "no-version" ]
}
