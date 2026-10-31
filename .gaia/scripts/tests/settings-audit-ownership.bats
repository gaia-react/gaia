#!/usr/bin/env bats
# A pull request that changes only .claude/settings.json is audited on an
# adopter roster: the shipped shell member owns the file, dispatches on an
# ordinary branch and on a GAIA update branch, is routed to a full review by the
# light router, and holds the merge gate until its clearance exists.
#
# The sandbox strips every maintainer-only block, as a release does. In this
# repository the maintainer-only shell member claims the file first, so an
# unstripped roster would never show the adopter behavior under test. The
# sandbox carries this checkout's real settings file and manifest; the manifest
# classes the settings file `shared`, which is what the release skip leaves alone.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

SHELL_MEMBER="code-audit-shell"
SETTINGS=".claude/settings.json"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# build_base: the scrubbed adopter sandbox with the settings file, the manifest
# and one adopter shell script on main, and the branch cut at main's tip.
build_base() {
  # shellcheck disable=SC2119
  lsb_init || return 1
  lsb_main_base_begin || return 1
  cp "$REPO_ROOT/.claude/settings.json" "$LSB_ROOT/.claude/settings.json" || return 1
  cp "$REPO_ROOT/.gaia/manifest.json" "$LSB_ROOT/.gaia/manifest.json" || return 1
  lsb_git add -- .claude/settings.json .gaia/manifest.json && lsb_git commit -q -m "settings and manifest" || return 1
  lsb_strip_maintainer_only || return 1
  if grep -qF 'code-audit-maintainer-shell' "$LSB_ROOT/.gaia/audit-ci.yml"; then
    printf 'the scrubbed roster still holds the maintainer shell member\n' >&2
    return 1
  fi
  grep -qF '".claude/settings.json"' "$LSB_ROOT/.gaia/audit-ci.yml" || {
    printf 'the scrubbed roster lost the settings glob\n' >&2
    return 1
  }
  lsb_commit scripts/deploy.sh "$(printf '#!/usr/bin/env bash\necho one\necho two\necho three')" || return 1
  lsb_main_base_end
}

# anchor_and_clear: a branch-own anchor commit at a path the shell member does
# not own, then a full clearance on it. A clearance on the merge base never
# anchors, so the router would answer no-full-clearance.
anchor_and_clear() {
  lsb_commit frontend/app/anchor.md "anchor" || return 1
  lsb_full_clearance "$SHELL_MEMBER"
}

# commit_settings_change <marker>: rewrite the settings file with jq, commit.
commit_settings_change() {
  jq --arg marker "$1" '.permissions.deny += ["Bash(settings-probe-" + $marker + ":*)"]' \
    "$LSB_ROOT/$SETTINGS" >"$LSB_ROOT/$SETTINGS.next" || return 1
  mv "$LSB_ROOT/$SETTINGS.next" "$LSB_ROOT/$SETTINGS" || return 1
  lsb_git add -- "$SETTINGS" && lsb_git commit -q -m "change settings" || return 1
  _lsb_set_head
}

raise_version() {
  printf '99.0.0\n' >"$LSB_ROOT/.gaia/VERSION" || return 1
  lsb_git add -- .gaia/VERSION && lsb_git commit -q -m "update gaia" || return 1
  _lsb_set_head
}

dispatched_members() {
  bash "$LSB_ROOT/.gaia/scripts/resolve-audit-members.sh" --root "$LSB_ROOT"
}

# owners <roster-file> <arm-base-or-empty>: "<path>\t<owner|->" for the paths on
# stdin, through the sandbox classifier with the release context armed against
# the base when one is given.
owners() {
  (
    # shellcheck source=/dev/null
    . "$LSB_ROOT/.claude/hooks/lib/audit-scope.sh"
    audit_scope_init "$LSB_ROOT" "$1" 2>/dev/null
    [ -z "$2" ] || audit_scope_release_context "$LSB_ROOT" "$2"
    audit_owners_for_paths
  )
}

owner_of() {
  awk -F'\t' -v wanted="$2" '$1 == wanted { print $2 }' <<<"$1"
}

expect_route() {
  [ "$status" -eq 0 ] || { printf 'status %s, output: %s\n' "$status" "$output" >&2; return 1; }
  [ "$output" = "$(printf '%s\t%s' "$1" "$2")" ] || { printf 'want %s/%s, got: %s\n' "$1" "$2" "$output" >&2; return 1; }
}

@test "a settings-only change on an ordinary branch dispatches the shell member" {
  build_base
  commit_settings_change one
  [ "$(lsb_git diff --name-only origin/main...HEAD)" = "$SETTINGS" ]
  run dispatched_members
  [ "$status" -eq 0 ]
  grep -qxF "$SHELL_MEMBER" <<<"$output"
}

@test "a settings-only change on a GAIA update branch dispatches the shell member" {
  build_base
  raise_version
  commit_settings_change one
  run dispatched_members
  [ "$status" -eq 0 ]
  grep -qxF "$SHELL_MEMBER" <<<"$output"
}

@test "guard can fail: the update branch dispatch rests on the shared class, not a disarmed context" {
  build_base
  raise_version
  commit_settings_change one
  local owned_hook base_commit armed
  owned_hook="$(jq -r '.files | to_entries[] | select(.value == "owned") | .key' "$LSB_ROOT/.gaia/manifest.json" \
    | grep -E '^\.claude/hooks/[^/]+\.sh$' | grep -vE 'audit|resolve|scope|roster|manifest|provision' | sort | head -n 1)"
  [ -n "$owned_hook" ]
  [ -f "$LSB_ROOT/$owned_hook" ]
  printf '# changed on branch\n' >>"$LSB_ROOT/$owned_hook"
  lsb_git add -- "$owned_hook" && lsb_git commit -q -m "edit an owned hook"
  base_commit="$(lsb_git rev-parse origin/main)"
  armed="$(printf '%s\n%s\n' "$owned_hook" "$SETTINGS" | owners "$LSB_ROOT/.gaia/audit-ci.yml" "$base_commit")"
  [ -n "$(owner_of "$armed" "$owned_hook")" ]
  [ "$(owner_of "$armed" "$owned_hook")" != "$SHELL_MEMBER" ]
  [ "$(owner_of "$armed" "$SETTINGS")" = "$SHELL_MEMBER" ]
  # Class the settings file `owned` on the head side: the skip now drops it.
  jq --arg path "$SETTINGS" '.files[$path] = "owned"' "$LSB_ROOT/.gaia/manifest.json" >"$LSB_ROOT/.gaia/manifest.next"
  mv "$LSB_ROOT/.gaia/manifest.next" "$LSB_ROOT/.gaia/manifest.json"
  lsb_git add -- .gaia/manifest.json && lsb_git commit -q -m "class settings owned"
  armed="$(printf '%s\n' "$SETTINGS" | owners "$LSB_ROOT/.gaia/audit-ci.yml" "$base_commit")"
  [ "$(owner_of "$armed" "$SETTINGS")" != "$SHELL_MEMBER" ]
}

@test "guard can fail: without the roster glob the shell member does not own the settings file" {
  build_base
  local scratch_roster="$BATS_TEST_TMPDIR/roster-without-glob.yml" owned
  grep -vxF '      - ".claude/settings.json"' "$LSB_ROOT/.gaia/audit-ci.yml" >"$scratch_roster"
  ! cmp -s "$LSB_ROOT/.gaia/audit-ci.yml" "$scratch_roster" || return 1
  owned="$(printf '%s\n' "$SETTINGS" | owners "$LSB_ROOT/.gaia/audit-ci.yml" "")"
  [ "$(owner_of "$owned" "$SETTINGS")" = "$SHELL_MEMBER" ]
  owned="$(printf '%s\n' "$SETTINGS" | owners "$scratch_roster" "")"
  [ "$(owner_of "$owned" "$SETTINGS")" != "$SHELL_MEMBER" ]
}

@test "the light router sends a settings delta to a full review after a full clearance" {
  build_base
  anchor_and_clear
  commit_settings_change one
  lsb_route "$SHELL_MEMBER"
  expect_route full hard-full
}

# The clearance records the framework version it was earned under, so the
# version is raised before it is written; raised after, the router answers
# no-full-clearance for the stale version instead.
@test "the light router sends a settings delta on an update branch to a full review" {
  build_base
  raise_version
  anchor_and_clear
  commit_settings_change one
  lsb_route "$SHELL_MEMBER"
  expect_route full hard-full
}

@test "guard can fail: the router routes a small adopter script change light" {
  build_base
  anchor_and_clear
  lsb_commit scripts/deploy.sh "$(printf '#!/usr/bin/env bash\necho one\necho two\necho changed')"
  lsb_route "$SHELL_MEMBER"
  expect_route light light-eligible
}

@test "the merge gate holds a settings-only change until the shell member clears it" {
  build_base
  commit_settings_change one
  lsb_run_merge_hook 41
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output"
  grep -qF "$SHELL_MEMBER" <<<"$output"
  lsb_full_clearance "$SHELL_MEMBER"
  lsb_run_merge_hook 41
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}
