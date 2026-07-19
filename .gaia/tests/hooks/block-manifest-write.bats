#!/usr/bin/env bats

# Tests for .claude/hooks/block-manifest-write.sh.
#
# `.gaia/manifest.json` is release-generated; adopter feature work never adds
# to it. This guard denies writes to it through the edit tools (Edit / Write /
# MultiEdit, no exemption) and through common Bash write vectors (output
# redirects, tee, sed -i, sponge, cp/mv as destination), while allowing reads
# and the two legitimate Bash writers that prepend the GAIA_MANIFEST_WRITE=
# exemption marker. The guard is best-effort, not airtight: it always exits 0,
# carrying the allow/deny decision in stdout JSON.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-manifest-write.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Quote-safe delivery (mandatory): several payloads below carry Bash commands
# that contain single quotes of their own (echo '{}' > ..., sed -i '' ..., a
# jq '...' filter). Re-wrapping $json in an outer single-quoted `bash -c '...'`
# string would let those embedded quotes terminate the wrapper early and strip
# the inner quoting before it reaches the hook. Passing $json and $HOOK_ABS as
# positional args instead means no re-quoting happens.
run_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg t "$tool" --arg p "$path" '{tool_name: $t, tool_input: {file_path: $p}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_bash() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# --- denied: edit tools, no exemption ---

@test "Edit on .gaia/manifest.json is denied" {
  run_hook_edit "Edit" ".gaia/manifest.json"
  assert_denied
}

@test "Write on .gaia/manifest.json is denied" {
  run_hook_edit "Write" ".gaia/manifest.json"
  assert_denied
}

@test "MultiEdit on .gaia/manifest.json is denied" {
  run_hook_edit "MultiEdit" ".gaia/manifest.json"
  assert_denied
}

@test "Edit on an absolute path ending /.gaia/manifest.json is denied" {
  run_hook_edit "Edit" "/Users/you/projects/my-app/.gaia/manifest.json"
  assert_denied
}

# --- allowed: edit tools ---

@test "Edit on .gaia/manifest.json.tmp is allowed" {
  run_hook_edit "Edit" ".gaia/manifest.json.tmp"
  assert_allowed
}

@test "Edit on .gaia/manifest.json.bak is allowed" {
  run_hook_edit "Edit" ".gaia/manifest.json.bak"
  assert_allowed
}

@test "Write on public/site.webmanifest is allowed" {
  run_hook_edit "Write" "public/site.webmanifest"
  assert_allowed
}

@test "Edit on an unrelated plan README is allowed" {
  run_hook_edit "Edit" ".gaia/local/plans/x/README.md"
  assert_allowed
}

# --- denied: Bash write vectors, no marker ---

@test "jq rewrite redirected back into the manifest is denied" {
  run_hook_bash "jq '.files += {\"app/x.tsx\":\"owned\"}' .gaia/manifest.json > .gaia/manifest.json"
  assert_denied
}

@test "echo redirect overwriting the manifest is denied (quote-safety canary)" {
  # This payload's command text carries single quotes of its own; a denial
  # here proves the harness's quote-safe delivery is wired correctly, not
  # just that the guard logic works.
  run_hook_bash "echo '{}' > .gaia/manifest.json"
  assert_denied
}

@test "append redirect onto the manifest is denied" {
  run_hook_bash "cat frag >> .gaia/manifest.json"
  assert_denied
}

@test "sed -i with a macOS empty backup suffix targeting the manifest is denied" {
  run_hook_bash "sed -i '' 's/a/b/' .gaia/manifest.json"
  assert_denied
}

@test "sed -i (GNU, no backup suffix) targeting the manifest is denied" {
  run_hook_bash "sed -i 's/a/b/' .gaia/manifest.json"
  assert_denied
}

@test "cp with the manifest as destination is denied" {
  run_hook_bash "cp /tmp/x.json .gaia/manifest.json"
  assert_denied
}

@test "mv with the manifest as destination is denied" {
  run_hook_bash "mv /tmp/x.json .gaia/manifest.json"
  assert_denied
}

@test "tee targeting the manifest is denied" {
  run_hook_bash "tee .gaia/manifest.json"
  assert_denied
}

@test "sponge targeting the manifest is denied" {
  run_hook_bash "jq '.files' .gaia/manifest.json | sponge .gaia/manifest.json"
  assert_denied
}

@test "a quoted redirect target is still denied" {
  run_hook_bash 'echo x > ".gaia/manifest.json"'
  assert_denied
}

@test "marker as an echo argument does not exempt the redirect it precedes" {
  run_hook_bash 'echo GAIA_MANIFEST_WRITE=hi > .gaia/manifest.json'
  assert_denied
}

@test "marker inside a quoted string does not exempt the redirect it precedes" {
  # Quote-safe delivery (mandatory): the command text carries its own double
  # quotes around the marker.
  run_hook_bash 'echo "GAIA_MANIFEST_WRITE=x" > .gaia/manifest.json'
  assert_denied
}

@test "a marked segment does not exempt a later unmarked segment after &&" {
  run_hook_bash "GAIA_MANIFEST_WRITE=1 echo ok && sed -i '' 's/a/b/' .gaia/manifest.json"
  assert_denied
}

@test "marker inside a sed script does not exempt the in-place edit" {
  run_hook_bash "sed -i '' 's/GAIA_MANIFEST_WRITE=//' .gaia/manifest.json"
  assert_denied
}

# --- denied: multi-line commands ---

@test "a redirect write on line 2 of a multi-line command is denied" {
  run_hook_bash $'echo ok\nprintf x > .gaia/manifest.json'
  assert_denied
}

@test "a marker on line 1 does not exempt an unmarked write on line 2" {
  run_hook_bash $'GAIA_MANIFEST_WRITE=1 echo ok\nsed -i \'\' \'s/a/b/\' .gaia/manifest.json'
  assert_denied
}

# --- denied: no-space redirect shapes ---

@test "a no-space redirect (>path, no space after >) onto the manifest is denied" {
  run_hook_bash 'echo x >.gaia/manifest.json'
  assert_denied
}

@test "a no-space append redirect (>>path, no space after >>) onto the manifest is denied" {
  run_hook_bash 'echo x >>.gaia/manifest.json'
  assert_denied
}

@test "a no-space redirect with a \$(...) prefix in the target is denied" {
  run_hook_bash 'echo x >"$(pwd)/.gaia/manifest.json"'
  assert_denied
}

@test "a no-space redirect to a manifest-adjacent path is still allowed" {
  run_hook_bash 'echo x >.gaia/manifest.json.bak'
  assert_allowed
}

# --- allowed: Bash with the GAIA_MANIFEST_WRITE= exemption marker ---

@test "marked release cp is allowed" {
  run_hook_bash 'GAIA_MANIFEST_WRITE=release cp "$LATEST_DIR/.gaia/manifest.json" .gaia/manifest.json'
  assert_allowed
}

@test "a marked write on line 2 of a multi-line command is allowed" {
  run_hook_bash $'echo prep\nGAIA_MANIFEST_WRITE=release cp x .gaia/manifest.json'
  assert_allowed
}

@test "marked remove-i18n jq step is allowed" {
  run_hook_bash "GAIA_MANIFEST_WRITE=remove-i18n jq 'del(.files[\"app/i18n.ts\"])' .gaia/manifest.json > .gaia/manifest.json.tmp"
  assert_allowed
}

@test "marked remove-i18n mv step is allowed" {
  run_hook_bash 'GAIA_MANIFEST_WRITE=remove-i18n mv .gaia/manifest.json.tmp .gaia/manifest.json'
  assert_allowed
}

@test "marker among multiple leading env assignments is still exempt" {
  run_hook_bash 'FOO=1 GAIA_MANIFEST_WRITE=release cp x .gaia/manifest.json'
  assert_allowed
}

# --- allowed: Bash with no write vector (legitimate reads / release CLI) ---

@test "the release CLI mentioning manifest with no write vector is allowed" {
  run_hook_bash '.gaia/cli/gaia-maintainer release manifest'
  assert_allowed
}

@test "cat of the manifest is allowed" {
  run_hook_bash 'cat .gaia/manifest.json'
  assert_allowed
}

@test "jq read of the manifest is allowed" {
  run_hook_bash "jq '.files' .gaia/manifest.json"
  assert_allowed
}

@test "grep over the manifest is allowed" {
  run_hook_bash 'grep owned .gaia/manifest.json'
  assert_allowed
}

@test "git add of the manifest is allowed" {
  run_hook_bash 'git add .gaia/manifest.json'
  assert_allowed
}

@test "cp with the manifest as source (not destination) is allowed" {
  run_hook_bash 'cp .gaia/manifest.json /tmp/backup.json'
  assert_allowed
}

@test "redirect to a different manifest-adjacent path is allowed" {
  run_hook_bash 'echo x > .gaia/manifest.json.bak'
  assert_allowed
}

# --- structural ---

@test "block-manifest-write.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json is valid JSON" {
  run jq empty "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command == ".claude/hooks/block-manifest-write.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers the hook under the Bash matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == ".claude/hooks/block-manifest-write.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
