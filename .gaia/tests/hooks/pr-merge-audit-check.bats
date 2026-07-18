#!/usr/bin/env bats

# Tests for .claude/hooks/pr-merge-audit-check.sh.
#
# The hook denies `gh pr merge` unless a code-review-audit signal exists for
# HEAD. Signal 5 (check_out_of_scope_pr) is a fail-closed allowlist bypass: it
# allows the merge when EVERY file the PR changes (vs its merge base with the
# default branch) lives outside audit scope; wiki/, .claude/, .specify/,
# .gaia/, docs/, and root-level markdown. Any in-scope path (app/, test/,
# configs, .github/workflows/) keeps the marker mandatory.
#
# Signal 6 (check_self_mod_only_update_pr) is a stricter sibling: it allows the
# merge when the ONLY in-scope path is .github/workflows/code-review-audit.yml
# AND its committed bytes are a verbatim re-render of the bundled template
# (.gaia/cli/templates/workflows/code-review-audit.yml.tmpl, proven by git-blob
# identity), with every other changed path out of scope. This is the self-mod-
# only case /update-gaia Step 12 produces; CI self-mod-skips such a PR so no
# GAIA-Audit stamp can land, but the changed bytes ARE GAIA's own template, not
# adopter code. Fail-closed: a non-matching workflow byte, a second in-scope
# path, or an absent template falls through to the normal deny.
#
# Every Code Audit Team marker is keyed to a member's own CONTENT DIGEST (a
# sha256 over exactly the files that member owns plus the shared gate
# machinery, folding the in-scope-but-ownerless paths into the default
# member's set), not the whole tree and not the commit. There is no
# carry-forward clearance machinery: a marker either validates for the
# CURRENT digest or it does not.
#
# Each test drives the hook exactly as the harness does: a PreToolUse JSON
# payload on stdin, run with the repo as the working directory (the hook uses
# bare `git`, not `git -C`). The hook always exits 0; allow vs deny is carried
# in stdout; a deny emits `"permissionDecision": "deny"`, an allow emits
# nothing. The in-scope (deny) cases double as a jq/setup canary: if jq were
# missing the hook would exit early with no output and those assertions would
# fail rather than false-pass.
#
# Setup models a PR: a base commit on `main`, then a `feature` branch carrying
# the change under test. merge-base(HEAD, main) resolves to the base commit, so
# the bypass diffs only the feature's files. No remote is needed; the hook
# falls back from `origin/main` to `main`.
#
# The real .gaia/scripts/resolve-audit-members.sh is copied into REPO
# (untracked, so it never appears in the diffs under test) so every case below
# exercises the hook exactly as it runs in the real repo, where the resolver
# is always present. The one test that needs the resolver-absent fallback
# removes this copy explicitly.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/pr-merge-audit-check.sh
  RESOLVER_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/resolve-audit-members.sh
  SPAWN_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/resolve-audit-spawn.sh
  LIB_DIR=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)
  REPO=$(mktemp -d -t pr-merge-test-XXXXXX)

  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  mkdir -p "$REPO/.gaia"
  printf '1.4.0\n' > "$REPO/.gaia/VERSION"
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add .gaia/VERSION README.md
  git -C "$REPO" commit --quiet -m "init"

  git -C "$REPO" checkout --quiet -b feature

  mkdir -p "$REPO/.gaia/scripts"
  cp "$RESOLVER_ABS" "$REPO/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$REPO/.gaia/scripts/resolve-audit-members.sh"
  cp "$SPAWN_ABS" "$REPO/.gaia/scripts/resolve-audit-spawn.sh"
  chmod +x "$REPO/.gaia/scripts/resolve-audit-spawn.sh"

  # The two copies above resolve their libs relative to THEMSELVES
  # ($REPO/.claude/hooks/lib/), not the real repo, so the sandbox needs its
  # own copy of the shared ownership classifier + digest engine + clearance
  # reader alongside them. The real hook (run by absolute path via
  # $HOOK_ABS, never copied) resolves its own libs to the real repo
  # regardless.
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$LIB_DIR/audit-scope.sh" "$REPO/.claude/hooks/lib/audit-scope.sh"
  cp "$LIB_DIR/audit-machinery.sh" "$REPO/.claude/hooks/lib/audit-machinery.sh"
  cp "$LIB_DIR/audit-clearance.sh" "$REPO/.claude/hooks/lib/audit-clearance.sh"
  cp "$LIB_DIR/audit-digest.sh" "$REPO/.claude/hooks/lib/audit-digest.sh"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Commit one or more files (path=content pairs) on the feature branch.
commit_files() {
  while [ "$#" -gt 0 ]; do
    local path="$1" content="$2"; shift 2
    mkdir -p "$REPO/$(dirname "$path")"
    printf '%s\n' "$content" > "$REPO/$path"
    git -C "$REPO" add "$path"
  done
  git -C "$REPO" commit --quiet -m "change"
}

# Seed the bundled audit-workflow template onto the BASE commit (main), out of
# the feature diff, then re-point feature at it. This mirrors the real
# /update-gaia self-mod PR: the template already exists on the base and only the
# installed .github/workflows/code-review-audit.yml is refreshed. The template is
# maintainer-shell-owned, so committing it in the feature diff would dispatch that
# member and defeat the frontend-only self-mod bypass under test; keeping it on
# the base leaves the diff self-mod-clean while still giving the blob-identity
# check a template to compare against. The template-absent case deliberately does
# NOT call this.
seed_base_template() {
  git -C "$REPO" checkout --quiet main
  mkdir -p "$REPO/.gaia/cli/templates/workflows"
  printf 'name: Code Review Audit\n' \
    > "$REPO/.gaia/cli/templates/workflows/code-review-audit.yml.tmpl"
  git -C "$REPO" add .gaia/cli/templates/workflows/code-review-audit.yml.tmpl
  git -C "$REPO" commit --quiet -m "seed bundled template on base"
  git -C "$REPO" checkout --quiet -B feature main
}

# Run the hook with a `gh pr merge` command, from inside the repo.
run_merge_hook() {
  local cmd="${1:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -n --arg c "$cmd" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c "cd '$REPO' && printf '%s' '$json' | bash '$HOOK_ABS'"
}

# Compute MEMBER's real content digest for REPO's current HEAD, via the real
# digest engine (never re-derived by hand), so fixtures stay in lockstep with
# whatever the hook itself would compute.
member_digest_for() {
  local member="$1"
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$LIB_DIR/audit-digest.sh" "$REPO" "$member"
}

# Write a Code Audit Team EARNED clearance marker for MEMBER, keyed to
# MEMBER's own content digest at REPO's current HEAD (schema 3). A marker
# attests that a member audited exactly the files it owns plus gate
# machinery, so it survives any change outside that set.
#   write_marker "code-audit-frontend"
#   write_marker "code-audit-maintainer-shell"
write_marker() {
  local member="$1" digest sha tree infix sidecar
  digest="$(member_digest_for "$member")"
  sha=$(git -C "$REPO" rev-parse HEAD)
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  if [ "$member" = "code-audit-frontend" ]; then infix=""; sidecar="true"; else infix=".$member"; sidecar="false"; fi
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$sidecar" \
    > "$REPO/.gaia/local/audit/${digest}${infix}.ok"
  # The frontend agent always writes a companion disposition sidecar in the
  # SAME audit run (sidecar:true above records that fact); mirror it here so
  # an ordinary marker fixture does not trip the C4 fail-closed
  # absent-sidecar check. The dedicated test for that check removes the
  # sidecar this writes; write_sidecar overwrites it for the offender tests.
  if [ "$member" = "code-audit-frontend" ] && [ ! -f "$REPO/.gaia/local/audit/${digest}.dispositions.json" ]; then
    printf '{"schema":1,"backend":"absent","findings":[]}\n' \
      > "$REPO/.gaia/local/audit/${digest}.dispositions.json"
  fi
}

# Write a REFUSAL artifact for MEMBER, keyed to the SAME digest write_marker
# would use right now (the current-content digest).
write_refused() {
  local member="$1" digest sha tree infix
  digest="$(member_digest_for "$member")"
  sha=$(git -C "$REPO" rev-parse HEAD)
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  if [ "$member" = "code-audit-frontend" ]; then infix=""; else infix=".$member"; fi
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":3,"member":"%s","provenance":"refused","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:01Z","sidecar":false}\n' \
    "$member" "$digest" "$tree" "$sha" \
    > "$REPO/.gaia/local/audit/${digest}${infix}.refused"
}

# Write a frontend disposition sidecar keyed to the frontend digest AT REPO's
# current HEAD.
write_sidecar() {
  local findings="${1:-[]}" backend="${2:-absent}" digest
  digest="$(member_digest_for code-audit-frontend)"
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"schema":1,"backend":"%s","findings":%s}\n' "$backend" "$findings" \
    > "$REPO/.gaia/local/audit/${digest}.dispositions.json"
}

# Print the spawn set the oracle resolves for REPO's current diff.
spawn_set() {
  ( cd "$REPO" && bash .gaia/scripts/resolve-audit-spawn.sh 2>/dev/null )
}

# Write an earned clearance marker for every name in a spawn-set
# (newline-separated) string.
write_markers_for_spawn_set() {
  local set="$1" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    write_marker "$name"
  done <<<"$set"
}

# Snapshot every file in the audit pool (name + content hash), to prove a run
# mints nothing.
pool_snapshot() {
  local dir="$REPO/.gaia/local/audit"
  [ -d "$dir" ] || { printf '<no-pool>'; return 0; }
  ( cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; shasum "$f" 2>/dev/null; done )
}

# Install a gh stub on a prepended PATH. `gh issue list` prints $1 (default []).
# GET statuses return null (so the frontend is NOT cleared via a CI status),
# `gh pr view` returns an empty title (no chore(deps) bypass).
install_gh_stub() {
  local issues="${1:-[]}"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  printf '%s' "$issues" > "$BATS_TEST_TMPDIR/issues.json"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
issues_file="$BATS_TEST_TMPDIR/issues.json"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) printf '\n'; exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

# Assert the most recent run_merge_hook call allowed the merge.
assert_allowed() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}

# Assert the most recent run_merge_hook call denied the merge.
assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  return 0
}

# Assert NAME is present as a whole line in NEWLINE-separated SET.
assert_in_set() {
  local name="$1" set="$2"
  grep -qxF -- "$name" <<<"$set" || return 1
  return 0
}

# Assert NAME is absent as a whole line from NEWLINE-separated SET.
assert_not_in_set() {
  local name="$1" set="$2"
  grep -qxF -- "$name" <<<"$set" && return 1
  return 0
}

@test "allows a docs/metadata-only PR (wiki + .claude + .gaia)" {
  # .claude/commands/*.md is ownerless docs. Skills prose (.claude/skills/**/*.md)
  # is audited by the prose member, so it belongs to the owned-surface cases below,
  # not here among the no-audit-needed docs.
  commit_files \
    ".claude/commands/gaia-spec.md" "updated" \
    "wiki/concepts/PR Merge Workflow.md" "updated" \
    ".gaia/manifest.json" "{}"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "allows a root-level markdown-only PR" {
  commit_files "README.md" "# changed"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "allows a docs-only PR under docs/" {
  commit_files "docs/guide.md" "guide"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR that changes app/ source" {
  commit_files "app/components/Foo/index.tsx" "export const Foo = () => null"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR that changes a root config (package.json)" {
  commit_files "package.json" '{"name":"x"}'
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR that changes a root *.config.ts" {
  commit_files "vitest.config.ts" "export default {}"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR mixing out-of-scope docs with in-scope source" {
  commit_files \
    "wiki/x.md" "doc" \
    "app/y.ts" "export const y = 1"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR that changes a CI workflow" {
  commit_files ".github/workflows/tests.yml" "name: t"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "ignores commands that are not gh pr merge" {
  commit_files "app/y.ts" "export const y = 1"
  run_merge_hook "git status"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# ---------------------------------------------------------------------------
# Signal 6: self-mod-only GAIA-update bypass (check_self_mod_only_update_pr).
# The single permitted in-scope path is .github/workflows/code-review-audit.yml
# AND its committed bytes must equal the bundled template. Commit BOTH paths
# with identical content so their git blobs match (commit_files appends the
# same trailing newline to each, so equal content => equal blob).
# ---------------------------------------------------------------------------

@test "allows a self-mod-only update PR (workflow bytes == bundled template)" {
  seed_base_template
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    "wiki/log.md" "entry"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "denies a workflow edit that does NOT match the bundled template" {
  # Adopter customization (self-hosted runner, extra secret) diverges from the
  # template, so there IS something to audit; the marker stays mandatory.
  seed_base_template
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit (customized)"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a verbatim workflow re-render smuggling in-scope source" {
  # A matching re-render cannot mask an app/ change; the marker is mandatory the
  # moment any auditable path appears.
  seed_base_template
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    "app/evil.ts" "export const evil = 1"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a workflow re-render when the bundled template is absent" {
  # Fail-closed: without the template on HEAD nothing proves the change is a
  # verbatim re-render, so the marker stays mandatory.
  commit_files ".github/workflows/code-review-audit.yml" "name: Code Review Audit"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a second workflow alongside the matching audit re-render" {
  # Only the audit workflow is a permitted in-scope path; any other workflow
  # file keeps the marker mandatory.
  seed_base_template
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    ".github/workflows/tests.yml" "name: Tests"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# ---------------------------------------------------------------------------
# AND-aggregator (FC-5): the dispatched member set drives a per-member
# clearance requirement instead of a single OR'd signal. SEC-001/UAT-002/018:
# one cleared member can never satisfy the gate while a co-dispatched member
# withholds. DP-001/CG-004: a zero-match diff falls through to the legacy
# out-of-scope gate above, NOT an unconditional allow.
# ---------------------------------------------------------------------------

@test "AND-aggregator: app-only diff allows once the frontend marker is present (regression)" {
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: mixed app/ + .gaia .sh diff denies while the maintainer-shell member withholds" {
  commit_files \
    "app/x.ts" "export const x = 1" \
    ".gaia/scripts/example.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: mixed app/ + .gaia .sh diff allows once both dispatched members clear" {
  commit_files \
    "app/x.ts" "export const x = 1" \
    ".gaia/scripts/example.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: .gaia .sh-only diff denies without the maintainer-shell marker (sole clearance, no frontend marker needed)" {
  commit_files ".gaia/scripts/example.sh" "#!/bin/bash"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: .gaia .sh-only diff allows once the maintainer-shell marker is present" {
  commit_files ".gaia/scripts/example.sh" "#!/bin/bash"
  write_marker "code-audit-maintainer-shell"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: root Dockerfile-only diff denies without a marker (zero-match falls through to the legacy gate, not an auto-allow)" {
  commit_files "Dockerfile" "FROM scratch"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: root Dockerfile-only diff allows once the legacy marker is present" {
  commit_files "Dockerfile" "FROM scratch"
  write_marker "code-audit-frontend"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: resolver script absent falls back to the single-signal path (no crash, same branch as zero-match)" {
  rm -f "$REPO/.gaia/scripts/resolve-audit-members.sh"
  commit_files "app/z.ts" "export const z = 1"
  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1

  write_marker "code-audit-frontend"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# The regression digest keying exists for. Every dispatched member audits its
# own owned-plus-machinery content and writes its marker; code-audit-frontend
# then stamps the GAIA-Audit trailer, which lands as an EMPTY commit -- HEAD
# advances, every blob stays byte-identical. A member's digest is a sha256
# over blob shas, so it does not rotate either, and no sibling member's marker
# is orphaned by the stamp.
@test "AND-aggregator: every member's marker survives the trailer stamp's empty commit (digest is content-keyed)" {
  commit_files "app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"

  before_frontend="$(member_digest_for code-audit-frontend)"
  before_shell="$(member_digest_for code-audit-maintainer-shell)"
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(member_digest_for code-audit-frontend)" = "$before_frontend" ]
  [ "$(member_digest_for code-audit-maintainer-shell)" = "$before_shell" ]

  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# ---------------------------------------------------------------------------
# UAT-001 (flagship): an out-of-glob-only commit rotates no member's digest,
# so every existing marker keeps validating with ZERO re-dispatch and ZERO
# new marker minting, at both the spawn oracle and the merge gate.
# ---------------------------------------------------------------------------

@test "UAT-001: an out-of-glob commit (CHANGELOG.md) leaves every digest unchanged; zero re-dispatch, zero new marker" {
  commit_files "app/x.ts" "export const x = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  frontend_before="$(member_digest_for code-audit-frontend)"
  shell_before="$(member_digest_for code-audit-maintainer-shell)"

  commit_files "CHANGELOG.md" "## [Unreleased]\n- entry"

  [ "$(member_digest_for code-audit-frontend)" = "$frontend_before" ]
  [ "$(member_digest_for code-audit-maintainer-shell)" = "$shell_before" ]

  set=$(spawn_set)
  [ -z "$set" ]

  before_pool="$(pool_snapshot)"
  run_merge_hook
  assert_allowed
  after_pool="$(pool_snapshot)"
  [ "$before_pool" = "$after_pool" ]
}

# ---------------------------------------------------------------------------
# UAT-002: a change to a file a single member owns rotates exactly that
# member's digest; every unrelated member keeps its clearance.
# ---------------------------------------------------------------------------

@test "UAT-002: a maintainer-node-owned change rotates only that member's digest" {
  commit_files "app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x" ".gaia/cli/src/foo.ts" "export const foo = 1"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  write_marker "code-audit-maintainer-node"
  frontend_before="$(member_digest_for code-audit-frontend)"
  shell_before="$(member_digest_for code-audit-maintainer-shell)"

  commit_files ".gaia/cli/src/foo.ts" "export const foo = 2"

  [ "$(member_digest_for code-audit-frontend)" = "$frontend_before" ]
  [ "$(member_digest_for code-audit-maintainer-shell)" = "$shell_before" ]

  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1
  grep -qF "code-audit-frontend: CLEARED" <<< "$output" || return 1
  grep -qF "code-audit-maintainer-shell: CLEARED" <<< "$output" || return 1
  grep -qF "code-audit-maintainer-node: PENDING" <<< "$output" || return 1

  write_marker "code-audit-maintainer-node"
  run_merge_hook
  assert_allowed
}

# ---------------------------------------------------------------------------
# UAT-003: a gate-machinery change rotates every member's digest, so the
# full team is re-dispatched, not just the owner of the touched file.
# ---------------------------------------------------------------------------

@test "UAT-003: a machinery-file change rotates every member's digest and re-dispatches the full team" {
  commit_files "app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x" ".gaia/cli/src/foo.ts" "export const foo = 1"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  write_marker "code-audit-maintainer-node"

  # audit-write-clearance.sh is gate machinery, and (unlike audit-scope.sh /
  # audit-machinery.sh / audit-clearance.sh) is NOT one of the fixture copies
  # setup() places under $REPO/.claude/hooks/lib/ for the sandboxed resolver
  # scripts' own dependency resolution, so writing it here cannot clobber
  # those and break the resolver. A change to it rotates EVERY digest.
  commit_files ".gaia/scripts/audit-write-clearance.sh" "# machinery touch"

  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1
  grep -qF "code-audit-frontend: PENDING" <<< "$output" || return 1
  grep -qF "code-audit-maintainer-shell: PENDING" <<< "$output" || return 1
  grep -qF "code-audit-maintainer-node: PENDING" <<< "$output" || return 1
}

# ---------------------------------------------------------------------------
# UAT-004 / C6: the gate checks the refused family before the earned family,
# so a live refusal for the current digest denies unconditionally even with a
# same-digest earned marker present.
# ---------------------------------------------------------------------------

@test "UAT-004: a live refusal for the SAME digest denies even with a valid earned marker present (frontend)" {
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  write_refused "code-audit-frontend"

  run_merge_hook
  assert_denied
}

@test "UAT-004: refusal precedence also applies to a specialized member" {
  commit_files "app/x.ts" "export const x = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  write_refused "code-audit-maintainer-shell"

  run_merge_hook
  assert_denied
  grep -qF "code-audit-maintainer-shell: REFUSED" <<< "$output" || return 1
}

# ---------------------------------------------------------------------------
# UAT-011: the in-scope-but-ownerless band is closed structurally by the
# frontend digest fold, not by a bespoke guard. A stale frontend marker
# (earned before an ownerless in-scope path was added) no longer validates.
# ---------------------------------------------------------------------------

@test "UAT-011: a stale frontend marker does not clear a merge that adds an in-scope-but-ownerless Dockerfile" {
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  commit_files "Dockerfile" "FROM scratch"

  run_merge_hook
  assert_denied
}

@test "UAT-011: a stale frontend marker does not clear a merge that adds a nested ownerless public asset" {
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  commit_files "public/logo.svg" "<svg></svg>"

  run_merge_hook
  assert_denied
}

# ---------------------------------------------------------------------------
# C4: the disposition read is re-keyed to the frontend digest and runs
# whenever the frontend's own earned marker is valid (not only after a
# carry, there is no carry-forward anymore). Fail closed on an absent
# sidecar; deny on an offender; allow on a clean sidecar.
# ---------------------------------------------------------------------------

@test "C4: frontend marker valid but disposition sidecar absent denies (fail-closed)" {
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  # write_marker auto-pairs a clean sidecar (mirroring the real agent flow);
  # remove it to exercise the fail-closed absent-sidecar path specifically.
  digest="$(member_digest_for code-audit-frontend)"
  rm -f "$REPO/.gaia/local/audit/${digest}.dispositions.json"

  run_merge_hook
  assert_denied
  grep -qF "disposition sidecar" <<< "$output" || return 1
}

@test "C4: a filed disposition whose issue no longer exists denies on the normal earned path" {
  install_gh_stub '[]'
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  write_sidecar '[{"key":"v1 class=x path=app/x.ts line=1","disposition":"filed"}]' "github"

  run_merge_hook
  assert_denied
  grep -qF "filed-but-missing" <<< "$output" || return 1
  grep -qF "v1 class=x path=app/x.ts line=1" <<< "$output" || return 1
}

@test "C4: a clean disposition sidecar allows the merge" {
  install_gh_stub '[]'
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  write_sidecar '[]' "absent"

  run_merge_hook
  assert_allowed
}

# ---------------------------------------------------------------------------
# FC-4 deadlock-freedom invariant: the spawn oracle's output and the merge
# gate's clearance requirements derive from the same source of truth.
#
#   No deadlock:     write a marker for every name the oracle prints for a
#                     diff -> the hook must ALLOW. If it denies, the gate
#                     wants a marker the spawn procedure never produces.
#   No useless spawn: withhold one spawned member's marker (all others
#                     present) -> the hook must DENY. If it allows, that
#                     member was spawned for nothing.
#
# The hazard: a zero-match dispatch does NOT auto-allow. The hook falls
# through to the legacy out-of-scope gate, which still demands the default
# member's clearance unless every changed path is on its allowlist. An
# in-scope-but-ownerless diff (root Dockerfile, public/**, ...) therefore
# resolves to an EMPTY dispatched set yet still DENIES without that
# clearance; the oracle's ownerless probe is what covers it.
# ---------------------------------------------------------------------------

@test "FC-4 no-deadlock: app/x.tsx spawns the default member alone, and its marker allows" {
  commit_files "app/x.tsx" "export const X = 1"
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: root tsconfig.json spawns the default member alone, and its marker allows" {
  commit_files "tsconfig.json" '{"compilerOptions":{}}'
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: a CI workflow spawns the workflows member only (not the default), and its marker allows" {
  commit_files ".github/workflows/ci.yml" "name: CI"
  set=$(spawn_set)
  [ "$set" = "code-audit-github-workflows" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: framework shell spawns the shell member only (not the default), and its marker allows" {
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-shell" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: framework CLI TypeScript spawns the node member only (not the default), and its marker allows" {
  commit_files ".gaia/cli/src/foo.ts" "export const foo = 1"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-node" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: mixed app/ + framework shell spawns both, sorted, and their markers allow" {
  commit_files "app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  expected=$'code-audit-frontend\ncode-audit-maintainer-shell'
  [ "$set" = "$expected" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: wiki + .claude + root markdown spawns nobody, and no markers still allows" {
  # .claude/commands/ is out of audit scope and owned by no roster member.
  # .claude/rules/** and .claude/agents/code-audit-*.md ARE maintainer-shell-owned,
  # so this uses a genuinely-ownerless .claude path to keep the spawn set empty.
  commit_files \
    "wiki/x.md" "doc" \
    ".claude/commands/y.md" "command" \
    "README.md" "# changed again"
  set=$(spawn_set)
  [ -z "$set" ]
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: root Dockerfile (in-scope, ownerless) denies unmarked and allows once spawned" {
  commit_files "Dockerfile" "FROM scratch"
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]

  # The hazard, made concrete: the dispatched set is empty (nothing OWNS a
  # Dockerfile), but the legacy out-of-scope gate still denies because
  # Dockerfile is in-scope. Writing no markers must still deny.
  run_merge_hook
  assert_denied

  # The oracle's ownerless probe names the default member for exactly this
  # case, so spawning it and writing its marker clears the gate.
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: nested public/** (in-scope, ownerless) denies unmarked and allows once spawned" {
  commit_files "public/logo.svg" "<svg></svg>"
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]

  run_merge_hook
  assert_denied

  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-deadlock: ownerless Dockerfile riding with a specialized member spawns the specialized member only" {
  # The dispatched set here is non-empty (the shell member owns y.sh), so the
  # hook takes the member-aware path and never reaches its legacy out-of-scope
  # gate: the Dockerfile is audited by nobody. This is the gate's own
  # documented behavior (FC-4's ownerless-plus-specialized row), not a defect,
  # and the oracle mirrors it exactly. Do NOT "fix" the oracle to add the
  # default member here: that would spawn a member the gate does not require,
  # breaking the no-useless-spawn half of the invariant.
  commit_files "Dockerfile" "FROM scratch" ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-shell" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed
}

# --- No useless spawn: withholding a spawned member's marker must deny -----

@test "FC-4 no-useless-spawn: mixed diff denies while only the default member's marker is present" {
  commit_files "app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_denied
}

@test "FC-4 no-useless-spawn: mixed diff denies with only the shell marker, then allows once both are present" {
  commit_files "app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-maintainer-shell"
  run_merge_hook
  assert_denied

  write_marker "code-audit-frontend"
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-useless-spawn: framework-shell-only diff denies with a frontend marker instead of the shell one" {
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_denied
}
