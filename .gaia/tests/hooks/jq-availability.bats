#!/usr/bin/env bats

# Tests for .claude/hooks/lib/jq-availability.sh as the PreToolUse layer runs
# it: every blocking hook driven with jq off PATH, against a payload inside its
# remit and, where the hook carries binding literals, one outside it.
#
# The suite is per-layer rather than per-hook because the claim is a property of
# the layer: with no jq on PATH the fail-closed hooks refuse and the advisory
# ones stand down. A copy of these two assertions in each hook's own suite would
# be one place per hook for the claim to drift, and the arm they all reach is
# one function.
#
# WHAT A FAILURE HERE MEANS. The hook read its payload with jq under errexit and
# died at status 127, which the PreToolUse contract reads as a NON-BLOCKING
# error: the call it was written to deny proceeded, with no denial and no
# diagnostic. That is the defect the arm exists to close, and a green run of the
# hook's own suite says nothing about it, because every other test in those
# suites runs with jq present.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/tests/hooks/jq-availability.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
}

# The mirroring rebuild rather than the dropping one: jq shares a directory with
# the bash, grep and cat both the hooks and these assertions still need, so
# dropping the directory would take them too (.gaia/tests/helpers/path.sh).
scrub_jq_from_path() {
  local rebuilt
  rebuilt="$(path_shim_without jq)"
  export PATH="$rebuilt"
}

# without_jq <hook-basename> <payload>
#
# The payload is built by the caller while jq is still reachable; only the hook
# runs without it.
without_jq() {
  scrub_jq_from_path
  [ -z "$(command -v jq)" ]
  invoke_hook "$2" "$HOOKS_SRC/$1"
}

# THE AMBIENT FIELDS ARE THE POINT, not padding. A PreToolUse payload carries
# session_id, transcript_path and cwd ahead of tool_input, and every one of the
# three is a filesystem path nobody chose for this purpose. The two below are
# built to carry every binding literal any hook here passes, as a substring, in a
# path shape a real machine could have: a "platform" directory supplies the rm
# literal, a "git-svc" one the git literal, a ".venv" the env literal, a
# "settings" the process-dump literal, a "highlights" one the gh literal, an
# "org-mirror" one the rg literal, a "ripgrep" checkout the grep literal, a
# "storage" one the ag literal, and so on down to .pem, .key and manifest.json.
# Read each of those as the contiguous run it has to be: `.github` spells no
# `gh` and `ripgrep` spells no `rg`, and a segment chosen for how it looks
# rather than for what it contains leaves the tests below unable to fail.
#
# So an arm matching its literals against the whole document denies every
# still-allowed case below, the jq install among them, which is the session with
# no way out the literals exist to prevent, reached by the mechanism meant to
# prevent it. These builders are what make that a red rather than a green.
#
# ONE literal is deliberately absent: `code-audit-`. block-selfheal-paths.sh
# binds on the top-level agent_type, so it scans the whole document by design and
# is correct to; poisoning the ambient fields with its literal would assert the
# opposite of that hook's contract.
readonly AMBIENT_CWD="/Users/you/work/platform/git-svc/highlights/org-mirror/ripgrep/storage/.venv/settings/test-credentials/secrets"
readonly AMBIENT_TRANSCRIPT="/Users/you/.claude/projects/gaia-plan/manifest.json.d/server.pem/id.key/plan.md.log"

# The key order mirrors the harness: every ambient field precedes tool_input.
ambient() {
  jq -n --arg c "$AMBIENT_CWD" --arg t "$AMBIENT_TRANSCRIPT" \
    '{session_id: "0193-fixture", transcript_path: $t, cwd: $c, hook_event_name: "PreToolUse"}'
}

# The Bash tool's tool_input carries a model-authored `description` beside the
# command, and no caller predicate reads it, so it is the same class of field as
# the ambient head one level deeper. This one carries every literal any
# Bash-matcher caller passes -- "Confirm" holds rm, "latest" holds test,
# "environment" holds env, "setup" holds the dump spelling -- so an arm that
# stops cutting it denies the jq install on the wording of its own description.
readonly AMBIENT_DESCRIPTION="Confirm the latest environment setup, gitignore and permissions"

bash_payload() {
  jq -n --argjson a "$(ambient)" --arg c "$1" --arg d "$AMBIENT_DESCRIPTION" \
    '$a + {tool_name: "Bash", tool_input: {command: $c, description: $d}}'
}

# The same fields with the two tool_input keys swapped. No session produces this
# order today -- which is exactly why it needs a builder: the arm's description
# cut must not depend on an emission order GAIA does not control, and the
# command-first builder above pins nothing about the other order.
#
# Both claims the command-first pair makes are re-made against it, and each
# catches a different way the cut can go wrong. The refusal catches a cut that
# takes the command out of the haystack along with the description, which is the
# fail-open direction on the guard whose purpose is to close it. The allow
# catches a cut that gives up and leaves the description in the haystack, which
# denies the jq install on the wording of its own description: the session with
# no way out from inside it.
bash_payload_description_first() {
  jq -n --argjson a "$(ambient)" --arg c "$1" --arg d "$AMBIENT_DESCRIPTION" \
    '$a + {tool_name: "Bash", tool_input: {description: $d, command: $c}}'
}

edit_payload() {
  jq -n --argjson a "$(ambient)" --arg p "$1" \
    '$a + {tool_name: "Edit", tool_input: {file_path: $p, new_string: "x"}}'
}

# The command that repairs the machine. Every literal set below is checked
# against it, because a hook whose refusal catches this one leaves the session
# with no way out from inside it.
readonly INSTALL_CMD="brew install jq"

# --- the matcher cannot reach the jq install, so the refusal is unconditional -

@test "jq absent: block-env-write refuses an edit rather than letting it through" {
  local json
  json=$(edit_payload ".env.local")
  without_jq block-env-write.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-eslint-config-edit refuses an edit" {
  local json
  json=$(edit_payload "eslint.config.ts")
  without_jq block-eslint-config-edit.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-invalid-yaml-write refuses an edit" {
  local json
  json=$(edit_payload ".github/workflows/ci.yml")
  without_jq block-invalid-yaml-write.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-lockfile-edit refuses an edit" {
  local json
  json=$(edit_payload "pnpm-lock.yaml")
  without_jq block-lockfile-edit.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-secrets-write refuses a write carrying a key" {
  local json
  json=$(edit_payload "app/config.ts")
  without_jq block-secrets-write.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-vitest-globals-tsconfig refuses an edit" {
  local json
  json=$(edit_payload "tsconfig.json")
  without_jq block-vitest-globals-tsconfig.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-worktree-path-mismatch refuses an edit" {
  local json
  json=$(edit_payload "app/foo.ts")
  without_jq block-worktree-path-mismatch.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-serena-cross-tree-activation refuses an activation" {
  local json
  json=$(jq -n '{tool_name: "mcp__serena__activate_project", tool_input: {project: "/tmp/other"}}')
  without_jq block-serena-cross-tree-activation.sh "$json"
  assert_blocked_by_exit
}

# --- the matcher CAN reach the jq install, so the refusal is narrowed ---------
#
# Each pair is the whole claim: the in-remit call is refused, and the install
# that repairs the machine is not.

@test "jq absent: block-env-read refuses a dotenv read" {
  local json
  json=$(bash_payload "cat .env.local")
  without_jq block-env-read.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-env-read allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq block-env-read.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-main-destructive-git refuses a git command" {
  local json
  json=$(bash_payload "git push --force origin main")
  without_jq block-main-destructive-git.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-main-destructive-git allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq block-main-destructive-git.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-no-verify refuses a git command" {
  local json
  json=$(bash_payload "git commit --no-verify -m x")
  without_jq block-no-verify.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-no-verify allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq block-no-verify.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-manifest-write refuses a write to the manifest" {
  local json
  json=$(edit_payload ".gaia/manifest.json")
  without_jq block-manifest-write.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-manifest-write allows an edit naming no manifest" {
  local json
  json=$(edit_payload "app/foo.ts")
  without_jq block-manifest-write.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-rm-rf refuses a command carrying its literal" {
  local json
  json=$(bash_payload "rm -rf /")
  without_jq block-rm-rf.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-rm-rf allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq block-rm-rf.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-secrets-read refuses a read of a key path" {
  local json
  json=$(jq -n '{tool_name: "Read", tool_input: {file_path: "certs/server.pem"}}')
  without_jq block-secrets-read.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-secrets-read allows a read naming no secret class" {
  local json
  json=$(jq -n '{tool_name: "Read", tool_input: {file_path: "README.md"}}')
  without_jq block-secrets-read.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-spec-plan-chain refuses the skill it denies" {
  local json
  json=$(jq -n '{hook_event_name: "PreToolUse", tool_name: "Skill", tool_input: {name: "gaia-plan"}}')
  without_jq block-spec-plan-chain.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-spec-plan-chain allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq block-spec-plan-chain.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-fourth-audit-round refuses a member dispatch" {
  local json
  json=$(jq -n '{hook_event_name: "PreToolUse", tool_name: "Agent", tool_input: {subagent_type: "code-audit-frontend"}}')
  without_jq block-fourth-audit-round.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-fourth-audit-round allows a dispatch naming no member" {
  local json
  json=$(jq -n '{hook_event_name: "PreToolUse", tool_name: "Agent", tool_input: {subagent_type: "general-purpose"}}')
  without_jq block-fourth-audit-round.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-selfheal-paths refuses a member edit" {
  local json
  json=$(jq -n '{agent_type: "code-audit-frontend", tool_name: "Edit", tool_input: {file_path: "test/foo.ts"}}')
  without_jq block-selfheal-paths.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-selfheal-paths allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq block-selfheal-paths.sh "$json"
  assert_allowed_by_exit
}

# The gates converted off the `|| exit 0` stand-down, each in-remit case naming
# the verb that gate's own predicate binds on, so a conversion that dropped its
# literal would green the refusal here and red the install beside it.

@test "jq absent: audit-disposition-check refuses a merge attempt" {
  local json
  json=$(bash_payload "gh pr merge 42 --squash")
  without_jq audit-disposition-check.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: audit-disposition-check allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq audit-disposition-check.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: pr-merge-audit-check refuses a merge attempt" {
  local json
  json=$(bash_payload "gh pr merge 42 --squash")
  without_jq pr-merge-audit-check.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: pr-merge-audit-check allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq pr-merge-audit-check.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: worthiness-presence-check refuses a merge attempt" {
  local json
  json=$(bash_payload "gh pr merge 42 --squash")
  without_jq worthiness-presence-check.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: worthiness-presence-check allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq worthiness-presence-check.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: distribution-preflight-check refuses a PR creation" {
  local json
  json=$(bash_payload "gh pr create --title x --body y")
  without_jq distribution-preflight-check.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: distribution-preflight-check allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq distribution-preflight-check.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: serena-code-search-guard refuses a shell symbol search" {
  local json
  json=$(bash_payload "grep -r useBreakpoint app")
  without_jq serena-code-search-guard.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: serena-code-search-guard allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_CMD")
  without_jq serena-code-search-guard.sh "$json"
  assert_allowed_by_exit
}

# --- the advisory hooks stand down, which is the opposite obligation ---------
#
# They nudge and never deny, so refusing on a missing interpreter would trade a
# lost reminder for a blocked session. The pair below is what keeps a later
# uniformity pass from "fixing" them into refusals.

@test "jq absent: check-i18n-strings stands down silently" {
  local json
  json=$(edit_payload "app/pages/Home/index.tsx")
  without_jq check-i18n-strings.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: check-story-exists stands down silently" {
  local json
  json=$(edit_payload "app/components/Button/index.tsx")
  without_jq check-story-exists.sh "$json"
  assert_allowed_by_exit
}

# --- the arm's own library is unreachable ------------------------------------

@test "a mis-arity call refuses rather than dying at a non-blocking status" {
  # A caller that omits an argument would expand an unset positional under the
  # errexit-and-nounset every armed hook arms, ending it at status 1, which
  # PreToolUse reads as a NON-BLOCKING error: the same fail-open a missing call
  # produces, reached by a different edit. The arm checks its own arity so a
  # wrong call is loud.
  local lib
  lib="$HOOKS_SRC/lib/jq-availability.sh"
  run bash -c 'set -euo pipefail; . "$1"; gaia_require_jq "only one arg"' _ "$lib"
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
  grep -qF -- 'needs at least 3' <<<"$output"
}

@test "the library missing refuses too, rather than running the hook unguarded" {
  # A hook resolves the library from its own on-disk location, so a copy in a
  # tree with an empty lib/ reproduces a broken install without touching the
  # real one. jq stays on PATH here: the claim is about the load, not about the
  # interpreter.
  local dir json
  dir="$BATS_TEST_TMPDIR/no-lib"
  mkdir -p "$dir/lib"
  cp "$HOOKS_SRC/block-lockfile-edit.sh" "$dir/block-lockfile-edit.sh"

  json=$(edit_payload "pnpm-lock.yaml")
  invoke_hook "$json" "$dir/block-lockfile-edit.sh"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot load lib/jq-availability.sh' <<<"$output"
}
