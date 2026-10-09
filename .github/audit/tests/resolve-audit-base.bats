#!/usr/bin/env bats
#
# Every test uses `run --separate-stderr`: the resolver writes one decision
# line to stderr on every path, and bats' plain `run` folds stderr into
# $output.
bats_require_minimum_version 1.5.0

# Tests for .github/audit/resolve-audit-base.sh.
#
# The helper is consumed by the Code Audit Team's agent definitions on local
# runs. Two invocation forms:
#
#   argument-less   ONE stdout line: the most recent PR ancestor of HEAD that
#                   passed a clean whole-team audit under the current
#                   .gaia/VERSION (proven by a GAIA-Audit commit status), or
#                   the main ref for a full-scope fallback. A commit-message
#                   trailer is not a signal and is ignored.
#   --member <name> FOUR stdout lines: the per-member review base, the reason
#                   token, the shared pull-request-wide base (byte-identical
#                   to what the argument-less form prints on the same
#                   fixture), and the recorded tree of the clearance or
#                   refusal that anchored the answer.
#
# The base is gated by VERSION MATCH ALONE on both anchor arms: the
# status is the three-field C3 form
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
# one test per token in the closed set.
#

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCRIPT="$THIS_DIRECTORY/../resolve-audit-base.sh"
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

  # Every test posts its whole-team signals through this one mock, so it is
  # installed here in the parent shell: a fixture that posts a status from a
  # command substitution could not export PATH or the token to the test.
  install_gh_mock

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

  # The team-signal arm scans every roster member's markers, so the roster is
  # provisioned too (uncommitted, like the libs).
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$SANDBOX/.gaia/audit-ci.yml"

  # The refusal link locates the re-run ledger through the key library; its
  # absence fails only that link, so one test removes it.
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" "$SANDBOX/.gaia/scripts/audit-key-lib.sh"

  # The resolver takes one path whatever the environment; the tests that prove
  # that export these variables themselves.
  unset GITHUB_ACTIONS CI GITHUB_BASE_REF

  # The status digest field (C3 field 2) is never compared by this
  # script (only the version, field 1, gates the base), so every fixture
  # uses this fixed 64-hex placeholder rather than a recomputed real digest.
  DIGEST="$(printf '%064d' 0)"

  # The clearance reader gives the default member the infix-free filename
  # family and every other member a ".<member>" infix, so fixtures need one
  # of each.
  DEFAULT_MEMBER="code-audit-frontend"
  OTHER_MEMBER="code-audit-maintainer-shell"

  # A third roster member no fixture resolves as: it holds the full review a
  # signal commit needs, without ever becoming a per-member anchor itself.
  SUPPORT_MEMBER="code-audit-maintainer-node"

  MEMBER_OUTPUT_FILE="$BATS_TEST_TMPDIR/member.out"
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
#
# $2 pins the interpreter. Unset, the script runs under its own
# `#!/usr/bin/env bash` shebang, which is whichever bash leads PATH. The
# unparseable-lib cases below pass /bin/bash deliberately: the guarded-load
# shapes they tell apart behave identically on bash 5, so only the 3.2.57 stock
# macOS ships distinguishes them.
run_member() {
  local interpreter="${2:-}"
  if [ -n "$interpreter" ]; then
    ( cd "$SANDBOX" && "$interpreter" "$SCRIPT" --member "$1" ) > "$MEMBER_OUTPUT_FILE"
  else
    ( cd "$SANDBOX" && "$SCRIPT" --member "$1" ) > "$MEMBER_OUTPUT_FILE"
  fi
}

# Field accessors over the filed stdout of the last run_member call.
member_base() { sed -n 1p "$MEMBER_OUTPUT_FILE"; }
member_reason() { sed -n 2p "$MEMBER_OUTPUT_FILE"; }
member_shared_base() { sed -n 3p "$MEMBER_OUTPUT_FILE"; }
member_anchor_tree() { sed -n 4p "$MEMBER_OUTPUT_FILE"; }
member_line_count() { wc -l < "$MEMBER_OUTPUT_FILE" | tr -d ' '; }

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

# Amend HEAD with one GAIA-Audit trailer. The resolver ignores trailers, so
# only the cases proving that use it. Only HEAD can be amended cheaply.
amend_head_with_trailer() {
  git -C "$SANDBOX" commit --amend --no-edit --no-verify \
    --trailer "$1" >/dev/null
}

# Post a GAIA-Audit status for HEAD, "<version> <digest> <tree>": the signal the
# whole-team arm anchors on. It appends to the gh mock's map, so HEAD keeps its
# sha and several commits can each carry a status.
status_at_head() {
  printf '%s=%s\n' "$(sha_of HEAD)" "$1" >> "$MAP"
}

# Give HEAD a version-matching whole-team status and echo its sha: the
# clean-round anchor most fixtures below build from. It also records a full
# review at that tree, as a real clean round does; `stamp_anchor bare` posts
# the status alone, the shape CI and a fresh clone see.
stamp_anchor() {
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
  [ "${1:-}" = "bare" ] || support_signal_at HEAD
  sha_of HEAD
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
# and GNU. The counter is the store's file count rather than a shell variable,
# so a write made inside a command substitution still advances it. The recorded
# sha is deliberately whatever HEAD is at write time, because the anchor is
# matched on the tree and never on the sha.
#   $5 review (full|light|none; default full; an earned marker only: `none`
#      strips the field the way a legacy body lacks it)
#   $6 review coverage (proven|none|mismatch; default proven; a refusal only):
#      `proven` records review_coverage.scope_digest equal to the record's own
#      digest, the proof a refusal anchor needs; `none` omits the object and
#      `mismatch` records a different digest. record_digest reads the digest
#      back from the printed path.
write_clearance() {
  local member="$1" provenance="$2" tree="$3" version="$4" review="${5:-full}"
  local coverage="${6:-proven}" coverage_field=""
  local extension digest name directory review_field="" existing_count
  directory="$SANDBOX/.gaia/local/audit"
  mkdir -p "$directory"
  existing_count="$(find "$directory" -type f | wc -l | tr -d ' ')"
  digest="$(printf '%064d' "$(( existing_count + 1 ))")"
  case "$provenance" in
    earned) extension="ok" ;;
    *) extension="refused" ;;
  esac
  if [ "$member" = "$DEFAULT_MEMBER" ]; then
    name="${digest}.${extension}"
  else
    name="${digest}.${member}.${extension}"
  fi
  if [ "$provenance" = "earned" ] && [ "$review" != "none" ]; then
    review_field="$(printf '"review":"%s",' "$review")"
  fi
  if [ "$provenance" = "refused" ]; then
    case "$coverage" in
      proven) coverage_field="$(printf '"review_coverage":{"scope_digest":"%s"},' "$digest")" ;;
      mismatch) coverage_field="$(printf '"review_coverage":{"scope_digest":"%064d"},' 99)" ;;
    esac
  fi
  printf '{"version":"%s","schema":4,"member":"%s","provenance":"%s",%s%s"digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z"}\n' \
    "$version" "$member" "$provenance" "$review_field" "$coverage_field" "$digest" "$tree" "$(sha_of HEAD)" \
    > "$directory/$name"
  printf '%s\n' "$directory/$name"
}

# The digest a record carries, read from its body.
record_digest() {
  jq -r .digest "$1"
}

# Record that a full review stands at <sha>'s tree: the verification the
# team-signal arm needs before it anchors on a signal there. Written as the
# SUPPORT member so no fixture's resolving member gains a per-member anchor.
support_signal_at() {
  write_clearance "$SUPPORT_MEMBER" earned "$(tree_of "$1")" 1.2.3 full >/dev/null
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
  description="\${line#*=}"
  case "\$args" in
    *"\$sha"*) printf '%s\n' "\$description"; exit 0 ;;
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
  MAP_DIRECTORY="$BATS_TEST_TMPDIR/gh-array-map"
  mkdir -p "$GH_BIN" "$MAP_DIRECTORY"
  for pair in "$@"; do
    sha="${pair%%=*}"
    payload="${pair#*=}"
    printf '%s' "$payload" > "$MAP_DIRECTORY/$sha"
  done
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
# Mock \`gh api repos/<repo>/commits/<sha>/statuses --jq <expr>\`: pull the SHA
# and the --jq expression from argv, then run the real jq against the crafted
# array mapped for that SHA (empty array when unmapped).
map_directory="$MAP_DIRECTORY"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
jq_expression=""
previous_argument=""
for argument in "$@"; do
  if [ "$previous_argument" = "--jq" ]; then jq_expression="$argument"; break; fi
  previous_argument="$argument"
done
[ -n "$jq_expression" ] || { printf 'null\n'; exit 0; }
payload="[]"
for map_file in "$map_directory"/*; do
  [ -e "$map_file" ] || continue
  sha="$(basename "$map_file")"
  case "$*" in
    *"$sha"*) payload="$(cat "$map_file")"; break ;;
  esac
done
printf '%s' "$payload" | jq -r "$jq_expression"
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

set_origin_reference() {
  git -C "$SANDBOX" update-ref "refs/remotes/origin/$1" "$(git -C "$SANDBOX" rev-parse "$2")"
}

@test "no base ref declared → the repository default" {
  add_commit a
  add_commit b
  set_origin_reference main main
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]
}

# This resolver decides how much of the tree a member reviews: a base taken from
# the environment that resolved at or near HEAD would empty the reviewed delta
# and let a member earn a clearance having read nothing, so a declared base ref
# is ignored whether or not the event variables claim to be Actions.
@test "a declared base ref is ignored, with or without GITHUB_ACTIONS" {
  add_commit a
  add_commit b
  set_origin_reference main main
  set_origin_reference release main
  export GITHUB_BASE_REF=release
  unset GITHUB_ACTIONS
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]
  export GITHUB_ACTIONS=true
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]
}

@test "stdout is identical with the CI variables exported and without them, in both forms" {
  local plain with_ci
  add_commit a
  add_commit b
  set_origin_reference main main
  set_origin_reference release main
  run --separate-stderr run_in_sandbox
  [ "$output" = "origin/main" ]
  plain="$output"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  plain="$plain|$output"
  export CI=true GITHUB_ACTIONS=true GITHUB_BASE_REF=release
  run --separate-stderr run_in_sandbox
  with_ci="$output"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  with_ci="$with_ci|$output"
  [ -n "$plain" ]
  [ "$plain" = "$with_ci" ]
}

# A trailer is not a signal: a branch whose history carries one, and no status
# or clearance for the current tree, resolves exactly as the same branch without.
@test "a GAIA-Audit trailer on the parent is ignored: resolves as the branch without it" {
  add_commit a
  add_commit b
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  without_trailer_stderr="$stderr"

  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(tree_of HEAD)"
  add_commit c
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ "${stderr%%$'\n'*}" = "${without_trailer_stderr%%$'\n'*}" ]
  grep -qF "reason=no-anchor" <<<"$stderr"
}

@test "a GAIA-Audit trailer is ignored in the member form too" {
  add_commit a
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(tree_of HEAD)"
  support_signal_at HEAD
  add_commit b

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  [ "$(member_shared_base)" = "main" ]
}

# -----------------------------------------------------------------------------
# 4. Newest of several audited commits wins
# -----------------------------------------------------------------------------

@test "newest audited commit wins over an older audited commit" {
  add_commit a
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
  older="$(sha_of HEAD)"
  add_commit b
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
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
# 7. A trailer newer than a status does not displace it
# -----------------------------------------------------------------------------

@test "a newer trailer does not displace an older status" {
  add_commit a
  status_sha="$(sha_of HEAD)"
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
  add_commit b
  amend_head_with_trailer "GAIA-Audit: 1.2.3 ${DIGEST} $(tree_of HEAD)"
  trailer_sha="$(sha_of HEAD)"
  add_commit c
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$status_sha" ]
  [ "$output" != "$trailer_sha" ]
}

@test ".gaia/VERSION missing → main ref" {
  add_commit a
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
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
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
  add_commit b
  : > "$SANDBOX/.gaia/VERSION"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "blank version"
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "matching status on HEAD is not used as its own base" {
  add_commit a
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
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

@test "no GH_TOKEN → status path skipped → main ref" {
  add_commit a
  base="$(sha_of HEAD)"
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
  add_commit b
  # A status exists, but without GH_TOKEN the helper never queries it, so it
  # falls back to main.
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
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
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
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
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
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
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
  status_at_head "1.2.3 ${DIGEST} $(tree_of HEAD)"
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
  team_anchor_sha="$(stamp_anchor)"
  add_commit b
  member_clearance_sha="$(sha_of HEAD)"
  member_clearance_tree="$(tree_of HEAD)"
  write_clearance "$OTHER_MEMBER" earned "$member_clearance_tree" 1.2.3 >/dev/null
  add_commit c

  # The member holding a clearance at C2 anchors there, though no whole-team
  # signal ever certified C2 (a sibling was pending in that round).
  run --separate-stderr run_member "$OTHER_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_line_count)" -eq 4 ]
  [ "$(member_base)" = "$member_clearance_sha" ]
  [ "$(member_reason)" = "member-clearance" ]
  [ "$(member_anchor_tree)" = "$member_clearance_tree" ]

  # A member holding no clearance newer than C1 falls back to the floor.
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_line_count)" -eq 4 ]
  [ "$(member_base)" = "$team_anchor_sha" ]
  [ "$(member_reason)" = "team-signal" ]
  [ -z "$(member_anchor_tree)" ]
}

@test "a member clearance newer than the whole-team signal wins the walk" {
  require_jq
  add_commit a
  team_anchor_sha="$(stamp_anchor)"
  add_commit b
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  member_clearance_sha="$(sha_of HEAD)"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$member_clearance_sha" ]
  [ "$(member_base)" != "$team_anchor_sha" ]
  [ "$(member_reason)" = "member-clearance" ]
}

@test "a whole-team signal newer than the member clearance wins the walk" {
  require_jq
  add_commit a
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  member_clearance_sha="$(sha_of HEAD)"
  add_commit b
  team_anchor_sha="$(stamp_anchor)"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$team_anchor_sha" ]
  [ "$(member_base)" != "$member_clearance_sha" ]
  [ "$(member_reason)" = "team-signal" ]
}

# -----------------------------------------------------------------------------
# The global tier: one commit touching one global-rules path between the anchor
# and HEAD resets every member. Four representative paths, one fixture each,
# because a delta accumulates: a second path tested in the same fixture would
# be masked by the first.
# -----------------------------------------------------------------------------

# Post an anchor status, commit an append to <path>, and assert the member form reset
# globally and named the path.
assert_global_reset_for() {
  local path="$1" base
  add_commit a
  base="$(stamp_anchor)"
  commit_append "$path"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ] || return 1
  [ "$(member_line_count)" -eq 4 ] || return 1
  [ "$(member_base)" = "main" ] || return 1
  [ "$(member_base)" != "$base" ] || return 1
  [ "$(member_reason)" = "rules-reset-global" ] || return 1
  [ -z "$(member_anchor_tree)" ] || return 1
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
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "rules-reset-member" ]
  grep -qF ".claude/agents/${DEFAULT_MEMBER}.md" <<<"$stderr"

  run --separate-stderr run_member "$OTHER_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$base" ]
  [ "$(member_reason)" = "team-signal" ]
}

@test "merely-shared machinery resets nobody in the member form" {
  add_commit a
  base="$(stamp_anchor)"
  commit_append ".claude/hooks/lib/cross-repo-refusal.sh"
  commit_append ".github/audit/resolve-check-base.sh"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$base" ]
  [ "$(member_reason)" = "team-signal" ]

  # The same delta legitimately resets the SHARED key base, which keeps the
  # flat machinery test. Lines 1 and 3 diverging is what the two-base split is
  # for, not a defect.
  [ "$(member_shared_base)" = "main" ]
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ "$output" = "$(member_shared_base)" ]
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
  [ "$(member_base)" = "$base" ]
  [ "$(member_reason)" = "team-signal" ]
  grep -qF "rules-reset-global" <<<"$stderr" && return 1

  run --separate-stderr run_member "$OTHER_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$base" ]
  [ "$(member_reason)" = "team-signal" ]
}

# -----------------------------------------------------------------------------
# The status arm drives the reset, exercised through the mock that returns a
# full statuses array, so the production state filter runs too.
# -----------------------------------------------------------------------------

@test "the reset fires on the commit-status arm" {
  add_commit a
  base="$(sha_of HEAD)"
  base_tree="$(tree_of HEAD)"
  support_signal_at "$base"
  install_gh_array_mock \
    "${base}=[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${DIGEST} ${base_tree}\"}]"
  commit_append ".claude/rules/quality-gate.md"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_base)" != "$base" ]
  [ "$(member_reason)" = "rules-reset-global" ]
  grep -qF ".claude/rules/quality-gate.md" <<<"$stderr"
}

@test "the status arm anchors the member form" {
  add_commit a
  base="$(sha_of HEAD)"
  base_tree="$(tree_of HEAD)"
  add_commit b
  support_signal_at "$base"
  install_gh_array_mock \
    "${base}=[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${DIGEST} ${base_tree}\"}]"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$base" ]
  [ "$(member_reason)" = "team-signal" ]
}

# -----------------------------------------------------------------------------
# The four ways a clearance is unusable. Each falls back to the newest usable
# whole-team signal, or to the main ref when there is none, and never emits the
# candidate the unusable clearance points at.
# -----------------------------------------------------------------------------

@test "unusable clearance: a stale recorded version is not an anchor" {
  require_jq
  add_commit a
  team_anchor_sha="$(stamp_anchor)"
  add_commit b
  unusable_clearance_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 9.9.9 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$team_anchor_sha" ]
  [ "$(member_base)" != "$unusable_clearance_sha" ]
  [ "$(member_reason)" = "team-signal" ]
}

@test "unusable clearance: a recorded tree matching no candidate is not an anchor" {
  require_jq
  add_commit a
  team_anchor_sha="$(stamp_anchor)"
  add_commit b
  unusable_clearance_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(printf '%040d' 7)" 1.2.3 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$team_anchor_sha" ]
  [ "$(member_base)" != "$unusable_clearance_sha" ]
  [ "$(member_reason)" = "team-signal" ]
}

@test "unusable clearance: a pruned record is not an anchor" {
  require_jq
  add_commit a
  team_anchor_sha="$(stamp_anchor)"
  add_commit b
  unusable_clearance_sha="$(sha_of HEAD)"
  marker="$(write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3)"
  rm -f "$marker"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$team_anchor_sha" ]
  [ "$(member_base)" != "$unusable_clearance_sha" ]
  [ "$(member_reason)" = "team-signal" ]
}

@test "unusable clearance: no whole-team signal in range yields the main ref" {
  require_jq
  add_commit a
  add_commit b
  unusable_clearance_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 9.9.9 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_base)" != "$unusable_clearance_sha" ]
  [ "$(member_reason)" = "no-anchor" ]
}

@test "another member's clearance is not readable as this member's anchor" {
  require_jq
  add_commit a
  add_commit b
  unusable_clearance_sha="$(sha_of HEAD)"
  write_clearance "$OTHER_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_base)" != "$unusable_clearance_sha" ]
  [ "$(member_reason)" = "no-anchor" ]
}

# -----------------------------------------------------------------------------
# An amend rewrites the sha a moments-old clearance recorded while preserving
# the tree. Matching on the tree is what survives it.
# -----------------------------------------------------------------------------

@test "a clearance still anchors after an amend rewrites the commit sha" {
  require_jq
  add_commit a
  team_anchor_sha="$(stamp_anchor)"
  add_commit b
  member_clearance_sha_before_amend="$(sha_of HEAD)"
  member_clearance_tree="$(tree_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$member_clearance_tree" 1.2.3 >/dev/null
  GIT_COMMITTER_DATE="2026-01-02T00:00:00" git -C "$SANDBOX" commit \
    --amend --no-edit --no-verify --date="2026-01-02T00:00:00" >/dev/null
  member_clearance_sha_after_amend="$(sha_of HEAD)"
  # The fixture is only meaningful if the amend really moved the sha.
  [ "$member_clearance_sha_after_amend" != "$member_clearance_sha_before_amend" ]
  [ "$(tree_of HEAD)" = "$member_clearance_tree" ]
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$member_clearance_sha_after_amend" ]
  [ "$(member_base)" != "$team_anchor_sha" ]
  [ "$(member_reason)" = "member-clearance" ]
  [ "$(member_anchor_tree)" = "$member_clearance_tree" ]
}

# -----------------------------------------------------------------------------
# Refusals. The newest member signal wins the member arm, a refusal winning a
# same-tree tie, and a refusal anchors (member-refusal) only when the re-run
# ledger links it: per-member provenance naming this refusal's digest, tree and
# the current version, at least one open entry for the member, a ledger for
# this branch and key base, and a review-coverage proof on the refusal record.
# Any failed link falls back to the whole-team anchor or to no-anchor, never to
# degraded, and names its cause on a line carrying "refused content".
# -----------------------------------------------------------------------------

# The ledger path the resolver derives: the audit key built from the merge-base
# of the argument-less resolution (line 3) and HEAD, through the sandbox's own
# key library. Computed at the fixture's final HEAD, since line 3 depends on it.
sandbox_ledger_path() {
  local key_reference key_base key
  key_reference="$( cd "$SANDBOX" && "$SCRIPT" 2>/dev/null )"
  key_base="$(git -C "$SANDBOX" merge-base "$key_reference" HEAD)"
  key="$( . "$SANDBOX/.gaia/scripts/audit-key-lib.sh" && gaia_audit_key "$key_base" "$SANDBOX" )"
  [ -n "$key" ] || return 1
  printf '%s\n' "$SANDBOX/.gaia/local/audit/${key}.rerun.json"
}

# write_ledger <member> <refusal-digest> <refusal-tree> <version> [<entries-json>]
# Writes a schema-1 re-run ledger at the derived key whose provenance for
# <member> names that refusal, and prints its path. The default entries hold one
# open finding for <member>.
write_ledger() {
  local member="$1" refusal_digest="$2" refusal_tree="$3" version="$4" entries="${5:-}"
  local ledger_path key_reference key_base
  ledger_path="$(sandbox_ledger_path)" || return 1
  key_reference="$( cd "$SANDBOX" && "$SCRIPT" 2>/dev/null )"
  key_base="$(git -C "$SANDBOX" merge-base "$key_reference" HEAD)"
  if [ -z "$entries" ]; then
    entries="$(jq -n --arg member "$member" \
      '[{member: $member, entry_id: "r1-1", finding_class: "example-class", severity: "important",
         path: "a.txt", line: 1, title: "an open finding", first_seen_round: 1, escalated: false}]')"
  fi
  mkdir -p "$SANDBOX/.gaia/local/audit"
  jq -n \
    --arg branch "$(git -C "$SANDBOX" branch --show-current)" \
    --arg base "$key_base" \
    --arg head "$(sha_of HEAD)" \
    --arg member "$member" \
    --arg digest "$refusal_digest" \
    --arg tree "$refusal_tree" \
    --arg version "$version" \
    --argjson entries "$entries" \
    '{schema: 1, base_sha: $base, branch: $branch, round: 1, head_sha: $head,
      updated_at: "2026-01-01T00:00:00Z", remaining: $entries, fixed_last_round: [],
      notes: "",
      member_provenance: {($member): {refusal_digest: $digest, refusal_tree: $tree,
                                      refusal_sha: $head, version: $version}}}' \
    > "$ledger_path"
  printf '%s\n' "$ledger_path"
}

# edit_ledger <path> <jq filter>: rewrite the ledger in place through <filter>.
edit_ledger() {
  jq "$2" "$1" > "$1.edited"
  mv "$1.edited" "$1"
}

# write_twin <record path> <provenance> [<tree>]: a record of the same member
# and digest under the other provenance, optionally recording another tree.
write_twin() {
  local source="$1" provenance="$2" tree="${3:-}" extension
  case "$provenance" in
    earned) extension="ok" ;;
    *) extension="refused" ;;
  esac
  jq --arg provenance "$provenance" --arg tree "$tree" \
    '.provenance = $provenance
      | (if $tree != "" then .tree = $tree else . end)
      | (if $provenance == "earned" then .review = "full" | del(.review_coverage) else . end)' \
    "$source" > "${source%.*}.${extension}"
}

# refuse_head [<coverage>]: record a current-version refusal of the default
# member at HEAD's tree. Sets REFUSED_SHA, REFUSED_TREE, REFUSAL_RECORD and
# REFUSAL_DIGEST (globals, so not callable from a command substitution).
refuse_head() {
  REFUSED_SHA="$(sha_of HEAD)"
  REFUSED_TREE="$(tree_of HEAD)"
  REFUSAL_RECORD="$(write_clearance "$DEFAULT_MEMBER" refused "$REFUSED_TREE" 1.2.3 full "${1:-proven}")"
  REFUSAL_DIGEST="$(record_digest "$REFUSAL_RECORD")"
}

# link_refusal: write the ledger linking the refusal refuse_head recorded, at
# the fixture's current HEAD. Sets LEDGER.
link_refusal() {
  LEDGER="$(write_ledger "$DEFAULT_MEMBER" "$REFUSAL_DIGEST" "$REFUSED_TREE" 1.2.3)"
  [ -f "$LEDGER" ]
}

# The basic linked shape: refusal at A with a valid link, HEAD on a fixer
# commit B. $1 is the refusal's review coverage (see write_clearance).
build_linked_refusal() {
  add_commit a
  refuse_head "${1:-proven}"
  add_commit b
  link_refusal
}

# golden_value <fixture> <form> <line>: the value the characterization golden
# recorded, so a fallback is compared with the pre-change resolver itself.
golden_value() {
  awk -v fixture="$1" -v form="$2" -v line="$3" \
    '$1 == fixture && $2 == form && $3 == line { print $4; exit }' \
    "$THIS_DIRECTORY/fixtures/resolve-audit-base-characterization.golden"
}

# The member form's line <n>, rendered the way the golden records a ref.
rendered_member_line() {
  local value
  value="$(sed -n "${1}p" "$MEMBER_OUTPUT_FILE")"
  if [ "$value" = "main" ]; then
    printf '%s\n' "main-ref"
  else
    printf '%s\n' "$value"
  fi
}

# assert_member_lines_match_golden <fixture>: lines 1-2 equal the golden's.
assert_member_lines_match_golden() {
  local expected_base expected_reason
  expected_base="$(golden_value "$1" member 1)"
  expected_reason="$(golden_value "$1" member 2)"
  [ -n "$expected_base" ] || return 1
  [ -n "$expected_reason" ] || return 1
  [ "$(rendered_member_line 1)" = "$expected_base" ] || return 1
  [ "$(rendered_member_line 2)" = "$expected_reason" ] || return 1
  return 0
}

assert_refusal_anchor() {
  [ "$status" -eq 0 ] || return 1
  [ "$(member_line_count)" -eq 4 ] || return 1
  [ "$(member_base)" = "$REFUSED_SHA" ] || return 1
  [ "$(member_reason)" = "member-refusal" ] || return 1
  [ "$(member_anchor_tree)" = "$REFUSED_TREE" ] || return 1
  return 0
}

# assert_refusal_fallback <cause>: the refusal did not link, the answer is the
# pre-change resolver's for a lone refusal, and stderr names <cause> on the
# line that carries "refused content".
assert_refusal_fallback() {
  local cause="$1" refusal_line
  [ "$status" -eq 0 ] || return 1
  [ "$(member_line_count)" -eq 4 ] || return 1
  [ "$(member_base)" = "main" ] || return 1
  [ "$(member_base)" != "$REFUSED_SHA" ] || return 1
  [ "$(member_reason)" = "no-anchor" ] || return 1
  [ -z "$(member_anchor_tree)" ] || return 1
  assert_member_lines_match_golden refusal-only || return 1
  refusal_line="$(grep -F "refused content" <<<"$stderr" || true)"
  [ -n "$refusal_line" ] || return 1
  grep -qF -- "$cause" <<<"$refusal_line" || return 1
  grep -qF "reason=degraded" <<<"$stderr" && return 1
  return 0
}

@test "refusal anchor: a linked refusal anchors the member at the refused commit" {
  require_jq
  build_linked_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_anchor
  # Line 3 and the argument-less form are the pre-change resolver's answer.
  [ "$(rendered_member_line 3)" = "$(golden_value refusal-only member 3)" ]
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ "$(golden_value refusal-only argless 1)" = "main-ref" ]
}

@test "refusal link: an absent ledger falls back" {
  require_jq
  build_linked_refusal
  rm -f "$LEDGER"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "the re-run ledger is absent"
}

@test "refusal link: a ledger that is not valid JSON falls back" {
  require_jq
  build_linked_refusal
  printf 'not json at all\n' > "$LEDGER"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "the re-run ledger does not parse"
}

@test "refusal link: a ledger with no open entry for the member falls back" {
  require_jq
  build_linked_refusal
  edit_ledger "$LEDGER" '.remaining = []'
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "holds no open entry for ${DEFAULT_MEMBER}"
}

@test "refusal link: a ledger whose entries all belong to another member falls back" {
  require_jq
  build_linked_refusal
  edit_ledger "$LEDGER" ".remaining |= map(.member = \"${OTHER_MEMBER}\")"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "holds no open entry for ${DEFAULT_MEMBER}"
}

@test "refusal link: provenance naming an older refusal of the member falls back" {
  require_jq
  add_commit o
  older_tree="$(tree_of HEAD)"
  older_record="$(write_clearance "$DEFAULT_MEMBER" refused "$older_tree" 1.2.3)"
  add_commit a
  refuse_head
  add_commit b
  LEDGER="$(write_ledger "$DEFAULT_MEMBER" "$(record_digest "$older_record")" "$older_tree" 1.2.3)"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "names a different refusal of ${DEFAULT_MEMBER}"
}

@test "refusal link: provenance naming the refusal's digest with another tree falls back" {
  require_jq
  build_linked_refusal
  edit_ledger "$LEDGER" ".member_provenance[\"${DEFAULT_MEMBER}\"].refusal_tree = \"$(printf '%040d' 5)\""
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "records a different tree for this refusal"
}

@test "refusal link: a ledger with no member provenance at all falls back" {
  require_jq
  build_linked_refusal
  edit_ledger "$LEDGER" 'del(.member_provenance)'
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "holds no provenance for ${DEFAULT_MEMBER}"
}

@test "refusal link: a jq that cannot run falls back" {
  require_jq
  build_linked_refusal
  # A failing jq shadows the real one, the shim shape the clearance writer's
  # suite uses; git, awk and sed still resolve behind it.
  shim="$BATS_TEST_TMPDIR/shim-nojq"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/jq"
  chmod +x "$shim/jq"
  export PATH="$shim:$PATH"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "jq is unavailable"
}

@test "refusal link: an absent key library falls back without degrading" {
  require_jq
  build_linked_refusal
  rm -f "$SANDBOX/.gaia/scripts/audit-key-lib.sh"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "audit key library"
  [ "$(member_reason)" != "degraded" ]
}

@test "refusal link: a ledger recorded for another branch falls back" {
  require_jq
  build_linked_refusal
  edit_ledger "$LEDGER" '.branch = "another-branch"'
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "stale re-run ledger"
}

@test "refusal link: a ledger recorded against another base falls back" {
  require_jq
  build_linked_refusal
  edit_ledger "$LEDGER" ".base_sha = \"$(printf '%040d' 3)\""
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "stale re-run ledger"
}

@test "refusal link: a refusal with no review-coverage proof falls back" {
  require_jq
  build_linked_refusal none
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "no review-coverage proof"
}

@test "refusal link: a review-coverage proof naming another digest falls back" {
  require_jq
  build_linked_refusal mismatch
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "no review-coverage proof"
}

@test "refusal link: the ledger is read with GITHUB_ACTIONS and CI exported" {
  require_jq
  build_linked_refusal
  export GITHUB_ACTIONS=true CI=true
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_anchor
}

@test "refusal link: CI=true outside GitHub Actions still reads the ledger" {
  require_jq
  build_linked_refusal
  export CI=true
  unset GITHUB_ACTIONS
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_anchor
}

@test "refusal anchor: a linked refusal newer than an earned clearance anchors at the refusal" {
  require_jq
  add_commit c
  earned_tree="$(tree_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$earned_tree" 1.2.3 full >/dev/null
  add_commit a
  refuse_head
  add_commit b
  link_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_anchor
  [ "$(member_anchor_tree)" != "$earned_tree" ]
}

@test "refusal anchor: the member's own agent definition changing resets it" {
  require_jq
  add_commit a
  refuse_head
  commit_append ".claude/agents/${DEFAULT_MEMBER}.md"
  link_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_base)" != "$REFUSED_SHA" ]
  [ "$(member_reason)" = "rules-reset-member" ]
}

@test "refusal anchor: a global rules path changing resets it" {
  require_jq
  add_commit a
  refuse_head
  commit_append ".claude/rules/quality-gate.md"
  link_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_base)" != "$REFUSED_SHA" ]
  [ "$(member_reason)" = "rules-reset-global" ]
}

@test "refusal anchor: both rule tiers changing resolve as the golden recorded for a clearance" {
  require_jq
  add_commit a
  refuse_head
  commit_append ".claude/agents/${DEFAULT_MEMBER}.md"
  commit_append ".claude/rules/quality-gate.md"
  add_commit b
  link_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" != "$REFUSED_SHA" ]
  assert_member_lines_match_golden clearance-both-rules
}

@test "refusal anchor: a missing predicate lib degrades as the golden recorded for a clearance" {
  require_jq
  build_linked_refusal
  rm -f "$SANDBOX/.claude/hooks/lib/audit-scope.sh"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" != "$REFUSED_SHA" ]
  assert_member_lines_match_golden clearance-degraded
}

@test "refusal anchor: a missing version file resolves as the golden recorded for a clearance" {
  require_jq
  build_linked_refusal
  rm -f "$SANDBOX/.gaia/VERSION"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" != "$REFUSED_SHA" ]
  assert_member_lines_match_golden clearance-no-version
}

@test "refusal link: a refusal recorded under another version never anchors and blocks an older clearance" {
  require_jq
  add_commit c
  earned_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit a
  REFUSED_SHA="$(sha_of HEAD)"
  REFUSED_TREE="$(tree_of HEAD)"
  REFUSAL_RECORD="$(write_clearance "$DEFAULT_MEMBER" refused "$REFUSED_TREE" 0.9.9)"
  REFUSAL_DIGEST="$(record_digest "$REFUSAL_RECORD")"
  add_commit b
  link_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "version mismatch"
  [ "$(member_base)" != "$earned_sha" ]
}

@test "refusal precedence: an earned clearance newer than the refusal anchors" {
  require_jq
  add_commit a
  refused_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" refused "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit b
  earned_sha="$(sha_of HEAD)"
  earned_tree="$(tree_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$earned_tree" 1.2.3 >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$earned_sha" ]
  [ "$(member_base)" != "$refused_sha" ]
  [ "$(member_reason)" = "member-clearance" ]
  [ "$(member_anchor_tree)" = "$earned_tree" ]
}

@test "refusal precedence: an older earned clearance never anchors past an unlinked refusal" {
  require_jq
  add_commit c
  earned_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit a
  refuse_head
  add_commit b

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "the re-run ledger is absent"
  [ "$(member_base)" != "$earned_sha" ]

  link_refusal
  edit_ledger "$LEDGER" 'del(.member_provenance)'
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_fallback "holds no provenance for ${DEFAULT_MEMBER}"
  [ "$(member_base)" != "$earned_sha" ]
}

@test "refusal precedence: a refusal and an earned record at the same tree resolve as the refusal" {
  require_jq
  add_commit a
  refuse_head
  write_twin "$REFUSAL_RECORD" earned
  [ -f "${REFUSAL_RECORD%.*}.ok" ]
  add_commit b
  link_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_anchor
}

@test "refusal link: a team signal older than the refusal is the fallback, and the link beats it" {
  require_jq
  add_commit t
  team_anchor_sha="$(stamp_anchor)"
  add_commit a
  refuse_head
  add_commit b

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$team_anchor_sha" ]
  [ "$(member_reason)" = "team-signal" ]
  grep -qF "refused content at ${REFUSED_SHA}" <<<"$stderr"

  link_refusal
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_anchor
  [ "$(member_shared_base)" = "$team_anchor_sha" ]
}

@test "refusal anchor: merely-shared machinery after the anchor resets line 3 and never line 1" {
  require_jq
  add_commit t
  stamp_anchor >/dev/null
  add_commit a
  refuse_head
  add_machinery_commit
  add_commit b
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  argless_without_link="$output"
  link_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_anchor
  [ "$(member_shared_base)" = "main" ]
  run --separate-stderr run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ "$output" = "$argless_without_link" ]
}

@test "refusal precedence: a refusal at HEAD disables the member arm" {
  require_jq
  add_commit c
  earned_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit h
  refuse_head
  link_refusal

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_base)" != "$earned_sha" ]
  [ "$(member_reason)" = "no-anchor" ]
  grep -qF "refused content at HEAD" <<<"$stderr"
}

@test "refusal precedence: an earned clearance beside a live refusal for its own digest is no anchor" {
  require_jq
  add_commit c
  earned_sha="$(sha_of HEAD)"
  earned_record="$(write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full)"
  write_twin "$earned_record" refused "$(printf '%040d' 8)"
  [ -f "${earned_record%.*}.refused" ]
  add_commit d

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_base)" != "$earned_sha" ]
  [ "$(member_reason)" = "no-anchor" ]
}

@test "refusal link: a co-member advancing the ledger's head and round leaves the link intact" {
  require_jq
  build_linked_refusal
  edit_ledger "$LEDGER" "
    .head_sha = \"$(printf '%040d' 4)\"
    | .round = 5
    | .remaining += [{member: \"${OTHER_MEMBER}\", entry_id: \"r5-1\", finding_class: \"other-class\",
                      path: \"b.txt\", line: 2, title: \"another member's finding\"}]
    | .member_provenance[\"${OTHER_MEMBER}\"] = {refusal_digest: \"$(printf '%064d' 77)\",
                                                refusal_tree: \"$(printf '%040d' 6)\",
                                                refusal_sha: \"$(printf '%040d' 4)\",
                                                version: \"1.2.3\"}"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  assert_refusal_anchor
}

# The whole-team floor is deliberately NOT disabled by a refusal, and this
# probe pins that as decided rather than accidental. The status is
# posted only when no dispatched member is pending, and a member
# holding a live refusal IS pending, so a whole-team signal at or newer than
# the refused commit is evidence the refusal was already resolved (superseded
# by its author, or retired by a digest rotation).
@test "a whole-team signal newer than a refusal still anchors the member" {
  require_jq
  add_commit a
  write_clearance "$DEFAULT_MEMBER" refused "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit b
  team_anchor_sha="$(stamp_anchor)"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$team_anchor_sha" ]
  [ "$(member_reason)" = "team-signal" ]
  [ -z "$(member_anchor_tree)" ]
}

# -----------------------------------------------------------------------------
# Review depth. Only a marker carrying `review: full` anchors, in the member
# arm and, through the store scan, in the team-signal arm: the
# status is light-blind, so the resolver itself refuses to anchor the team arm
# past a non-full clearance of ANY member, or where no full review is on record.
# -----------------------------------------------------------------------------

@test "review depth: a light clearance after a full one never anchors" {
  require_jq
  add_commit a
  full_sha="$(sha_of HEAD)"
  full_tree="$(tree_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$full_tree" 1.2.3 full >/dev/null
  add_commit b
  light_tree="$(tree_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$light_tree" 1.2.3 light >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$full_sha" ]
  [ "$(member_reason)" = "member-clearance" ]
  [ "$(member_anchor_tree)" = "$full_tree" ]
  [ "$(member_anchor_tree)" != "$light_tree" ]
}

@test "review depth: a marker lacking the review field is not an anchor" {
  require_jq
  add_commit a
  full_sha="$(sha_of HEAD)"
  full_tree="$(tree_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$full_tree" 1.2.3 full >/dev/null
  add_commit b
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 none >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$full_sha" ]
  [ "$(member_reason)" = "member-clearance" ]
  [ "$(member_anchor_tree)" = "$full_tree" ]
}

@test "review depth: a status on a light-cleared commit does not anchor the team arm" {
  require_jq
  add_commit a
  full_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit b
  light_sha="$(stamp_anchor bare)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 light >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$full_sha" ]
  [ "$(member_base)" != "$light_sha" ]
  [ "$(member_reason)" = "member-clearance" ]
  grep -qF "non-full clearance at ${light_sha}" <<<"$stderr"
  # The shared floor keeps the signal: only the member's scope narrows less.
  [ "$(member_shared_base)" = "$light_sha" ]
}

@test "review depth: the same status anchors when the clearance at it is full" {
  require_jq
  add_commit a
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit b
  full_sha="$(stamp_anchor bare)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$full_sha" ]
}

# The scan covers every roster member. The resolving member's own stale-version
# full marker at the signal tree satisfies the "a full review is on record"
# half on its own, so only the OTHER member's light marker can disable the arm.
@test "review depth: another member's light clearance at the signal disables the team arm" {
  require_jq
  add_commit a
  full_sha="$(sha_of HEAD)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit b
  signal_sha="$(stamp_anchor bare)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 0.0.1 full >/dev/null
  write_clearance "$OTHER_MEMBER" earned "$(tree_of HEAD)" 1.2.3 light >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$full_sha" ]
  [ "$(member_base)" != "$signal_sha" ]
  [ "$(member_reason)" = "member-clearance" ]
  grep -qF "${OTHER_MEMBER} holds a non-full clearance at ${signal_sha}" <<<"$stderr"
}

@test "review depth: a non-full marker outside the range leaves the verified signal as the base" {
  require_jq
  add_commit a
  add_commit b
  signal_sha="$(stamp_anchor bare)"
  support_signal_at HEAD
  write_clearance "$OTHER_MEMBER" earned "$(printf '%040d' 7)" 1.2.3 light >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$signal_sha" ]
  [ "$(member_reason)" = "team-signal" ]
}

@test "review depth: the same signal anchors when the other member's clearance is full" {
  require_jq
  add_commit a
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit b
  signal_sha="$(stamp_anchor bare)"
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 0.0.1 full >/dev/null
  write_clearance "$OTHER_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$signal_sha" ]
  [ "$(member_reason)" = "team-signal" ]
}

@test "review depth: a light-only history has no anchor" {
  require_jq
  add_commit a
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 light >/dev/null
  add_commit b
  stamp_anchor bare >/dev/null
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 light >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  [ -z "$(member_anchor_tree)" ]
}

@test "review depth: a signal with an empty marker store refuses to anchor" {
  add_commit a
  add_commit b
  stamp_anchor bare >/dev/null
  add_commit c
  [ ! -d "$SANDBOX/.gaia/local/audit" ]

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  grep -qF "unverifiable" <<<"$stderr"
}

@test "review depth: a full review of another member at the signal tree lets the arm anchor" {
  require_jq
  add_commit a
  add_commit b
  signal_sha="$(stamp_anchor bare)"
  write_clearance "$OTHER_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$signal_sha" ]
  [ "$(member_reason)" = "team-signal" ]
  [ -z "$(member_anchor_tree)" ]
}

@test "review depth: a marker the reader cannot parse at the signal tree is unverifiable" {
  require_jq
  add_commit a
  add_commit b
  stamp_anchor bare >/dev/null
  marker_path="$(write_clearance "$OTHER_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full)"
  printf 'not json at all\n' > "$marker_path"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  grep -qF "unverifiable" <<<"$stderr"
}

@test "review depth: an unreadable roster refuses the team arm" {
  require_jq
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  rm -f "$SANDBOX/.gaia/audit-ci.yml"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  grep -qF "roster is unreadable" <<<"$stderr"
}

# Records every clearance_scan call (member and provenance) into the file the
# sandbox's reader copy appends to, so a test can see which stores were read.
trace_clearance_scans() {
  CLEARANCE_SCAN_TRACE="$BATS_TEST_TMPDIR/scan.trace"
  export CLEARANCE_SCAN_TRACE
  : > "$CLEARANCE_SCAN_TRACE"
  local reader="$SANDBOX/.claude/hooks/lib/audit-clearance.sh"
  awk '{ print } /^clearance_scan\(\) \{$/ { print "  printf \"%s %s\\n\" \"$2\" \"$3\" >>\"${CLEARANCE_SCAN_TRACE:-/dev/null}\"" }' "$reader" > "$reader.traced"
  mv "$reader.traced" "$reader"
  grep -qF 'CLEARANCE_SCAN_TRACE' "$reader"
}

@test "review depth: the roster scan is skipped when no whole-team signal is in range" {
  require_jq
  trace_clearance_scans
  add_commit a
  write_clearance "$OTHER_MEMBER" earned "$(tree_of HEAD)" 1.2.3 light >/dev/null
  add_commit b
  write_clearance "$SUPPORT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  grep -qF "non-full clearance" <<<"$stderr" && return 1
  [ "$(sort "$CLEARANCE_SCAN_TRACE" | tr '\n' ',')" = "${DEFAULT_MEMBER} earned,${DEFAULT_MEMBER} refused," ]
}

@test "review depth: a signal in range scans each roster member once and the resolving member only once" {
  require_jq
  trace_clearance_scans
  add_commit a
  add_commit b
  signal_sha="$(stamp_anchor)"
  add_commit c

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "$signal_sha" ]
  [ "$(grep -cxF "${DEFAULT_MEMBER} earned" "$CLEARANCE_SCAN_TRACE")" -eq 1 ]
  grep -qxF "${OTHER_MEMBER} earned" "$CLEARANCE_SCAN_TRACE"
  grep -qxF "${SUPPORT_MEMBER} earned" "$CLEARANCE_SCAN_TRACE"
  [ -z "$(sort "$CLEARANCE_SCAN_TRACE" | uniq -d)" ]
}

# -----------------------------------------------------------------------------
# Library availability. Four libs decide the answer and their absence resets
# to full scope; the clearance reader's absence is the CONTRAST, because it is
# the same condition as the empty store every continuous-integration run has.
# -----------------------------------------------------------------------------

# Remove one provisioned lib, then assert the member form degraded rather than
# emitting the candidate it would otherwise have anchored on.
assert_degraded_without() {
  local library_name="$1" base
  add_commit a
  base="$(stamp_anchor)"
  add_commit b
  rm -f "$SANDBOX/.claude/hooks/lib/${library_name}"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ] || return 1
  [ "$(member_line_count)" -eq 4 ] || return 1
  [ "$(member_base)" = "main" ] || return 1
  [ "$(member_base)" != "$base" ] || return 1
  [ "$(member_reason)" = "degraded" ] || return 1
  [ "$(member_shared_base)" = "main" ] || return 1
  grep -qF "$library_name" <<<"$stderr" || return 1
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

# -----------------------------------------------------------------------------
# The OTHER arm of "cannot be sourced": present, but unparseable.
#
# Every case above deletes the lib, so each one exercises the `[ -f ]` guard and
# none of them reaches the load. A lib that is present but syntactically broken
# passes that guard and fails at the load instead -- an interrupted
# `/update-gaia`, an unresolved merge conflict, or a truncated write all leave
# one on disk. Under the errexit this script arms at its top, a trailing
# `|| true` does not catch a parse failure on bash 3.2.57: the shell is
# abandoned AT the load and never reaches the `||`, so the resolver would exit
# emitting nothing instead of degrading to full scope, which inverts the
# fail-safe these tests are named for.
#
# The cases below are pinned to stock /bin/bash, and it is the pin rather than
# the fixture that decides. Measured both ways on this machine: 3.2.57 abandons
# the shell on the `|| true` form and survives on the bracketed one, while
# 5.3.15 survives on both. So on a bash-5 /bin/bash (Linux CI) these pass either
# way, and only 3.2 tells the two shapes apart. Dropping the pin would green
# them against the spelling they exist to reject.
# -----------------------------------------------------------------------------

# Overwrite <lib> in place with an unresolved-merge-conflict body: the file
# opens and reads fine, so the `[ -f ]` guard admits it, and bash cannot parse
# it. Deliberately not a deletion -- that is the arm above.
write_unparseable_library() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$SANDBOX/.claude/hooks/lib/${1}"
}

# Same assertions as assert_degraded_without, against the unparseable fixture
# and under the pinned interpreter.
assert_degraded_with_unparseable() {
  local library_name="$1" base
  add_commit a
  base="$(stamp_anchor)"
  add_commit b
  write_unparseable_library "$library_name"

  run --separate-stderr run_member "$DEFAULT_MEMBER" /bin/bash
  [ "$status" -eq 0 ] || return 1
  [ "$(member_line_count)" -eq 4 ] || return 1
  [ "$(member_base)" = "main" ] || return 1
  [ "$(member_base)" != "$base" ] || return 1
  [ "$(member_reason)" = "degraded" ] || return 1
  [ "$(member_shared_base)" = "main" ] || return 1
  grep -qF "$library_name" <<<"$stderr" || return 1
  return 0
}

# The control for the `degraded:` cases below. Without it they would stay green
# if the resolver stopped resolving entirely under 3.2, for a reason having
# nothing to do with either load shape. The clearance-reader case at the end
# needs no such control: it asserts `team-signal` rather than `degraded`, so a
# resolver that had stopped resolving could not satisfy it.
@test "unparseable control: with every lib intact, stock /bin/bash resolves normally" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  add_commit a
  base="$(stamp_anchor)"
  add_commit b

  run --separate-stderr run_member "$DEFAULT_MEMBER" /bin/bash
  [ "$status" -eq 0 ]
  [ "$(member_line_count)" -eq 4 ]
  [ "$(member_base)" = "$base" ]
  [ "$(member_reason)" = "team-signal" ]
  grep -qF "reason=degraded" <<<"$stderr" && return 1
  return 0
}

@test "degraded: the ownership classifier is present but unparseable" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  assert_degraded_with_unparseable "audit-scope.sh"
}

@test "degraded: the machinery matcher is present but unparseable" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  assert_degraded_with_unparseable "audit-machinery.sh"
}

@test "degraded: the rules-tier predicate is present but unparseable" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  assert_degraded_with_unparseable "audit-rules-changed.sh"
}

@test "degraded: the version normalizer is present but unparseable" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  assert_degraded_with_unparseable "gaia-version.sh"
}

# The clearance reader is the CONTRAST on this arm exactly as it is on the
# absent one: it is the fourth lib in the same load block, so an unparseable
# copy abandons the shell the same way, but its unavailability falls back to the
# floor rather than degrading. Without this case the library block's fourth
# member is the one load the unparseable arm never opens. Its unavailability
# does not degrade, but the team-signal arm cannot verify review depth without
# it, so the member form refuses the signal and the argument-less form (which
# reads no store) still anchors.
@test "an unparseable clearance reader refuses the team signal rather than degrading" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  add_commit a
  base="$(stamp_anchor)"
  add_commit b
  write_unparseable_library "audit-clearance.sh"

  run --separate-stderr run_member "$DEFAULT_MEMBER" /bin/bash
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  [ "$(member_shared_base)" = "$base" ]
  grep -qF "reason=degraded" <<<"$stderr" && return 1
  grep -qF "clearance reader is unavailable" <<<"$stderr"
}

@test "an absent clearance reader refuses the team signal rather than degrading" {
  add_commit a
  base="$(stamp_anchor)"
  add_commit b
  rm -f "$SANDBOX/.claude/hooks/lib/audit-clearance.sh"

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  [ "$(member_shared_base)" = "$base" ]
  grep -qF "reason=degraded" <<<"$stderr" && return 1
  grep -qF "clearance reader is unavailable" <<<"$stderr"
}

@test "an empty clearance store refuses the team signal and resolves the full-branch base" {
  add_commit a
  base="$(stamp_anchor bare)"
  add_commit b
  [ ! -d "$SANDBOX/.gaia/local/audit" ]

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-anchor" ]
  [ -z "$(member_anchor_tree)" ]
  [ "$(member_shared_base)" = "$base" ]
  grep -qF "unverifiable" <<<"$stderr"
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
  [ "$(member_line_count)" -eq 4 ]
  [ "$(member_reason)" = "member-clearance" ]
  [ -n "$(member_anchor_tree)" ]
  key="$(member_shared_base)"

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
  [ "$(member_line_count)" -eq 4 ]
  [ "$(member_base)" = "main" ]
  [ "$(member_reason)" = "no-version" ]
  [ "$(member_shared_base)" = "main" ]
  [ -z "$(member_anchor_tree)" ]
}

@test "the member form prints four lines on a reset path" {
  add_commit a
  stamp_anchor >/dev/null
  add_global_rules_commit

  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_line_count)" -eq 4 ]
  [ "$(member_reason)" = "rules-reset-global" ]
  [ -z "$(member_anchor_tree)" ]
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
# Characterization of the resolver outputs that a per-member anchor change must
# leave alone, compared against a golden recorded from the resolver before that
# change. The golden holds labels, never raw shas or trees (those differ on
# every run): a commit label the fixture assigns, `tree:<label>`, `main-ref`, a
# reason token, or `empty`.
# -----------------------------------------------------------------------------

CHARACTERIZATION_REASON_TOKENS=" no-anchor team-signal machinery-reset rules-reset-member rules-reset-global degraded no-version member-clearance "

characterization_golden_path() {
  printf '%s\n' "$THIS_DIRECTORY/fixtures/resolve-audit-base-characterization.golden"
}

# The forms a fixture captures: `argless` is line 1 of the argument-less form,
# `member4` all four --member lines, `member2` the first two.
characterization_forms() {
  case "$1" in
    refusal-only|team-older-than-refusal|machinery-after-team) printf '%s\n' "argless member4" ;;
    clearance-both-rules) printf '%s\n' "member2" ;;
    clearance-degraded|clearance-no-version) printf '%s\n' "member2 argless" ;;
    *) return 1 ;;
  esac
}

# Fixture names, derived from the builder functions below so a builder added
# without a golden record (or the reverse) is caught by the set-equality test.
characterization_fixture_names() {
  declare -F | awk '{ print $3 }' | grep '^characterization_build_' | sed 's/^characterization_build_//'
}

# Record <label> for the sha and tree of <ref>.
characterization_label() {
  printf '%s\t%s\n' "$(sha_of "$2")" "$1" >> "$CHARACTERIZATION_LABELS"
  printf '%s\t%s\n' "$(tree_of "$2")" "tree:$1" >> "$CHARACTERIZATION_LABELS"
}

characterization_render_value() {
  local value="$1" label
  if [ -z "$value" ]; then
    printf '%s\n' "empty"
    return 0
  fi
  if [ "$value" = "main" ]; then
    printf '%s\n' "main-ref"
    return 0
  fi
  case "$CHARACTERIZATION_REASON_TOKENS" in
    *" ${value} "*) printf '%s\n' "$value"; return 0 ;;
  esac
  label="$(awk -F '\t' -v value="$value" '$1 == value { print $2; exit }' "$CHARACTERIZATION_LABELS")"
  if [ -n "$label" ]; then
    printf '%s\n' "$label"
  else
    printf 'unlabelled:%s\n' "$value"
  fi
}

characterization_build_refusal-only() {
  add_commit a
  characterization_label A HEAD
  write_clearance "$DEFAULT_MEMBER" refused "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit b
  characterization_label B HEAD
}

characterization_build_team-older-than-refusal() {
  add_commit t
  stamp_anchor >/dev/null
  characterization_label T HEAD
  add_commit a
  characterization_label A HEAD
  write_clearance "$DEFAULT_MEMBER" refused "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit b
  characterization_label B HEAD
}

characterization_build_machinery-after-team() {
  add_commit t
  stamp_anchor >/dev/null
  characterization_label T HEAD
  add_commit a
  characterization_label A HEAD
  write_clearance "$DEFAULT_MEMBER" refused "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_machinery_commit
  add_commit b
  characterization_label B HEAD
}

characterization_build_clearance-both-rules() {
  add_commit a
  characterization_label A HEAD
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  mkdir -p "$SANDBOX/.claude/agents" "$SANDBOX/.claude/rules"
  echo "agent" > "$SANDBOX/.claude/agents/code-audit-frontend.md"
  echo "gate rule" > "$SANDBOX/.claude/rules/quality-gate.md"
  git -C "$SANDBOX" add .claude/agents/code-audit-frontend.md .claude/rules/quality-gate.md
  git -C "$SANDBOX" commit --quiet -m "agent definition and global rules"
  add_commit b
  characterization_label B HEAD
}

characterization_build_clearance-degraded() {
  add_commit a
  characterization_label A HEAD
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit b
  characterization_label B HEAD
  rm -f "$SANDBOX/.claude/hooks/lib/audit-scope.sh"
}

characterization_build_clearance-no-version() {
  add_commit a
  characterization_label A HEAD
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 full >/dev/null
  add_commit b
  characterization_label B HEAD
  rm -f "$SANDBOX/.gaia/VERSION"
}

# Build <fixture> in the sandbox, run the forms it captures, and print the
# rendered records in golden format.
characterization_render() {
  local fixture="$1" form line_number value
  CHARACTERIZATION_LABELS="$BATS_TEST_TMPDIR/characterization-labels"
  : > "$CHARACTERIZATION_LABELS"
  "characterization_build_${fixture}" || return 1
  for form in $(characterization_forms "$fixture"); do
    case "$form" in
      argless)
        value="$( cd "$SANDBOX" && "$SCRIPT" 2>/dev/null )" || return 1
        printf '%s argless 1 %s\n' "$fixture" "$(characterization_render_value "$value")"
        ;;
      member4|member2)
        run_member "$DEFAULT_MEMBER" 2>/dev/null || return 1
        for line_number in 1 2 3 4; do
          [ "$line_number" -le "${form#member}" ] || continue
          value="$(sed -n "${line_number}p" "$MEMBER_OUTPUT_FILE")"
          printf '%s member %s %s\n' "$fixture" "$line_number" "$(characterization_render_value "$value")"
        done
        ;;
    esac
  done
}

# Compare the rendered records for <fixture> with the golden's lines for it.
# $2 overrides the golden path. A fixture the golden has no line for fails
# rather than comparing empty to empty; the rendered text goes to stderr so a
# golden can be regenerated from a failing run against an unchanged resolver.
characterization_matches_golden() {
  local fixture="$1" golden="${2:-$(characterization_golden_path)}" actual expected
  actual="$(characterization_render "$fixture")" || return 1
  expected="$(grep -E "^${fixture} " "$golden" || true)"
  if [ -z "$expected" ]; then
    printf 'golden has no record for fixture %s; actual:\n%s\n' "$fixture" "$actual" >&2
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    printf 'fixture %s differs from the golden.\nexpected:\n%s\nactual:\n%s\n' "$fixture" "$expected" "$actual" >&2
    return 1
  fi
  return 0
}

# Assert the golden holds <count> records for <fixture>.
assert_characterization_count() {
  local fixture="$1" count="$2"
  [ "$(grep -cE "^${fixture} " "$(characterization_golden_path)")" -eq "$count" ]
}

@test "characterization: refusal-only fixture matches the golden" {
  require_jq
  characterization_matches_golden refusal-only
  assert_characterization_count refusal-only 5
}

@test "characterization: team-older-than-refusal fixture matches the golden" {
  require_jq
  characterization_matches_golden team-older-than-refusal
  assert_characterization_count team-older-than-refusal 5
}

@test "characterization: machinery-after-team fixture matches the golden" {
  require_jq
  characterization_matches_golden machinery-after-team
  assert_characterization_count machinery-after-team 5
}

@test "characterization: clearance-both-rules fixture matches the golden" {
  require_jq
  characterization_matches_golden clearance-both-rules
  assert_characterization_count clearance-both-rules 2
}

@test "characterization: clearance-degraded fixture matches the golden" {
  require_jq
  characterization_matches_golden clearance-degraded
  assert_characterization_count clearance-degraded 3
}

@test "characterization: clearance-no-version fixture matches the golden" {
  require_jq
  characterization_matches_golden clearance-no-version
  assert_characterization_count clearance-no-version 3
}

@test "characterization: the comparison fails on a deliberately wrong expected line" {
  require_jq
  wrong_golden="$BATS_TEST_TMPDIR/wrong.golden"
  sed 's/^refusal-only member 2 .*/refusal-only member 2 team-signal/' "$(characterization_golden_path)" > "$wrong_golden"
  grep -qxF "refusal-only member 2 team-signal" "$wrong_golden"
  characterization_matches_golden refusal-only "$wrong_golden" 2>/dev/null && return 1
  true
}

@test "characterization: the golden's fixture set equals the suite's fixture set" {
  golden_names="$(grep -v '^#' "$(characterization_golden_path)" | awk 'NF { print $1 }' | sort -u)"
  suite_names="$(characterization_fixture_names | sort -u)"
  [ -n "$suite_names" ]
  [ "$golden_names" = "$suite_names" ]
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
# Reason-token reachability: each token of the closed set the resolver's header
# lists must be emitted on at least one input. The tests above assert richer
# behavior on these same paths; this section exists so the set is enumerated in
# one place and a new token cannot be introduced unnoticed.
# =============================================================================

@test "reason token: member-clearance" {
  require_jq
  add_commit a
  add_commit b
  write_clearance "$DEFAULT_MEMBER" earned "$(tree_of HEAD)" 1.2.3 >/dev/null
  add_commit c
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_reason)" = "member-clearance" ]
}

@test "reason token: member-refusal" {
  require_jq
  build_linked_refusal
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_reason)" = "member-refusal" ]
  [ "$(member_base)" = "$REFUSED_SHA" ]
  [ "$(member_anchor_tree)" = "$REFUSED_TREE" ]
  grep -qF "member=${DEFAULT_MEMBER} base=${REFUSED_SHA} reason=member-refusal anchor_tree=${REFUSED_TREE}" <<<"$stderr"
}

@test "reason token: team-signal" {
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_reason)" = "team-signal" ]
}

@test "reason token: no-anchor" {
  add_commit a
  add_commit b
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_reason)" = "no-anchor" ]
}

@test "reason token: rules-reset-global" {
  add_commit a
  stamp_anchor >/dev/null
  add_global_rules_commit
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_reason)" = "rules-reset-global" ]
}

@test "reason token: rules-reset-member" {
  add_commit a
  stamp_anchor >/dev/null
  commit_append ".claude/agents/${DEFAULT_MEMBER}.md"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_reason)" = "rules-reset-member" ]
}

@test "reason token: machinery-reset" {
  add_commit a
  stamp_anchor >/dev/null
  commit_append ".claude/hooks/lib/cross-repo-refusal.sh"
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
  [ "$(member_reason)" = "degraded" ]
}

@test "reason token: no-version" {
  add_commit a
  stamp_anchor >/dev/null
  add_commit b
  rm -f "$SANDBOX/.gaia/VERSION"
  run --separate-stderr run_member "$DEFAULT_MEMBER"
  [ "$status" -eq 0 ]
  [ "$(member_reason)" = "no-version" ]
}
