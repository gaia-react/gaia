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

# bats file_tags=whole-tree

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
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
  invoke_hook "$2" "$HOOKS_SOURCE_DIRECTORY/$1"
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
readonly INSTALL_COMMAND="brew install jq"

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

@test "jq absent: block-secrets-write refuses a write carrying a key" {
  local json
  json=$(edit_payload "app/config.ts")
  without_jq block-secrets-write.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: block-worktree-path-mismatch refuses an edit" {
  local json
  json=$(edit_payload "app/foo.ts")
  without_jq block-worktree-path-mismatch.sh "$json"
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
  json=$(bash_payload "$INSTALL_COMMAND")
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
  json=$(bash_payload "$INSTALL_COMMAND")
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
  json=$(bash_payload "$INSTALL_COMMAND")
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
  json=$(bash_payload "$INSTALL_COMMAND")
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

# The Agent payload keeps the harness key order: ambient head first, then the
# tool call. The bound hook's binding literal is the member-name prefix, which
# no ambient path carries.
agent_payload() {
  jq -n --argjson a "$(ambient)" --arg s "$1" \
    '$a + {tool_name: "Agent", tool_input: {subagent_type: $s}}'
}

@test "jq absent: audit-loop-bound refuses a member dispatch" {
  local json
  json=$(agent_payload "code-audit-frontend")
  without_jq audit-loop-bound.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: audit-loop-bound allows a dispatch naming no member" {
  local json
  json=$(agent_payload "general-purpose")
  without_jq audit-loop-bound.sh "$json"
  assert_allowed_by_exit
}

write_payload() {
  jq -n --argjson a "$(ambient)" --arg p "$1" \
    '$a + {tool_name: "Write", tool_input: {file_path: $p, content: "x"}}'
}

@test "jq absent: block-audit-loop-write refuses a write under the loop state" {
  local json
  json=$(write_payload ".gaia/local/protected/audit-loop/state.json")
  without_jq block-audit-loop-write.sh "$json"
  assert_blocked_by_exit
}

# The protected folder is armed by the `local/protected` literal alone: none of
# these payloads names `audit-loop`, so an omitted literal would exit 0 here.
@test "jq absent: block-audit-loop-write refuses a write naming only a new file in the protected folder" {
  local json
  json=$(write_payload "/Users/you/work/repo/.gaia/local/protected/new-state.json")
  grep -qF -- 'audit-loop' <<<"$json" && return 1
  without_jq block-audit-loop-write.sh "$json"
  assert_blocked_by_exit
  grep -qF -- 'cannot be checked' <<<"$output"
}

@test "jq absent: block-audit-loop-write refuses a write naming only the override file" {
  local json
  json=$(write_payload "/Users/you/work/repo/.gaia/local/protected/checkpoint-override.json")
  grep -qF -- 'audit-loop' <<<"$json" && return 1
  without_jq block-audit-loop-write.sh "$json"
  assert_blocked_by_exit
  grep -qF -- 'cannot be checked' <<<"$output"
}

@test "jq absent: block-audit-loop-write refuses a redirect into the protected folder" {
  local json
  json=$(bash_payload "printf x > /Users/you/work/repo/.gaia/local/protected/new-state.json")
  grep -qF -- 'audit-loop' <<<"$json" && return 1
  without_jq block-audit-loop-write.sh "$json"
  assert_blocked_by_exit
  grep -qF -- 'cannot be checked' <<<"$output"
}

@test "jq absent: block-audit-loop-write allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_COMMAND")
  without_jq block-audit-loop-write.sh "$json"
  assert_allowed_by_exit
}

@test "jq absent: block-audit-loop-write allows an unrelated write" {
  local json
  json=$(write_payload "app/foo.ts")
  without_jq block-audit-loop-write.sh "$json"
  assert_allowed_by_exit
}

# The grant hook runs on UserPromptSubmit, so its payload carries that head and
# a prompt rather than a tool call. The ambient path noise stays in cwd and
# transcript_path.
grant_payload() {
  jq -n --arg c "$AMBIENT_CWD" --arg t "$AMBIENT_TRANSCRIPT" --arg p "$1" \
    '{session_id: "0193-fixture", transcript_path: $t, cwd: $c, hook_event_name: "UserPromptSubmit", prompt: $p}'
}

state_listing() {
  local audit_loop_directory
  audit_loop_directory="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/local/protected/audit-loop"
  if [ -d "$audit_loop_directory" ]; then
    find "$audit_loop_directory" -print | sort
  fi
  true
}

@test "jq absent: audit-loop-grant says so and records nothing for a grant line" {
  local json before after
  json=$(grant_payload "audit-grant 2")
  before=$(state_listing)
  without_jq audit-loop-grant.sh "$json"
  after=$(state_listing)
  [ "$status" -eq 0 ]
  grep -qF -- 'jq is missing' <<<"$output"
  [ "$before" = "$after" ]
}

@test "jq absent: audit-loop-grant stays silent for a prompt without the keyword" {
  local json
  json=$(grant_payload "please continue")
  without_jq audit-loop-grant.sh "$json"
  assert_allowed_by_exit
}

# The gates converted off the `|| exit 0` stand-down, each in-remit case naming
# the verb that gate's own predicate binds on, so a conversion that dropped its
# literal would green the refusal here and red the install beside it.

@test "jq absent: pr-merge-audit-check refuses a merge attempt" {
  local json
  json=$(bash_payload "gh pr merge 42 --squash")
  without_jq pr-merge-audit-check.sh "$json"
  assert_blocked_by_exit
}

@test "jq absent: pr-merge-audit-check allows the jq install" {
  local json
  json=$(bash_payload "$INSTALL_COMMAND")
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
  json=$(bash_payload "$INSTALL_COMMAND")
  without_jq worthiness-presence-check.sh "$json"
  assert_allowed_by_exit
}

# --- the arm's own library is unreachable ------------------------------------

@test "a mis-arity call refuses rather than dying at a non-blocking status" {
  # A caller that omits an argument would expand an unset positional under the
  # errexit-and-nounset every armed hook arms, ending it at status 1, which
  # PreToolUse reads as a NON-BLOCKING error: the same fail-open a missing call
  # produces, reached by a different edit. The arm checks its own arity so a
  # wrong call is loud.
  local library_path
  library_path="$HOOKS_SOURCE_DIRECTORY/lib/jq-availability.sh"
  run bash -c 'set -euo pipefail; . "$1"; gaia_require_jq "only one arg"' _ "$library_path"
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
  grep -qF -- 'needs at least 3' <<<"$output"
}

@test "the library missing refuses too, rather than running the hook unguarded" {
  # A hook resolves the library from its own on-disk location, so a copy in a
  # tree with an empty lib/ reproduces a broken install without touching the
  # real one. jq stays on PATH here: the claim is about the load, not about the
  # interpreter.
  local scratch_directory json
  scratch_directory="$BATS_TEST_TMPDIR/no-lib"
  mkdir -p "$scratch_directory/lib"
  cp "$HOOKS_SOURCE_DIRECTORY/block-eslint-config-edit.sh" "$scratch_directory/block-eslint-config-edit.sh"

  json=$(edit_payload "eslint.config.ts")
  invoke_hook "$json" "$scratch_directory/block-eslint-config-edit.sh"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot load lib/jq-availability.sh' <<<"$output"
}
