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

# The permit-diagnostic case below asserts stdout and stderr independently,
# which needs `run --separate-stderr` (bats >= 1.5.0).
bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
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
  # reader + base provenance resolver alongside them. The real hook (run by
  # absolute path via $HOOK_ABS, never copied) resolves its own libs to the
  # real repo regardless.
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$LIB_DIR/audit-scope.sh" "$REPO/.claude/hooks/lib/audit-scope.sh"
  cp "$LIB_DIR/audit-machinery.sh" "$REPO/.claude/hooks/lib/audit-machinery.sh"
  cp "$LIB_DIR/audit-clearance.sh" "$REPO/.claude/hooks/lib/audit-clearance.sh"
  cp "$LIB_DIR/audit-digest.sh" "$REPO/.claude/hooks/lib/audit-digest.sh"
  cp "$LIB_DIR/audit-base-provenance.sh" "$REPO/.claude/hooks/lib/audit-base-provenance.sh"
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

# Run the hook with a `gh pr merge` command, against an arbitrary ROOT. The
# root-parameterized twin of run_merge_hook.
run_merge_hook_at() {
  local root="$1" cmd="${2:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -n --arg c "$cmd" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$root" "$json" "$HOOK_ABS"
}

# Run the hook with a `gh pr merge` command, from inside the repo.
run_merge_hook() {
  run_merge_hook_at "$REPO" "${1:-gh pr merge 30 --squash --delete-branch}"
}

# Compute MEMBER's real content digest for REPO's current HEAD, via the real
# digest engine (never re-derived by hand), so fixtures stay in lockstep with
# whatever the hook itself would compute.
member_digest_for() {
  local member="$1"
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$LIB_DIR/audit-digest.sh" "$REPO" "$member"
}

# Write a Code Audit Team EARNED clearance marker for MEMBER, keyed to
# MEMBER's own content digest at ROOT's current HEAD (schema 3). The
# root-parameterized twin of write_marker, built on member_digest_at.
#   write_marker_at "$WT" "code-audit-frontend"
write_marker_at() {
  local root="$1" member="$2" digest sha tree infix sidecar
  digest="$(member_digest_at "$root" "$member")"
  sha=$(git -C "$root" rev-parse HEAD)
  tree=$(git -C "$root" rev-parse "HEAD^{tree}")
  if [ "$member" = "code-audit-frontend" ]; then infix=""; sidecar="true"; else infix=".$member"; sidecar="false"; fi
  mkdir -p "$root/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$sidecar" \
    > "$root/.gaia/local/audit/${digest}${infix}.ok"
  # The frontend agent always writes a companion disposition sidecar in the
  # SAME audit run (sidecar:true above records that fact); mirror it here so
  # an ordinary marker fixture does not trip the C4 fail-closed
  # absent-sidecar check. The dedicated test for that check removes the
  # sidecar this writes; write_sidecar_at overwrites it for the offender
  # tests.
  if [ "$member" = "code-audit-frontend" ] && [ ! -f "$root/.gaia/local/audit/${digest}.dispositions.json" ]; then
    printf '{"schema":1,"backend":"absent","findings":[]}\n' \
      > "$root/.gaia/local/audit/${digest}.dispositions.json"
  fi
}

# Write a Code Audit Team EARNED clearance marker for MEMBER, keyed to
# MEMBER's own content digest at REPO's current HEAD (schema 3). A marker
# attests that a member audited exactly the files it owns plus gate
# machinery, so it survives any change outside that set.
#   write_marker "code-audit-frontend"
#   write_marker "code-audit-maintainer-shell"
write_marker() {
  write_marker_at "$REPO" "$1"
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

# Write a frontend disposition sidecar keyed to the frontend digest AT ROOT's
# current HEAD. The root-parameterized twin of write_sidecar.
write_sidecar_at() {
  local root="$1" findings="${2:-[]}" backend="${3:-absent}" digest
  digest="$(member_digest_at "$root" code-audit-frontend)"
  mkdir -p "$root/.gaia/local/audit"
  printf '{"schema":1,"backend":"%s","findings":%s}\n' "$backend" "$findings" \
    > "$root/.gaia/local/audit/${digest}.dispositions.json"
}

# Write a frontend disposition sidecar keyed to the frontend digest AT REPO's
# current HEAD.
write_sidecar() {
  write_sidecar_at "$REPO" "${1:-[]}" "${2:-absent}"
}

# make_no_base_repo_pr <name>
#
# A standalone repo whose branch is not `main`, carries no `origin` remote,
# and has no `main` branch, so the FULL_BASE-style three-level chain
# (_disposition_changed_set, mirroring the write-side derivation) cannot
# resolve. Seeds .gaia/VERSION so the gate's version read succeeds. Asserts,
# before returning, that neither merge-base arm the derivation tries
# resolves, so the fixture cannot silently degrade into the resolved path
# and green.
make_no_base_repo_pr() {
  local name="$1" dir
  dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.gaia"
  git -C "$dir" init --quiet --initial-branch=master
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
  printf '1.4.0\n' > "$dir/.gaia/VERSION"
  git -C "$dir" add .gaia/VERSION
  git -C "$dir" commit --quiet -m "init"
  printf 'second\n' > "$dir/.gaia/second.txt"
  git -C "$dir" add .gaia/second.txt
  git -C "$dir" commit --quiet -m "second"

  if git -C "$dir" merge-base HEAD origin/main >/dev/null 2>&1; then
    echo "make_no_base_repo_pr: origin/main unexpectedly resolved" >&2
    return 1
  fi
  if git -C "$dir" merge-base HEAD main >/dev/null 2>&1; then
    echo "make_no_base_repo_pr: main unexpectedly resolved" >&2
    return 1
  fi
  printf '%s' "$dir"
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
# `gh pr view` returns the PR record the hook reads once: an empty title (no
# chore(deps) bypass) and an empty base ref (so the base derivation falls back
# to the remote's advertised default).
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
  pr) printf '{"title":"","baseRefName":""}\n'; exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

# Same stub, but the PR record carries $1 as the title, so the chore(deps)
# bypass can actually fire. Every other case above leaves the title empty, which
# is why no test here exercised the bypass's allow path. jq builds the record
# rather than a printf format, so a title carrying a quote or a backslash stays
# valid JSON instead of silently emptying the field the test is pinning.
install_gh_stub_with_title() {
  local title="$1"
  install_gh_stub "${2:-[]}"
  printf '%s' "$title" > "$BATS_TEST_TMPDIR/pr-title.txt"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
issues_file="$BATS_TEST_TMPDIR/issues.json"
title_file="$BATS_TEST_TMPDIR/pr-title.txt"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) jq -n --arg t "$(cat "$title_file")" '{title:$t, baseRefName:""}'; exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
}

# Put the real chore(deps) predicate in the sandbox's ACTING tree, which is
# where the hook resolves it from.
install_chore_deps_predicate() {
  local src
  src=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/chore-deps-skip.sh
  mkdir -p "$REPO/.gaia/scripts"
  cp "$src" "$REPO/.gaia/scripts/chore-deps-skip.sh"
  chmod +x "$REPO/.gaia/scripts/chore-deps-skip.sh"
}

# Assert the most recent run_merge_hook call allowed the merge.

# Assert the most recent run_merge_hook call denied the merge.

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
  # not here among the no-audit-needed docs. The .gaia/ file is a README for the
  # same reason: the roster grants .gaia/*.json to the shell member, so the
  # manifest is audited metadata rather than the unaudited kind this case is about.
  commit_files \
    ".claude/commands/gaia-spec.md" "updated" \
    "wiki/concepts/PR Merge Workflow.md" "updated" \
    ".gaia/templates/README.md" "updated"
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

# The witness here must be a root path in scope that NO member claims, or the
# pair below stops exercising the zero-match legacy branch and silently becomes
# two more member-aware cases. Two candidates fail that bar for opposite
# reasons: `Dockerfile` is claimed by the default member, and `.editorconfig` is
# allowlisted outright, so it never reaches the legacy gate's denylist. A root
# `Makefile` is neither.
@test "AND-aggregator: root Makefile-only diff denies without a marker (zero-match falls through to the legacy gate, not an auto-allow)" {
  commit_files "Makefile" "all:"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: root Makefile-only diff allows once the legacy marker is present" {
  commit_files "Makefile" "all:"
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

@test "AND-aggregator: a resolver that CANNOT answer denies instead of falling through to the legacy path" {
  # A non-zero resolver exit means the audited root did not resolve, which is
  # never "nothing owed". The diff below is entirely out of scope, so the
  # legacy single-signal path would ALLOW it: only the unanswerable-query deny
  # can produce a denial here, which is what makes this test discriminating.
  printf '#!/usr/bin/env bash\nexit 2\n' > "$REPO/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$REPO/.gaia/scripts/resolve-audit-members.sh"
  commit_files "docs/guide.md" "guide"
  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1
  grep -qF 'resolve-audit-members.sh' <<< "$output" || return 1
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
  assert_allowed_by_json
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
  assert_allowed_by_json
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
  assert_denied_by_json
}

@test "UAT-004: refusal precedence also applies to a specialized member" {
  commit_files "app/x.ts" "export const x = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  write_marker "code-audit-maintainer-shell"
  write_refused "code-audit-maintainer-shell"

  run_merge_hook
  assert_denied_by_json
  grep -qF "code-audit-maintainer-shell: REFUSED" <<< "$output" || return 1
}

# ---------------------------------------------------------------------------
# UAT-011: the in-scope-but-ownerless band is closed structurally by the
# frontend digest fold, not by a bespoke guard. A stale frontend marker
# (earned before an ownerless in-scope path was added) no longer validates.
# ---------------------------------------------------------------------------

@test "UAT-011: a stale frontend marker does not clear a merge that adds an in-scope-but-ownerless root Makefile" {
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  commit_files "Makefile" "all:"

  run_merge_hook
  assert_denied_by_json
}

@test "UAT-011: a stale frontend marker does not clear a merge that adds a nested ownerless public asset" {
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  commit_files "public/logo.svg" "<svg></svg>"

  run_merge_hook
  assert_denied_by_json
}

# The converse, and the reason the .editorconfig witness above had to move to a
# root Makefile: a path the allowlist carries sits OUTSIDE the fold, so adding
# one leaves the frontend's digest where it was and its marker still valid.
# Pinning the band from one side only would let a widening that swallowed a path
# the member does read still green the rows above.
@test "UAT-011: an allowlisted path added after the marker leaves that marker valid" {
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  commit_files ".editorconfig" "root = true" ".gitignore" "node_modules"

  run_merge_hook
  assert_allowed_by_json
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
  assert_denied_by_json
  grep -qF "disposition sidecar" <<< "$output" || return 1
}

@test "C4: a filed disposition whose issue no longer exists denies on the normal earned path" {
  install_gh_stub '[]'
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  write_sidecar '[{"key":"v1 class=x path=app/x.ts line=1","disposition":"filed"}]' "github"

  run_merge_hook
  assert_denied_by_json
  grep -qF "filed-but-missing" <<< "$output" || return 1
  grep -qF "v1 class=x path=app/x.ts line=1" <<< "$output" || return 1
}

@test "C4: a clean disposition sidecar allows the merge" {
  install_gh_stub '[]'
  commit_files "app/x.ts" "export const x = 1"
  write_marker "code-audit-frontend"
  write_sidecar '[]' "absent"

  run_merge_hook
  assert_allowed_by_json
}

# ---------------------------------------------------------------------------
# machinery_waived abuse-check at the merge gate: arm (c) of
# disposition_offenders is the union of the gate-machinery path set and this
# pull request's own changed-file set. Every case here needs a valid
# frontend marker AND a sidecar with a non-absent backend (write_marker's
# auto-seeded "absent" backend short-circuits disposition_offenders before
# arm (c) ever runs), so each writes the sidecar explicitly.
# ---------------------------------------------------------------------------

@test "machinery_waived abuse-check: near-miss keys (including a directory-prefix key) all deny at the merge gate" {
  commit_files "app/x.ts" "export const x = 1" "docs/readme.md" "docs"

  # Advance main past the fork point so a path main gained after the fork is
  # a real candidate near-miss: present on the tree, absent from THIS
  # branch's changed-file set.
  git -C "$REPO" checkout --quiet main
  mkdir -p "$REPO/unrelated"
  printf 'only on main\n' > "$REPO/unrelated/only-main.md"
  git -C "$REPO" add unrelated/only-main.md
  git -C "$REPO" commit --quiet -m "advance main past the fork point"
  git -C "$REPO" checkout --quiet feature

  write_marker "code-audit-frontend"
  # app/y.ts, app/x.tsx, x.ts, vendor/app/x.ts probe the SUFFIX/substring
  # directions; unrelated/only-main.md probes "on the tree but not in this
  # branch's diff"; app/x probes the PREFIX direction, a waived path that is
  # a directory-prefix of the changed app/x.ts, which only an exact
  # whole-string equality test (never a `case "$_p" in "$want"*)` prefix
  # match) correctly rejects.
  write_sidecar '[
    {"key":"v1 class=x path=app/y.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"},
    {"key":"v1 class=x path=app/x.tsx line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"},
    {"key":"v1 class=x path=x.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"},
    {"key":"v1 class=x path=vendor/app/x.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"},
    {"key":"v1 class=x path=unrelated/only-main.md line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"},
    {"key":"v1 class=x path=app/x line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}
  ]' "github"

  run_merge_hook
  assert_denied_by_json
  grep -qF "machinery-waived-not-eligible: v1 class=x path=app/y.ts line=1" <<<"$output" || return 1
  grep -qF "machinery-waived-not-eligible: v1 class=x path=app/x.tsx line=1" <<<"$output" || return 1
  grep -qF "machinery-waived-not-eligible: v1 class=x path=x.ts line=1" <<<"$output" || return 1
  grep -qF "machinery-waived-not-eligible: v1 class=x path=vendor/app/x.ts line=1" <<<"$output" || return 1
  grep -qF "machinery-waived-not-eligible: v1 class=x path=unrelated/only-main.md line=1" <<<"$output" || return 1
  grep -qF "machinery-waived-not-eligible: v1 class=x path=app/x line=1" <<<"$output" || return 1
}

@test "machinery_waived abuse-check: a key on a path this branch actually changed clears the merge" {
  commit_files "app/x.ts" "export const x = 1" "docs/readme.md" "docs"
  write_marker "code-audit-frontend"

  # First prove the disposition arm is genuinely reached: a sibling offender
  # in the SAME sidecar must deny, so the eventual "no deny" assertion below
  # cannot pass on a gate that read nothing.
  write_sidecar '[
    {"key":"v1 class=x path=app/y.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"},
    {"key":"v1 class=x path=app/x.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}
  ]' "github"
  run_merge_hook
  assert_denied_by_json
  grep -qF "machinery-waived-not-eligible: v1 class=x path=app/y.ts line=1" <<<"$output" || return 1

  # Drop the sibling offender; the surviving entry is keyed to app/x.ts, a
  # path this branch's diff against the fork point genuinely contains.
  write_sidecar '[{"key":"v1 class=x path=app/x.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}]' "github"
  run_merge_hook
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  assert_allowed_by_json
}

@test "machinery_waived abuse-check: an unresolvable base still denies a non-machinery key (gate-machinery term, not the git failure)" {
  local repo
  repo="$(make_no_base_repo_pr no-base-nonmachinery)"
  write_marker_at "$repo" "code-audit-frontend"
  write_sidecar_at "$repo" '[{"key":"v1 class=x path=app/other.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}]' "github"

  run_merge_hook_at "$repo"
  assert_denied_by_json
  grep -qF "machinery-waived-not-eligible: v1 class=x path=app/other.ts line=1" <<<"$output" || return 1
}

@test "machinery_waived abuse-check: an unresolvable base still clears a gate-machinery key, with a changed-files-unverified note" {
  local repo json
  repo="$(make_no_base_repo_pr no-base-machinery)"
  write_marker_at "$repo" "code-audit-frontend"
  write_sidecar_at "$repo" '[{"key":"v1 class=x path=.claude/hooks/lib/audit-machinery.sh line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}]' "github"

  # The note is written to stderr; stdout stays JSON-only (both hooks always
  # exit 0). Merge stderr into $output explicitly rather than rely on bats'
  # own stdout/stderr handling, so this assertion is not sensitive to it.
  json=$(jq -n --arg c "gh pr merge 30 --squash --delete-branch" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c "cd '$repo' && printf '%s' '$json' | bash '$HOOK_ABS' 2>&1"

  # First assert positively that the gate reached the disposition arm, so
  # this case cannot pass on a gate that returned before reading anything.
  grep -qF "changed-files-unverified: v1 class=x path=.claude/hooks/lib/audit-machinery.sh line=1" <<<"$output" || return 1
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  assert_allowed_by_json
}

@test "machinery_waived abuse-check: a resolved base with a genuinely empty diff still denies a non-machinery key, with no note" {
  # setup() leaves feature at the exact same commit as main (no divergence
  # yet), so merge-base(HEAD, main) resolves to HEAD itself and the
  # three-dot diff is legitimately empty: a resolved base, not an
  # unresolved one.
  write_marker "code-audit-frontend"
  write_sidecar '[{"key":"v1 class=x path=app/other.ts line=1","severity":"suggestion","security_class":false,"disposition":"machinery_waived"}]' "github"

  local json
  json=$(jq -n --arg c "gh pr merge 30 --squash --delete-branch" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c "cd '$REPO' && printf '%s' '$json' | bash '$HOOK_ABS' 2>&1"

  grep -qF "machinery-waived-not-eligible: v1 class=x path=app/other.ts line=1" <<<"$output" || return 1
  assert_denied_by_json
  grep -qF "changed-files-unverified" <<<"$output" && return 1
  grep -qF "changed-files-not-attributable" <<<"$output" && return 1
  return 0
}

@test "machinery_waived abuse-check: an unresolvable base alone does not block a merge with no machinery_waived entries" {
  local repo
  repo="$(make_no_base_repo_pr no-base-empty)"
  write_marker_at "$repo" "code-audit-frontend"

  # First prove the disposition arm is reached: a pending(definitive) entry
  # (an arm unconditional on the diff base) must deny.
  write_sidecar_at "$repo" '[{"key":"v1 class=x path=sibling line=1","severity":"suggestion","security_class":false,"disposition":"pending","pending_reason":"definitive"}]' "github"
  run_merge_hook_at "$repo"
  assert_denied_by_json
  grep -qF "pending(definitive): v1 class=x path=sibling line=1" <<<"$output" || return 1

  # With zero findings at all, the unresolvable base by itself must never
  # deny: nothing depends on it.
  write_sidecar_at "$repo" '[]' "github"
  run_merge_hook_at "$repo"
  assert_allowed_by_json
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
# in-scope-but-ownerless diff (root Makefile, public/**, ...) therefore
# resolves to an EMPTY dispatched set yet still DENIES without that
# clearance; the oracle's ownerless probe is what covers it.
# ---------------------------------------------------------------------------

@test "FC-4 no-deadlock: app/x.tsx spawns the default member alone, and its marker allows" {
  commit_files "app/x.tsx" "export const X = 1"
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: root tsconfig.json spawns the default member alone, and its marker allows" {
  commit_files "tsconfig.json" '{"compilerOptions":{}}'
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: a CI workflow spawns the workflows member only (not the default), and its marker allows" {
  commit_files ".github/workflows/ci.yml" "name: CI"
  set=$(spawn_set)
  [ "$set" = "code-audit-github-workflows" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: framework shell spawns the shell member only (not the default), and its marker allows" {
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-shell" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: framework CLI TypeScript spawns the node member only (not the default), and its marker allows" {
  commit_files ".gaia/cli/src/foo.ts" "export const foo = 1"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-node" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: skills prose spawns the prose member only (not the default), and its marker allows" {
  commit_files ".claude/skills/foo/SKILL.md" "# Foo skill"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-prose" ]
  assert_not_in_set "code-audit-frontend" "$set"
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: mixed app/ + framework shell spawns both, sorted, and their markers allow" {
  commit_files "app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  expected=$'code-audit-frontend\ncode-audit-maintainer-shell'
  [ "$set" = "$expected" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
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
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: a root in-scope ownerless file denies unmarked and allows once spawned" {
  commit_files "Makefile" "all:"
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]

  # The hazard, made concrete: the dispatched set is empty (nothing OWNS a root
  # Makefile), but the legacy out-of-scope gate still denies, because a root
  # file that is not *.md and not one of the allowlisted literals is in scope.
  # Writing no markers must still deny.
  #
  # Two earlier witnesses no longer serve, for opposite reasons, and both would
  # have kept passing while silently testing something else. Dockerfile is
  # claimed by the default member, so its deny would come from the member-aware
  # branch. .editorconfig is allowlisted outright, so it now allows and belongs
  # to the row below instead.
  run_merge_hook
  assert_denied_by_json

  # The oracle's ownerless probe names the default member for exactly this
  # case, so spawning it and writing its marker clears the gate.
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: nested public/** (in-scope, ownerless) denies unmarked and allows once spawned" {
  commit_files "public/logo.svg" "<svg></svg>"
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]

  run_merge_hook
  assert_denied_by_json

  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: allowlisted ownerless paths spawn nobody, and no markers still allows" {
  # The other half of FC-4's agreement invariant. These paths hold no lens for
  # any member, so the oracle names nobody AND the gate demands nothing: the
  # two sides move together because both read the same allowlist. A widening
  # applied to only one of them is what would deadlock a merge -- the gate
  # waiting on a marker the oracle never names anyone to write.
  commit_files ".gitignore" "node_modules" "LICENSE" "MIT" \
    ".editorconfig" "root = true"
  set=$(spawn_set)
  [ -z "$set" ]

  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-deadlock: an ownerless in-scope file riding with a specialized member spawns the specialized member only" {
  # The dispatched set here is non-empty (the shell member owns y.sh), so the
  # hook takes the member-aware path and never reaches its legacy out-of-scope
  # gate: the Makefile is audited by nobody. This is the gate's own
  # documented behavior (FC-4's ownerless-plus-specialized row), not a defect,
  # and the oracle mirrors it exactly. Do NOT "fix" the oracle to add the
  # default member here: that would spawn a member the gate does not require,
  # breaking the no-useless-spawn half of the invariant.
  #
  # The witness must be BOTH ownerless and in-scope, which is a narrow set: the
  # legacy gate allowlists wiki/, .claude/, .specify/, .gaia/, docs/,
  # root *.md and three root literals outright, so none of those reaches this
  # path. A root Makefile qualifies -- no roster glob claims it and no arm of
  # the allowlist admits it.
  commit_files "Makefile" "all:" ".gaia/scripts/y.sh" "#!/bin/bash"
  set=$(spawn_set)
  [ "$set" = "code-audit-maintainer-shell" ]
  write_markers_for_spawn_set "$set"
  run_merge_hook
  assert_allowed_by_json
}

# --- No useless spawn: withholding a spawned member's marker must deny -----

@test "FC-4 no-useless-spawn: mixed diff denies while only the default member's marker is present" {
  commit_files "app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_denied_by_json
}

@test "FC-4 no-useless-spawn: mixed diff denies with only the shell marker, then allows once both are present" {
  commit_files "app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-maintainer-shell"
  run_merge_hook
  assert_denied_by_json

  write_marker "code-audit-frontend"
  run_merge_hook
  assert_allowed_by_json
}

@test "FC-4 no-useless-spawn: framework-shell-only diff denies with a frontend marker instead of the shell one" {
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker "code-audit-frontend"
  run_merge_hook
  assert_denied_by_json
}

# --- Linked-worktree anchoring (regression) ---------------------------------
#
# The gate spans two roots that are the SAME path in a plain checkout and
# DIFFERENT paths in a linked worktree, which is why a single-root derivation
# passes every test above and still deadlocks a real worktree merge:
#
#   store root  WHERE a clearance lives -- main-anchored (state registry
#               `audit-clearance-markers`, scope shared; provisioning
#               symlinks <worktree>/.gaia/local at main's).
#   tree root   WHAT the clearance attests to -- the ACTING tree, because the
#               content being merged is the worktree's HEAD, not main's.
#
# Every clearance writer keys on the acting tree (the agent definitions pass
# `--root "$(git rev-parse --show-toplevel)"`, and resolve-audit-spawn.sh and
# audit-stamp-trailer.sh derive the same way). Digesting main's HEAD in the
# gate would compare a marker against content nobody is merging: no marker
# could ever match, and the deny message's own remedy ("re-spawn the agents")
# rewrites the same non-matching marker forever.

# MEMBER's real content digest at an ARBITRARY root's HEAD, via the real
# digest engine. member_digest_for is the same call pinned to $REPO.
member_digest_at() {
  local root="$1" member="$2"
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$LIB_DIR/audit-digest.sh" "$root" "$member"
}

# Provision a linked worktree of REPO on its own branch, carrying its own
# in-scope change, so its content digest necessarily differs from main's.
# Mirrors real provisioning: .gaia/local is a SYMLINK to main's, so a marker
# written from the worktree lands in main's shared store.
setup_linked_worktree() {
  WT=$(mktemp -d -t pr-merge-wt-XXXXXX)
  rm -rf "$WT"
  git -C "$REPO" worktree add --quiet -b wt "$WT" main
  mkdir -p "$WT/app"
  printf 'export const y = 2\n' > "$WT/app/y.ts"
  git -C "$WT" add app/y.ts
  git -C "$WT" commit --quiet -m "worktree change"

  # The dispatch resolver is anchored on the ACTING tree, and REPO's copy is
  # untracked so it does not appear in the worktree. Copy it in, as the real
  # repo always has it.
  mkdir -p "$WT/.gaia/scripts"
  cp "$RESOLVER_ABS" "$WT/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$WT/.gaia/scripts/resolve-audit-members.sh"

  mkdir -p "$REPO/.gaia/local"
  rm -rf "$WT/.gaia/local"
  ln -s "$REPO/.gaia/local" "$WT/.gaia/local"
}

run_merge_hook_in_worktree() {
  local cmd="gh pr merge 30 --squash --delete-branch"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$WT" "$json" "$HOOK_ABS"
}

teardown_linked_worktree() {
  [ -n "${WT:-}" ] && git -C "$REPO" worktree remove --force "$WT" 2>/dev/null
  return 0
}

@test "linked worktree: a marker keyed to the WORKTREE's own content allows the merge" {
  commit_files "app/x.ts" "export const x = 1"
  setup_linked_worktree

  local digest
  digest="$(member_digest_at "$WT" code-audit-frontend)"
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":4,"member":"code-audit-frontend","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true,"dispositions_sidecar":true}\n' \
    "$digest" "$(git -C "$WT" rev-parse 'HEAD^{tree}')" "$(git -C "$WT" rev-parse HEAD)" \
    > "$REPO/.gaia/local/audit/${digest}.ok"
  printf '{"schema":1,"backend":"absent","findings":[]}\n' \
    > "$REPO/.gaia/local/audit/${digest}.dispositions.json"

  run_merge_hook_in_worktree
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "linked worktree: a marker keyed to MAIN's content does NOT clear the worktree's merge" {
  commit_files "app/x.ts" "export const x = 1"
  setup_linked_worktree

  # Deliberately key the marker to the MAIN checkout's digest, the shape a
  # main-anchored gate would compute. The two digests must genuinely differ,
  # or this test would pass for the wrong reason.
  local main_digest wt_digest
  main_digest="$(member_digest_at "$REPO" code-audit-frontend)"
  wt_digest="$(member_digest_at "$WT" code-audit-frontend)"
  [ "$main_digest" != "$wt_digest" ]

  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":4,"member":"code-audit-frontend","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true,"dispositions_sidecar":true}\n' \
    "$main_digest" "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" "$(git -C "$REPO" rev-parse HEAD)" \
    > "$REPO/.gaia/local/audit/${main_digest}.ok"

  run_merge_hook_in_worktree
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# ---------------------------------------------------------------------------
# chore(deps) bypass, allow path
#
# Every case above stubs `gh pr view` to an empty title, so the bypass never
# fires and its allow path went untested. These three cover it, and the third
# is the reason: the predicate is executable code, so it must be resolved from
# the ACTING tree. Resolving it from the main checkout instead looks correct in
# an ordinary clone, where the two are the same directory, and silently denies
# every chore(deps) merge from a linked worktree.
# ---------------------------------------------------------------------------

@test "chore(deps): a dep-bump PR is allowed with no marker at all" {
  install_gh_stub_with_title "chore(deps): bump the github-actions group"
  install_chore_deps_predicate
  commit_files "app/x.ts" "export const x = 1"

  run_merge_hook
  assert_allowed_by_json
}

@test "chore(deps): an ordinary PR title still requires a marker" {
  install_gh_stub_with_title "feat: add a thing"
  install_chore_deps_predicate
  commit_files "app/x.ts" "export const x = 1"

  run_merge_hook
  assert_denied_by_json
}

@test "chore(deps): the bypass fires from a linked worktree, where main lacks the predicate" {
  install_gh_stub_with_title "chore(deps): bump the github-actions group"
  commit_files "app/x.ts" "export const x = 1"
  setup_linked_worktree

  # The predicate lands in the WORKTREE only. REPO stands in for a main
  # checkout whose branch does not carry it, which is what origin/main looks
  # like before this change merges. A gate resolving the script from the main
  # checkout finds nothing here and denies.
  mkdir -p "$WT/.gaia/scripts"
  cp "$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/chore-deps-skip.sh" \
    "$WT/.gaia/scripts/chore-deps-skip.sh"
  chmod +x "$WT/.gaia/scripts/chore-deps-skip.sh"
  [ ! -f "$REPO/.gaia/scripts/chore-deps-skip.sh" ]

  run_merge_hook_in_worktree
  teardown_linked_worktree
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

# ---------------------------------------------------------------------------
# Provenance-keyed base resolution
#
# The gate resolves its diff base through the shared provenance resolver
# (.claude/hooks/lib/audit-base-provenance.sh), which answers with a trust
# token alongside the base. An EMPTY base-to-HEAD range clears the
# out-of-scope bypass only when that trust is one this checkout could not have
# invented AND the base was taken against the pull request's own recorded base
# branch AND local HEAD is the pull request's recorded head AND the command
# being gated names that same pull request. Anything less denies. The first
# three conjuncts alone would not be enough: the gate scopes its range to local
# HEAD, and a synced default-branch checkout has an empty range against every
# pull request in the repository at once, while the record itself is read for
# the CURRENT BRANCH and so describes a pull request the gated command need
# never have named.
#
# The self-modification bypass reads the same base and is deliberately NOT
# relaxed: it is reachable from the member-aware gate, where it clears every
# dispatched member at once.
# ---------------------------------------------------------------------------

# Advertise refs/remotes/origin/main as the default and point it at REV, so
# the ladder's remote-minting arm resolves. Remote-tracking refs are written
# directly: they only ever need to resolve, never to fetch.
set_origin_main_at() {
  git -C "$REPO" update-ref refs/remotes/origin/main "$1"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# The gh stub with a POPULATED pull-request record: $1 is baseRefName, $2 is
# headRefOid, $3 is the pull-request number, $4 the issue list. jq builds the
# record rather than a printf format, so a value carrying a quote stays valid
# JSON instead of silently emptying a field a test is pinning, the same
# reasoning install_gh_stub_with_title gives.
#
# The number defaults to the one the default command under test merges, so a
# test that does not care about the number gets a record the gate's number
# conjunct accepts. A test that DOES care states both halves at its call site.
# The stub answers `pr` the same way whatever arguments it is handed, which is
# the point: the gate is what must tell the record's pull request from the one
# the command names.
install_gh_stub_with_record() {
  local base_ref="$1" head_oid="$2" number="${3:-30}"
  install_gh_stub "${4:-[]}"
  printf '%s' "$base_ref" > "$BATS_TEST_TMPDIR/pr-base.txt"
  printf '%s' "$head_oid" > "$BATS_TEST_TMPDIR/pr-head.txt"
  printf '%s' "$number" > "$BATS_TEST_TMPDIR/pr-number.txt"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
issues_file="$BATS_TEST_TMPDIR/issues.json"
base_file="$BATS_TEST_TMPDIR/pr-base.txt"
head_file="$BATS_TEST_TMPDIR/pr-head.txt"
number_file="$BATS_TEST_TMPDIR/pr-number.txt"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) jq -n --arg b "$(cat "$base_file")" --arg h "$(cat "$head_file")" \
        --arg n "$(cat "$number_file")" \
        '{title:"", baseRefName:$b, headRefOid:$h, number:$n}'; exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
}

# A `git` earlier on PATH than the real one that fails every `git diff` and
# forwards everything else. The failure mode under test is a diff that never
# RAN: it writes nothing to stdout, which a bare read cannot tell apart from a
# diff that ran and found nothing.
install_failing_diff_git() {
  local real
  real="$(command -v git)"
  cat > "$GH_BIN/git" <<EOF
#!/usr/bin/env bash
REAL_GIT="$real"
EOF
  cat >> "$GH_BIN/git" <<'EOF'
# Walk past git's own global options to find the subcommand: every call in the
# gate's chain spells the tree as `git -C <root> <subcommand>`, so a check on
# $1 alone would never see a diff at all. The scan runs inside a command
# substitution, which inherits the positional parameters and discards its own
# shifts, so the exec below still forwards the original argv.
sub="$(
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C | -c | --git-dir | --work-tree) shift 2 || break ;;
      -*) shift ;;
      *) printf '%s' "$1"; break ;;
    esac
  done
)"
if [ "$sub" = "diff" ]; then exit 1; fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$GH_BIN/git"
}

# Drop `gh` from PATH entirely, by mirroring every PATH directory that carries
# one into a shim directory without it. Filtering the directory out wholesale
# would take jq and git with it on a Homebrew host, where all three share a
# prefix.
scrub_gh_from_path() {
  local shim keep dir bin name
  shim="$BATS_TEST_TMPDIR/nogh"
  mkdir -p "$shim"
  keep=""
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    if [ -x "$dir/gh" ]; then
      for bin in "$dir"/*; do
        name="${bin##*/}"
        [ "$name" = "gh" ] && continue
        [ -e "$shim/$name" ] || ln -s "$bin" "$shim/$name" 2>/dev/null || true
      done
    else
      keep="${keep:+$keep:}$dir"
    fi
  done <<< "$(printf '%s' "$PATH" | tr ':' '\n')"
  export PATH="$shim${keep:+:$keep}"
}

# Run the hook with stdout and stderr kept apart, so a permit's silence on
# stdout can be asserted independently of its diagnostic line on stderr.
# invoke_hook_in merges the two.
run_merge_hook_split() {
  local cmd="${1:-gh pr merge 30 --squash --delete-branch}" json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  run --separate-stderr bash -c 'cd "$1" && printf %s "$2" | bash "$3"' \
    _ "$REPO" "$json" "$HOOK_ABS"
}

# A copy of the gate in the sandbox whose provenance library records the argv
# of every audit_resolve_base_provenance call before delegating to the real
# one. The copy is what makes the interception possible at all: the real hook
# resolves its libraries from its OWN on-disk location, so nothing a test puts
# in the sandbox can reach them.
install_recording_hook_copy() {
  RECORD_FILE="$BATS_TEST_TMPDIR/arbp-argv.txt"
  : > "$RECORD_FILE"
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$HOOK_ABS" "$REPO/.claude/hooks/pr-merge-audit-check.sh"
  cp "$LIB_DIR"/*.sh "$REPO/.claude/hooks/lib/"
  cat > "$REPO/.claude/hooks/lib/audit-base-provenance.sh" <<EOF
#!/usr/bin/env bash
. "$LIB_DIR/audit-base-provenance.sh"
_arbp_record="$RECORD_FILE"
EOF
  cat >> "$REPO/.claude/hooks/lib/audit-base-provenance.sh" <<'EOF'
eval "_arbp_real() $(declare -f audit_resolve_base_provenance | tail -n +2)"
audit_resolve_base_provenance() {
  printf 'supplied=[%s]\n' "${3-}" >> "$_arbp_record"
  _arbp_real "$@"
}
EOF
}

run_recording_hook() {
  local json
  json=$(jq -n --arg c "gh pr merge 30 --squash --delete-branch" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$REPO" "$json" "$REPO/.claude/hooks/pr-merge-audit-check.sh"
}

@test "an empty range on a remote-verified record base at the recorded head permits silently, with the reason on stderr" {
  # setup() leaves feature at main's tip, so the base-to-HEAD range is empty
  # by construction rather than by an emptied diff.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head"

  run_merge_hook_split
  [ "$status" -eq 0 ]
  # No JSON at all. The permit keeps the shape every other permit in this hook
  # has: a silent zero exit, never a permissionDecision emission.
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  grep -qF 'range is empty' <<<"$stderr" || return 1
  grep -qF 'remote provenance' <<<"$stderr" || return 1
  grep -qF 'anchor pr-record' <<<"$stderr" || return 1
}

@test "the gate emits no permissionDecision allow at all" {
  grep -qF 'permissionDecision: "allow"' "$HOOK_ABS" && return 1
  true
}

@test "an empty range on a locally-derived base denies, and the reason names the local provenance" {
  # No remote-tracking refs at all, so the record's branch cannot verify and
  # the ladder falls to the bare local branch name.
  install_gh_stub_with_record "main" "$(git -C "$REPO" rev-parse HEAD)"

  run_merge_hook
  assert_denied_by_json
  grep -qF 'Diff base:' <<<"$output" || return 1
  grep -qF 'local provenance' <<<"$output" || return 1
  grep -qF 'anchor default-branch' <<<"$output" || return 1
}

@test "an unresolvable base denies, and the reason names it as unresolvable" {
  local repo
  repo="$(make_no_base_repo_pr provenance-no-base)"
  install_gh_stub

  run_merge_hook_at "$repo"
  assert_denied_by_json
  grep -qF 'unresolvable provenance' <<<"$output" || return 1
  grep -qF 'base unresolved' <<<"$output" || return 1
}

@test "a synced default-branch checkout denies gh pr merge for a pull request it is not on (no record)" {
  # The reproduced hole: on a synced default branch merge-base(HEAD,
  # refs/remotes/origin/main) IS HEAD, so the range holds zero files on remote
  # provenance. Nothing in the command being gated says which pull request 999
  # is, so a range-only rule would clear an arbitrary unaudited one.
  git -C "$REPO" checkout --quiet main
  set_origin_main_at refs/heads/main
  install_gh_stub

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

@test "a synced default-branch checkout denies even when the record answers with this checkout's own head sha" {
  # Isolates the anchor conjunct: trust is remote and the recorded head sha
  # matches local HEAD, so only "the base was taken against the pull request's
  # own recorded base branch" stands between this and a permit.
  git -C "$REPO" checkout --quiet main
  set_origin_main_at refs/heads/main
  install_gh_stub_with_record "" "$(git -C "$REPO" rev-parse HEAD)" 999

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

@test "an empty range on a record base denies when the recorded head sha is not local HEAD" {
  # Isolates the head-sha conjunct: anchor and trust both qualify, and the
  # checkout is simply not on the pull request being merged.
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "0000000000000000000000000000000000000001" 999

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

@test "an empty range denies when the command names a pull request other than the record's" {
  # Isolates the number conjunct: trust, anchor and head sha all qualify, so
  # the ONLY thing between this and the permit its sibling above earns is that
  # the record describes pull request 30 and the command merges 999. The
  # record is read for the current branch, so nothing but this conjunct ever
  # looks at the number the command names.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge 999 --squash"
  assert_denied_by_json
}

@test "an empty range denies when the command names a target the gate cannot confirm" {
  # `gh pr merge` also accepts a branch and a URL. Both resolve to a number
  # only through a network read this gate does not make, so an unconfirmable
  # target takes the deny rather than the relaxation. A separated option value
  # reads as the positional for the same reason and lands in the same place.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge feature --squash"
  assert_denied_by_json

  run_merge_hook "gh pr merge https://github.com/gaia-react/gaia/pull/30"
  assert_denied_by_json

  # A single-dash cluster is a shape the shared scanner declines to model,
  # because pflag reads it letter by letter and the first value-taking
  # shorthand in it swallows the rest. An unmodelled shape denies.
  run_merge_hook "gh pr merge -sd 30"
  assert_denied_by_json
}

@test "an empty range denies when a separated option value is the record's own number" {
  # The defect this pins: skipping options by their leading dash alone reads a
  # value-taking flag's SEPARATED value as the positional. Every spelling below
  # hands the record's number to a flag and merges 999, so a scanner that does
  # not model the flag set compares the flag's value equal to the record and
  # permits a merge of an entirely unaudited pull request.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge --body 30 999 --squash"
  assert_denied_by_json

  run_merge_hook "gh pr merge -t 30 999 --squash"
  assert_denied_by_json

  run_merge_hook "gh pr merge --match-head-commit 30 999 --squash"
  assert_denied_by_json

  run_merge_hook "gh pr merge --body-file 30 999 --squash"
  assert_denied_by_json
}

@test "an empty range still permits when a separated option value sits beside the record's own number" {
  # The complement of the test above, and what keeps its deny from being
  # trivially satisfied by "any command carrying a flag value denies": the same
  # flag shapes with the RECORD's number as the real positional still permit,
  # so the scanner is reading the positional rather than refusing the shape.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge --body 999 30 --squash"
  assert_allowed_by_json

  run_merge_hook "gh pr merge --subject=999 30 --squash"
  assert_allowed_by_json
}

@test "an empty range denies anything at all following the merge in the same command" {
  # One tool call, two merges: the first names the record's pull request and
  # the second an arbitrary one. Reading the first reference and permitting
  # would clear both, so the relaxation requires the merge to be the whole
  # command.
  #
  # The four spellings below are what forced this to be the shell's own
  # tokenizer rather than a scan of the text. A subshell and a brace group put
  # a character before the second verb, so a scan that reads command positions
  # cannot see it; quoting one word of the verb and splitting it across a line
  # continuation each break the literal run of characters, so a scan that
  # counts the phrase cannot see it either. Both were demonstrated to permit.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "gh pr merge 30 --squash; gh pr merge 999 --squash"
  assert_denied_by_json

  run_merge_hook "gh pr merge 30 --squash && (gh pr merge 999 --squash)"
  assert_denied_by_json

  run_merge_hook "gh pr merge 30 --squash && { gh pr merge 999 --squash; }"
  assert_denied_by_json

  run_merge_hook 'gh pr merge 30 --squash && gh pr "merge" 999 --squash'
  assert_denied_by_json

  run_merge_hook 'gh pr merge 30 --squash && gh "pr" merge 999 --squash'
  assert_denied_by_json

  run_merge_hook 'gh pr merge 30 --squash && gh pr \
merge 999 --squash'
  assert_denied_by_json

  # Not a second merge at all, and it still denies: the relaxation cannot
  # account for what runs beside it, so it refuses rather than read the rest
  # approximately.
  run_merge_hook "gh pr merge 30 --squash && echo done"
  assert_denied_by_json
}

@test "an empty range denies when the merge is not the first command in the tool call" {
  # The shared scanner reads the FIRST command and abstains otherwise, because
  # whatever sits ahead of a merge decides which repository and which checkout
  # it lands in. An abstention denies here rather than being read approximately.
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head" 30

  run_merge_hook "echo ready && gh pr merge 30 --squash"
  assert_denied_by_json
}

@test "the self-mod bypass does not fire on an empty range, even with the audit workflow re-rendered verbatim" {
  seed_base_template
  commit_files ".github/workflows/code-review-audit.yml" "name: Code Review Audit"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "0000000000000000000000000000000000000001"

  run_merge_hook
  assert_denied_by_json
  # Positively pin that the base really was remote-verified, so this case
  # cannot green on a fixture that quietly degraded to a local base.
  grep -qF 'remote provenance' <<<"$output" || return 1
}

@test "a non-empty dispatched member set still denies while a member withholds, on remote provenance at the recorded head" {
  commit_files \
    "app/x.ts" "export const x = 1" \
    ".gaia/scripts/example.sh" "#!/bin/bash"
  set_origin_main_at refs/heads/main
  install_gh_stub_with_record "main" "$(git -C "$REPO" rev-parse HEAD)"
  write_marker "code-audit-frontend"

  run_merge_hook
  assert_denied_by_json
  grep -qF "code-audit-maintainer-shell: PENDING" <<<"$output" || return 1
}

@test "a diff that never ran never reaches the permit arm" {
  # The resolver copy is removed so the legacy path runs: a failing git would
  # otherwise make the member query unanswerable, and that deny would mask the
  # one under test.
  rm -f "$REPO/.gaia/scripts/resolve-audit-members.sh"
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  set_origin_main_at refs/heads/feature
  install_gh_stub_with_record "main" "$head"

  # Positive control: with a working git this exact fixture permits, so the
  # denial below is the failed diff and nothing else.
  run_merge_hook
  assert_allowed_by_json

  install_failing_diff_git
  run_merge_hook
  assert_denied_by_json
}

@test "every audit_resolve_base_provenance call in the gate source passes an empty supplied base" {
  local calls bad
  calls="$(grep -n 'audit_resolve_base_provenance ' "$HOOK_ABS" | grep -v '^[0-9]*:[[:space:]]*#')"
  [ -n "$calls" ] || return 1
  bad="$(printf '%s\n' "$calls" \
    | grep -vF 'audit_resolve_base_provenance "$tree_root" pr-record "" "$pr_record_base"' || true)"
  [ -z "$bad" ] || return 1
}

@test "every audit_resolve_base_provenance invocation at run time passes an empty supplied base" {
  install_recording_hook_copy
  commit_files "app/x.ts" "export const x = 1"
  install_gh_stub_with_record "main" "$(git -C "$REPO" rev-parse HEAD)"

  run_recording_hook
  assert_denied_by_json
  [ -s "$RECORD_FILE" ]
  grep -v -x 'supplied=\[\]' "$RECORD_FILE" > "$BATS_TEST_TMPDIR/arbp-bad.txt" || true
  [ ! -s "$BATS_TEST_TMPDIR/arbp-bad.txt" ]
}

@test "the base comes from the remote-tracking ref, not a local branch literally named origin/main" {
  # git resolves the bare revspec origin/main through refs/heads/ before
  # refs/remotes/, so a local branch of that name would supply the base while
  # refs/remotes/origin/main still verifies -- remote trust minted for a purely
  # local base. The fully-qualified spelling is what forecloses it, and this
  # checkout is where the two spellings answer differently.
  local remote_base shadow_tip
  remote_base="$(git -C "$REPO" rev-parse HEAD)"
  commit_files "docs/note.md" "a commit only the shadowing local branch carries"
  shadow_tip="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" branch "origin/main" "$shadow_tip"
  commit_files "Makefile" "all:"
  set_origin_main_at "$remote_base"
  install_gh_stub

  run_merge_hook
  assert_denied_by_json
  grep -qF "base ${remote_base:0:12}" <<<"$output" || return 1
  grep -qF "base ${shadow_tip:0:12}" <<<"$output" && return 1
  true
}

@test "the gate denies with well-formed JSON when gh is absent from PATH entirely" {
  # resolve_pr_record returns at its `command -v gh` guard, before any field
  # assignment. Every reader of a record field must survive that under set -u,
  # or the hook dies and emits nothing at all where it owes a deny.
  set_origin_main_at refs/heads/feature
  scrub_gh_from_path
  [ -z "$(command -v gh)" ]

  run_merge_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ]
}

@test "the gate denies with well-formed JSON when gh answers with no record at all" {
  # The other early return: gh exists, and there is no pull request for this
  # branch. Same obligation, reached one line later.
  set_origin_main_at refs/heads/feature
  install_gh_stub
  cat > "$GH_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pr) exit 1 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"

  run_merge_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ]
}
