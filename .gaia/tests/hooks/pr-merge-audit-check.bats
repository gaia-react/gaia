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

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/pr-merge-audit-check.sh
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

# Run the hook with a `gh pr merge` command, from inside the repo.
run_merge_hook() {
  local cmd="${1:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -n --arg c "$cmd" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c "cd '$REPO' && printf '%s' '$json' | bash '$HOOK_ABS'"
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
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" "name: Code Review Audit" \
    "wiki/log.md" "entry"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "denies a workflow edit that does NOT match the bundled template" {
  # Adopter customization (self-hosted runner, extra secret) diverges from the
  # template, so there IS something to audit; the marker stays mandatory.
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit (customized)" \
    ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" "name: Code Review Audit"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a verbatim workflow re-render smuggling in-scope source" {
  # A matching re-render cannot mask an app/ change; the marker is mandatory the
  # moment any auditable path appears.
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" "name: Code Review Audit" \
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
  commit_files \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" "name: Code Review Audit" \
    ".github/workflows/tests.yml" "name: Tests"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}
