#!/usr/bin/env bats

# Tests for .claude/hooks/block-selfheal-paths.sh, the LOCAL producer's
# self-heal repair-boundary gate (FC-10).
#
# The gate binds MEMBERS, not the tree: a PreToolUse payload carries
# `agent_type` only when the hook fires inside a subagent call, so this hook
# no-ops for the main session / orchestrator (absent agent_type) and for any
# non-Code-Audit-Team subagent, and denies only a `code-audit-*` member
# editing (via Edit/Write/MultiEdit or a well-known Bash write vector) a path
# matched by the ONE refusal set in .claude/hooks/lib/audit-selfheal-paths.sh
# -- the same set the CI producer's push gate sources
# (.github/workflows/code-review-audit.yml). The guard is best-effort, not
# airtight: Bash vectors are unbounded, so only the well-known write shapes
# (redirect, tee, sed -i, sponge, cp/mv destination) are covered, mirroring
# block-manifest-write.sh's own stated posture. It always exits 0, carrying
# the allow/deny decision in stdout JSON.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-selfheal-paths.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Quote-safe delivery (mandatory, per block-manifest-write.bats precedent):
# several payloads below carry Bash commands with their own single quotes
# (sed -i '' ...). Passing $json and $HOOK_ABS as positional args to an
# inner `bash -c` avoids re-quoting that would strip the embedded quoting.
run_hook_edit() {
  local agent="$1" tool="$2" path="$3"
  local json
  if [ -n "$agent" ]; then
    json=$(jq -n --arg a "$agent" --arg t "$tool" --arg p "$path" '{agent_type: $a, tool_name: $t, tool_input: {file_path: $p}}')
  else
    json=$(jq -n --arg t "$tool" --arg p "$path" '{tool_name: $t, tool_input: {file_path: $p}}')
  fi
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_bash() {
  local agent="$1" cmd="$2"
  local json
  if [ -n "$agent" ]; then
    json=$(jq -n --arg a "$agent" --arg c "$cmd" '{agent_type: $a, tool_name: "Bash", tool_input: {command: $c}}')
  else
    json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  fi
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}

# --- the gate binds members, not the tree (criteria 5, 6) ---

@test "no agent_type (main session / orchestrator): editing test/foo.ts is allowed" {
  run_hook_edit "" "Edit" "test/foo.ts"
  assert_allowed
}

@test "no agent_type: editing .gaia/audit-ci.yml is allowed" {
  run_hook_edit "" "Edit" ".gaia/audit-ci.yml"
  assert_allowed
}

@test "no agent_type: editing .github/workflows/tests.yml is allowed" {
  run_hook_edit "" "Edit" ".github/workflows/tests.yml"
  assert_allowed
}

@test "agent_type general-purpose (non-member subagent): editing test/foo.ts is allowed" {
  run_hook_edit "general-purpose" "Edit" "test/foo.ts"
  assert_allowed
}

# --- a member denied on the refused set, criteria 1, 2, 7 (UAT-026/UAT-027) ---

@test "code-audit-frontend editing test/foo.ts is denied and names the path" {
  run_hook_edit "code-audit-frontend" "Edit" "test/foo.ts"
  assert_denied
  grep -qF 'test/foo.ts' <<<"$output"
}

@test "code-audit-frontend editing .github/workflows/tests.yml is denied and names the path" {
  run_hook_edit "code-audit-frontend" "Edit" ".github/workflows/tests.yml"
  assert_denied
  grep -qF '.github/workflows/tests.yml' <<<"$output"
}

@test "code-audit-frontend editing .gaia/audit-ci.yml is denied and names the path" {
  run_hook_edit "code-audit-frontend" "Edit" ".gaia/audit-ci.yml"
  assert_denied
  grep -qF '.gaia/audit-ci.yml' <<<"$output"
}

@test "code-audit-frontend editing .claude/rules/foo.md is denied" {
  run_hook_edit "code-audit-frontend" "Edit" ".claude/rules/foo.md"
  assert_denied
}

@test "code-audit-frontend editing wiki/concepts/Foo.md is denied" {
  run_hook_edit "code-audit-frontend" "Edit" "wiki/concepts/Foo.md"
  assert_denied
}

@test "code-audit-frontend editing root package.json is denied" {
  run_hook_edit "code-audit-frontend" "Edit" "package.json"
  assert_denied
}

@test "code-audit-frontend editing root tsconfig.base.json is denied" {
  run_hook_edit "code-audit-frontend" "Edit" "tsconfig.base.json"
  assert_denied
}

@test "code-audit-frontend editing root vite.config.ts is denied" {
  run_hook_edit "code-audit-frontend" "Edit" "vite.config.ts"
  assert_denied
}

@test "an advisory member (code-audit-github-workflows) is denied on .github/workflows/tests.yml too" {
  run_hook_edit "code-audit-github-workflows" "Edit" ".github/workflows/tests.yml"
  assert_denied
}

@test "code-audit-maintainer-shell editing test/foo.ts is denied (every member, not just the self-healer)" {
  run_hook_edit "code-audit-maintainer-shell" "Edit" "test/foo.ts"
  assert_denied
}

# --- every test surface is refused, not just test/ ---
#
# .playwright/ holds the e2e specs, the a11y assertions, and the react-perf
# harness; .storybook/ holds the config and decorators that shape what
# Chromatic snapshots, and Chromatic is a required merge check. Both carry
# test/'s own rationale: a member must not be able to edit the assertion that
# would catch its own bad repair. These pin that, so the refusal set cannot
# silently narrow back to test/ alone.

@test "code-audit-frontend editing .playwright/e2e/hydration.spec.ts is denied and names the path" {
  run_hook_edit "code-audit-frontend" "Edit" ".playwright/e2e/hydration.spec.ts"
  assert_denied
  grep -qF -- '.playwright/e2e/hydration.spec.ts' <<<"$output"
}

@test "code-audit-frontend editing .playwright/utils.ts is denied (the whole tree, not just e2e/)" {
  run_hook_edit "code-audit-frontend" "Edit" ".playwright/utils.ts"
  assert_denied
}

@test "code-audit-frontend editing .storybook/preview.ts is denied and names the path" {
  run_hook_edit "code-audit-frontend" "Edit" ".storybook/preview.ts"
  assert_denied
  grep -qF -- '.storybook/preview.ts' <<<"$output"
}

@test "code-audit-frontend editing .storybook/chromatic/decorator.tsx is denied" {
  run_hook_edit "code-audit-frontend" "Edit" ".storybook/chromatic/decorator.tsx"
  assert_denied
}

@test "Bash: code-audit-frontend redirecting into a .playwright/ spec is denied" {
  run_hook_bash "code-audit-frontend" "echo x > .playwright/e2e/hydration.spec.ts"
  assert_denied
}

# --- an app-only edit still allowed, criterion 3 ---

@test "code-audit-frontend editing app/foo.ts is allowed" {
  run_hook_edit "code-audit-frontend" "Edit" "app/foo.ts"
  assert_allowed
}

@test "Write tool: code-audit-frontend writing app/Foo/index.tsx is allowed" {
  run_hook_edit "code-audit-frontend" "Write" "app/Foo/index.tsx"
  assert_allowed
}

@test "MultiEdit tool: code-audit-frontend editing test/foo.ts is denied" {
  run_hook_edit "code-audit-frontend" "MultiEdit" "test/foo.ts"
  assert_denied
}

# --- .gaia/local/ is the members' own gitignored artifact dir, never refused ---
# A member writes its clearance marker, findings sidecar, disposition sidecar,
# and re-run ledger under .gaia/local/audit/. Refusing that directory blocks
# the sidecars this team writes and deadlocks the merge gate via the
# disposition backstop. Everything else under .gaia/ stays refused.

@test "code-audit-frontend writing its findings sidecar under .gaia/local/audit/ is allowed" {
  run_hook_edit "code-audit-frontend" "Write" ".gaia/local/audit/2cea369b.code-audit-frontend.findings.json"
  assert_allowed
}

@test "code-audit-frontend writing its disposition sidecar under .gaia/local/audit/ is allowed" {
  run_hook_edit "code-audit-frontend" "Write" ".gaia/local/audit/abc123.dispositions.json"
  assert_allowed
}

@test "Bash: code-audit-frontend redirecting into a .gaia/local/audit/ sidecar is allowed" {
  run_hook_bash "code-audit-frontend" "printf '%s' '{}' > .gaia/local/audit/abc123.dispositions.json"
  assert_allowed
}

@test "code-audit-frontend editing .gaia/localfoo/x.sh (a sibling, not the carve-out) is denied" {
  run_hook_edit "code-audit-frontend" "Edit" ".gaia/localfoo/x.sh"
  assert_denied
}

@test "code-audit-frontend editing .gaia/scripts/x.sh (machinery, not .gaia/local) is denied" {
  run_hook_edit "code-audit-frontend" "Edit" ".gaia/scripts/x.sh"
  assert_denied
}

# --- root vs nested build config, criterion 4 ---

@test "code-audit-frontend editing nested app/foo.config.ts is allowed (root-only arm)" {
  run_hook_edit "code-audit-frontend" "Edit" "app/foo.config.ts"
  assert_allowed
}

@test "code-audit-frontend editing nested app/package.json is allowed (root-only arm)" {
  run_hook_edit "code-audit-frontend" "Edit" "app/package.json"
  assert_allowed
}

# --- absolute paths relativize against the repo root ---

@test "an absolute path under the repo root is relativized before matching (denied)" {
  local repo_root
  repo_root=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  run_hook_edit "code-audit-frontend" "Edit" "$repo_root/test/foo.ts"
  assert_denied
}

@test "an absolute path OUTSIDE the repo root is left alone (allowed)" {
  run_hook_edit "code-audit-frontend" "Edit" "/tmp/some-other-place/test/foo.ts"
  assert_allowed
}

# --- Bash write vectors ---

@test "Bash: code-audit-frontend redirecting into test/foo.ts is denied" {
  run_hook_bash "code-audit-frontend" "echo x > test/foo.ts"
  assert_denied
}

@test "Bash: code-audit-frontend appending into .gaia/audit-ci.yml is denied" {
  run_hook_bash "code-audit-frontend" "cat frag >> .gaia/audit-ci.yml"
  assert_denied
}

@test "Bash: code-audit-frontend tee into .github/workflows/tests.yml is denied" {
  run_hook_bash "code-audit-frontend" "tee .github/workflows/tests.yml"
  assert_denied
}

@test "Bash: code-audit-frontend sponge into test/foo.ts is denied" {
  run_hook_bash "code-audit-frontend" "cat test/foo.ts | sponge test/foo.ts"
  assert_denied
}

@test "Bash: code-audit-frontend sed -i (macOS empty-suffix) on .gaia/audit-ci.yml is denied" {
  run_hook_bash "code-audit-frontend" "sed -i '' 's/a/b/' .gaia/audit-ci.yml"
  assert_denied
}

@test "Bash: code-audit-frontend sed -i (GNU) on test/foo.ts is denied" {
  run_hook_bash "code-audit-frontend" "sed -i 's/a/b/' test/foo.ts"
  assert_denied
}

@test "Bash: code-audit-frontend cp with test/foo.ts as destination is denied" {
  run_hook_bash "code-audit-frontend" "cp /tmp/x.ts test/foo.ts"
  assert_denied
}

@test "Bash: code-audit-frontend mv with .github/workflows/x.yml as destination is denied" {
  run_hook_bash "code-audit-frontend" "mv /tmp/x.yml .github/workflows/x.yml"
  assert_denied
}

@test "Bash: code-audit-frontend cp with test/foo.ts as SOURCE (not destination) is allowed" {
  run_hook_bash "code-audit-frontend" "cp test/foo.ts /tmp/backup.ts"
  assert_allowed
}

@test "Bash: code-audit-frontend redirecting into app/foo.ts is allowed" {
  run_hook_bash "code-audit-frontend" "echo x > app/foo.ts"
  assert_allowed
}

@test "Bash: no agent_type, redirecting into .gaia/audit-ci.yml is allowed (orchestrator)" {
  run_hook_bash "" "echo x > .gaia/audit-ci.yml"
  assert_allowed
}

@test "Bash: a plain git command with no write vector is allowed" {
  run_hook_bash "code-audit-frontend" "git status"
  assert_allowed
}

# --- the remit writer is an execution-shape refusal, not a write-shape one ---

@test "SPEC-056 UAT-015: code-audit-frontend running the remit writer is denied" {
  run_hook_bash "code-audit-frontend" "bash .gaia/scripts/write-audit-remits.sh"
  assert_denied
  grep -qF -- "finding" <<<"$output"
}

@test "SPEC-056 UAT-015: an advisory member running the remit writer is denied too" {
  run_hook_bash "code-audit-maintainer-shell" "bash .gaia/scripts/write-audit-remits.sh"
  assert_denied
}

@test "SPEC-056 UAT-015: the writer invoked by an absolute path is denied" {
  run_hook_bash "code-audit-frontend" "bash /Users/you/projects/my-app/.gaia/scripts/write-audit-remits.sh"
  assert_denied
}

@test "SPEC-056 UAT-015: the writer invoked with a leading ./ is denied" {
  run_hook_bash "code-audit-frontend" "bash ./.gaia/scripts/write-audit-remits.sh"
  assert_denied
}

@test "SPEC-056 UAT-015: no agent_type running the remit writer is allowed" {
  run_hook_bash "" "bash .gaia/scripts/write-audit-remits.sh"
  assert_allowed
}

@test "SPEC-056 UAT-015: a non-member subagent running the remit writer is allowed" {
  run_hook_bash "general-purpose" "bash .gaia/scripts/write-audit-remits.sh"
  assert_allowed
}

@test "SPEC-056 UAT-015: neither payload writes a file" {
  local agents_dir before after
  agents_dir="$BATS_TEST_DIRNAME/../../../.claude/agents"
  before=$(find "$agents_dir" -type f -exec shasum {} + | sort)
  run_hook_bash "code-audit-frontend" "bash .gaia/scripts/write-audit-remits.sh"
  run_hook_bash "" "bash .gaia/scripts/write-audit-remits.sh"
  after=$(find "$agents_dir" -type f -exec shasum {} + | sort)
  [ "$before" = "$after" ]
}

@test "SPEC-056 UAT-015: running the roster CHECK is still allowed for a member" {
  run_hook_bash "code-audit-frontend" "bash .gaia/scripts/verify-audit-roster.sh"
  assert_allowed
}

@test "SPEC-056 UAT-015: shellcheck naming the writer as an argument is allowed, not an invocation" {
  # The execution-shape refusal is anchored to an EXECUTABLE position (token
  # 0, or right after an interpreter / a ; && || | separator), not to any
  # token that merely names the file. A read-only command like `shellcheck`
  # naming the writer as an argument must stay allowed, including the
  # shell auditor's own mandated methodology against this very file.
  run_hook_bash "code-audit-maintainer-shell" "shellcheck .gaia/scripts/write-audit-remits.sh"
  assert_allowed
}

@test "SPEC-056 UAT-015: the writer invoked bare (no interpreter) is denied" {
  run_hook_bash "code-audit-frontend" ".gaia/scripts/write-audit-remits.sh"
  assert_denied
}

@test "SPEC-056 UAT-015: the writer invoked after a && separator is denied" {
  run_hook_bash "code-audit-frontend" "true && bash .gaia/scripts/write-audit-remits.sh"
  assert_denied
}

# --- execution-position anchor: skip interpreter options and env assignments ---

@test "SPEC-056 UAT-015: bash -x <writer> is denied" {
  run_hook_bash "code-audit-frontend" "bash -x .gaia/scripts/write-audit-remits.sh"
  assert_denied
}

@test "SPEC-056 UAT-015: sh -x <writer> is denied" {
  run_hook_bash "code-audit-frontend" "sh -x .gaia/scripts/write-audit-remits.sh"
  assert_denied
}

@test "SPEC-056 UAT-015: bash --norc <writer> is denied" {
  run_hook_bash "code-audit-frontend" "bash --norc .gaia/scripts/write-audit-remits.sh"
  assert_denied
}

@test "SPEC-056 UAT-015: env FOO=1 <writer> is denied" {
  run_hook_bash "code-audit-frontend" "env FOO=1 .gaia/scripts/write-audit-remits.sh"
  assert_denied
}

@test "SPEC-056 UAT-015: nohup <writer> is denied" {
  run_hook_bash "code-audit-frontend" "nohup .gaia/scripts/write-audit-remits.sh"
  assert_denied
}

# --- structural ---

@test "block-selfheal-paths.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json is valid JSON" {
  run jq empty "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command == ".claude/hooks/block-selfheal-paths.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers the hook under the Bash matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == ".claude/hooks/block-selfheal-paths.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
