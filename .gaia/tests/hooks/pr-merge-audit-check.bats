#!/usr/bin/env bats

# Tests for the two no-marker bypasses in .claude/hooks/pr-merge-audit-check.sh.
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
  # own copy of the shared ownership classifier alongside them. The real
  # hook (run by absolute path via $HOOK_ABS, never copied) resolves its own
  # libs to the real repo regardless.
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$LIB_DIR/audit-scope.sh" "$REPO/.claude/hooks/lib/audit-scope.sh"
  cp "$LIB_DIR/audit-machinery.sh" "$REPO/.claude/hooks/lib/audit-machinery.sh"
  cp "$LIB_DIR/audit-clearance.sh" "$REPO/.claude/hooks/lib/audit-clearance.sh"
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

# Write a Code Audit Team clearance marker for REPO's current HEAD TREE. A
# marker attests that a member audited the tree, not the commit, so it survives
# an empty commit (the GAIA-Audit trailer stamp) that leaves the tree identical.
# The body is a writer-shaped schema-2 clearance (the gate now accepts only
# such bodies, never a bare `{}`): its `tree` equals the filename key and its
# `member` matches the member the suffix names.
#   write_marker ""                              -> <tree>.ok (frontend/default)
#   write_marker ".code-audit-maintainer-shell"   -> <tree>.code-audit-maintainer-shell.ok
write_marker() {
  local suffix="$1" tree sha member sidecar
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  sha=$(git -C "$REPO" rev-parse HEAD)
  if [ -z "$suffix" ]; then
    member="code-audit-frontend"
    sidecar="true"
  else
    member="${suffix#.}"
    sidecar="false"
  fi
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":2,"member":"%s","provenance":"earned","sha":"%s","tree":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$sha" "$tree" "$sidecar" \
    > "$REPO/.gaia/local/audit/${tree}${suffix}.ok"
}

# Print the spawn set the oracle resolves for REPO's current diff.
spawn_set() {
  ( cd "$REPO" && bash .gaia/scripts/resolve-audit-spawn.sh 2>/dev/null )
}

# Write a clearance marker for every name in a spawn-set (newline-separated)
# string, mapping each to its FC-2 suffix: code-audit-frontend -> "",
# any other member <m> -> ".<m>".
write_markers_for_spawn_set() {
  local set="$1" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$name" = "code-audit-frontend" ]; then
      write_marker ""
    else
      write_marker ".$name"
    fi
  done <<<"$set"
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

# --- Carry-forward fixtures (Phase 3) --------------------------------------

# The dispatch resolver's own view of the whole-branch diff (the CONTROL that a
# member's absence from the spawn set is carry-forward's doing, not a fixture in
# which the member was never dispatched).
resolve_members() {
  ( cd "$REPO" && bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null )
}

# Seed a frontend EARNED clearance for a specific tree/sha plus its disposition
# sidecar, so it can serve as a carry-forward anchor (the sidecar-missing drop
# needs the sidecar present).
#   seed_anchor_frontend TREE SHA [AAT] [FINDINGS_JSON] [BACKEND]
seed_anchor_frontend() {
  local tree="$1" sha="$2" aat="${3:-2026-01-01T00:00:00Z}" findings="${4:-[]}" backend="${5:-absent}"
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":2,"member":"code-audit-frontend","provenance":"earned","sha":"%s","tree":"%s","audited_at":"%s","sidecar":true}\n' \
    "$sha" "$tree" "$aat" > "$REPO/.gaia/local/audit/${tree}.ok"
  printf '{"schema":1,"backend":"%s","findings":%s}\n' "$backend" "$findings" \
    > "$REPO/.gaia/local/audit/${sha}.dispositions.json"
}

# Write a frontend CARRIED clearance for a tree (no earned marker), so the
# member reads as cleared via the carried artifact.
write_carried_frontend() {
  local tree="$1" sha
  sha=$(git -C "$REPO" rev-parse HEAD)
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":2,"member":"code-audit-frontend","provenance":"carried","sha":"%s","tree":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true,"anchor_tree":"%s"}\n' \
    "$sha" "$tree" "$tree" > "$REPO/.gaia/local/audit/${tree}.carried"
}

# Install a gh stub on a prepended PATH. `gh issue list` prints $1 (default []).
# GET statuses return null (so the frontend is NOT cleared via a CI status,
# forcing carry-forward), `gh pr view` returns an empty title (no chore(deps)),
# and a `--method POST` records its argv to POST_LOG so the description can be
# asserted.
install_gh_stub() {
  local issues="${1:-[]}"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  POST_LOG="$BATS_TEST_TMPDIR/post.log"
  rm -f "$POST_LOG"
  printf '%s' "$issues" > "$BATS_TEST_TMPDIR/issues.json"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
post_log="$POST_LOG"
issues_file="$BATS_TEST_TMPDIR/issues.json"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) printf '\n'; exit 0 ;;
  issue) cat "$issues_file"; exit 0 ;;
  api)
    case "$*" in
      *"--method POST"*) printf '%s\n' "$*" >> "$post_log"; exit 0 ;;
      *) printf 'null\n'; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

@test "allows a docs/metadata-only PR (wiki + .claude + .gaia)" {
  commit_files \
    ".claude/skills/update-gaia/SKILL.md" "updated" \
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
  write_marker ""
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: mixed app/ + .gaia .sh diff denies while the maintainer-shell member withholds" {
  commit_files \
    "app/x.ts" "export const x = 1" \
    ".gaia/scripts/example.sh" "#!/bin/bash"
  write_marker ""
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "AND-aggregator: mixed app/ + .gaia .sh diff allows once both dispatched members clear" {
  commit_files \
    "app/x.ts" "export const x = 1" \
    ".gaia/scripts/example.sh" "#!/bin/bash"
  write_marker ""
  write_marker ".code-audit-maintainer-shell"
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
  write_marker ".code-audit-maintainer-shell"
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
  write_marker ""
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

  write_marker ""
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# The regression the tree key exists for. Every dispatched member audits one
# tree and writes its marker; code-audit-frontend then stamps the GAIA-Audit
# trailer, which lands as an EMPTY commit -- HEAD advances, the tree does not.
# Keyed to HEAD, every sibling member's marker is orphaned by that stamp and the
# gate denies a diff all members already cleared. Keyed to the tree, the markers
# still name the content being merged, so the gate clears.
@test "AND-aggregator: every member's marker survives the trailer stamp's empty commit" {
  commit_files "app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x"
  write_marker ""
  write_marker ".code-audit-maintainer-shell"

  # code-audit-frontend stamps the trailer: an empty commit, identical tree.
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(git -C "$REPO" rev-parse "HEAD^{tree}")" = "$before_tree" ]

  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# The other half of the contract: tree-keying must not turn the gate into a
# rubber stamp. A commit that actually CHANGES the tree invalidates every
# marker, because the content the members cleared is no longer the content
# being merged.
@test "AND-aggregator: a marker does NOT survive a commit that changes the tree" {
  commit_files "app/a.ts" "export const a = 1" ".gaia/scripts/x.sh" "echo x"
  write_marker ""
  write_marker ".code-audit-maintainer-shell"

  commit_files "app/b.ts" "export const b = 2"

  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<< "$output" || return 1
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

@test "FC-4 no-deadlock: a CI workflow spawns the default member alone, and its marker allows" {
  commit_files ".github/workflows/ci.yml" "name: CI"
  set=$(spawn_set)
  [ "$set" = "code-audit-frontend" ]
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
  write_marker ""
  run_merge_hook
  assert_denied
}

@test "FC-4 no-useless-spawn: mixed diff denies with only the shell marker, then allows once both are present" {
  commit_files "app/x.tsx" "export const X = 1" ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker ".code-audit-maintainer-shell"
  run_merge_hook
  assert_denied

  write_marker ""
  run_merge_hook
  assert_allowed
}

@test "FC-4 no-useless-spawn: framework-shell-only diff denies with a frontend marker instead of the shell one" {
  commit_files ".gaia/scripts/y.sh" "#!/bin/bash"
  write_marker ""
  run_merge_hook
  assert_denied
}

# ---------------------------------------------------------------------------
# Carry-forward: the authority mints a carried clearance and allows, never
# shrinks the required set, and re-verifies filed dispositions after a carry.
# ---------------------------------------------------------------------------

@test "UAT-001: a wiki-only commit carries the frontend clearance forward and allows, minting a carried clearance" {
  install_gh_stub
  # app/ change -> tree T1; seed the frontend earned anchor + a clean sidecar.
  commit_files "app/x.ts" "export const x = 1"
  t1=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  s1=$(git -C "$REPO" rev-parse HEAD)
  seed_anchor_frontend "$t1" "$s1"
  # A wiki-only commit -> tree T2, with NO clearance artifact for T2.
  commit_files "wiki/x.md" "doc"
  t2=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  # CONTROL: the whole-branch diff still dispatches the frontend member, so its
  # absence from the spawn list is provably carry-forward's doing.
  members=$(resolve_members)
  assert_in_set "code-audit-frontend" "$members"

  run_merge_hook
  assert_allowed
  # A carried clearance was minted at T2's distinct filename.
  [ -f "$REPO/.gaia/local/audit/${t2}.carried" ]
  # The status POST carries the `carried` provenance token in its description.
  [ -f "$POST_LOG" ]
  grep -q "description=1.4.0 ${t2} carried" "$POST_LOG"
}

@test "UAT-004: a carried frontend clearance never removes a co-dispatched member from the required set" {
  # The whole-branch diff touches app/ AND a NON-machinery shell script, so both
  # code-audit-frontend and code-audit-maintainer-shell are required.
  commit_files "app/x.ts" "export const x = 1" ".gaia/scripts/token-tally.sh" "echo tally"
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  # frontend holds a CARRIED clearance for HEAD's tree; the shell member none.
  write_carried_frontend "$tree"

  # CONTROL: the required set derives from the whole-branch diff (both members),
  # not the clearance pool (which would be the frontend alone).
  members=$(resolve_members)
  assert_in_set "code-audit-frontend" "$members"
  assert_in_set "code-audit-maintainer-shell" "$members"

  run_merge_hook
  assert_denied
  grep -q "code-audit-maintainer-shell: PENDING" <<<"$output" || return 1
}

@test "UAT-010: a carried disposition whose filed key resolves to no issue denies (carry-then-deny)" {
  # gh reachable, but the tech-debt issue list is empty: the anchor's filed key
  # resolves to nothing.
  install_gh_stub '[]'
  commit_files "app/x.ts" "export const x = 1"
  t1=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  s1=$(git -C "$REPO" rev-parse HEAD)
  # The anchor's audit filed a disposition on a REACHABLE backend.
  seed_anchor_frontend "$t1" "$s1" "2026-01-01T00:00:00Z" \
    '[{"key":"v1 class=x path=app/x.ts line=1","disposition":"filed"}]' "github"
  # A wiki-only commit -> tree T2; the anchor commit is an ancestor of HEAD.
  commit_files "wiki/x.md" "doc"
  t2=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  s2=$(git -C "$REPO" rev-parse HEAD)

  run_merge_hook
  assert_denied
  grep -q "filed-but-missing" <<<"$output" || return 1
  grep -q "v1 class=x path=app/x.ts line=1" <<<"$output" || return 1
  # The carry DID happen: the carried clearance was minted and the anchor's
  # disposition record merged into HEAD's sidecar in the same operation.
  [ -f "$REPO/.gaia/local/audit/${t2}.carried" ]
  [ -f "$REPO/.gaia/local/audit/${s2}.dispositions.json" ]
  [ "$(jq -r '.findings[0].disposition' "$REPO/.gaia/local/audit/${s2}.dispositions.json")" = "filed" ]
}
