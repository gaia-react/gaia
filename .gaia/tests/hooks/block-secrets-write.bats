#!/usr/bin/env bats

# Tests for .claude/hooks/block-secrets-write.sh.
#
# The guard is a write-time heuristic, not a sandbox: it scans the content an
# Edit/Write/MultiEdit is about to introduce and denies four shapes of obvious
# committed secret (AWS access-key id, GitHub PAT, PEM private-key header, and a
# dotenv-style assignment to a suspicious name). It always exits 0, carrying the
# allow/deny decision in stdout JSON.
#
# The dotenv rule is the only one with an allowlist, because it is the only one
# that matches on a *name* rather than on secret-shaped material: a line whose
# name ends in _TOKEN/_SECRET/_KEY/_PASSWORD is suspicious, so the value decides.
# The allowlist therefore carries the whole weight of the rule's false-positive
# behavior, and the deny cases below are what pin down that widening it does not
# hollow it out.
#
# Writing this file is itself subject to the guard, so every secret-shaped
# fixture is concatenated at runtime from fragments that match no pattern as
# written. Do not "tidy" those into single literals; the guard will deny the
# edit that does it.

# shellcheck disable=SC2317
# SC2317 (command appears unreachable) is a structural false positive on every
# @test block below: bats invokes each test body through its own runner, which
# static shellcheck cannot see, so it marks the blocks unreachable. The directive
# is file-wide because the false positive is intrinsic to the bats structure, not
# to any single test, and it masks no genuine signal: SC2317 cannot reason about
# an indirectly-invoked bats suite at all.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-secrets-write.sh"
}

# Quote-safe delivery: the payloads below carry shell snippets with quotes of
# their own, so $json and the hook path go in as positional args rather than
# being re-wrapped in an outer quoted string.
run_hook_write() {
  local body="$1"
  local json
  json=$(jq -n --arg c "$body" '{tool_name: "Write", tool_input: {content: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_edit() {
  local body="$1"
  local json
  json=$(jq -n --arg s "$body" '{tool_name: "Edit", tool_input: {new_string: $s}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  ! grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# --- The three secret-shaped patterns still deny ---

@test "an AWS access-key id is denied" {
  local aws_id="AKIA""IOSFODNN7EXAMPLE"
  run_hook_write "const id = '$aws_id'"
  assert_denied
}

@test "a GitHub personal-access-token is denied" {
  local pat="ghp""_0123456789abcdefghij"
  run_hook_write "const token = '$pat'"
  assert_denied
}

@test "a PEM private-key header is denied" {
  local pem="-----BEGIN RSA PRIVATE ""KEY-----"
  run_hook_write "$pem"
  assert_denied
}

# --- The dotenv rule still denies a real literal value ---

@test "a dotenv assignment with a literal value is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a dotenv assignment with a literal value is denied through Edit too" {
  run_hook_edit "$(printf 'DB_PASSWORD=%s\n' 'hunter2-not-a-placeholder')"
  assert_denied
}

@test "a literal value is denied even when a command substitution precedes it" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(whoami)-sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

# The four below pin the allowlist's command-substitution arm to "wholly a
# substitution" rather than "starts with $( and ends with )". The first three
# are values a both-ends-anchored `\$\(.+\)` admits, because `.` matches the
# very `)` the closing anchor is supposed to certify; they pin the trailing
# anchor. The fourth pins the leading one, and only that one: it never starts
# with `$(`, so it is the shape a dropped `^` would silently let through.

@test "a literal value between two command substitutions is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(true)sk-live-9f3a1c4e8b7d2064$(true)')"
  assert_denied
}

@test "a literal value is denied when it merely ends in a closing paren" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(whoami)sk-live-9f3a1c4e8b7d2064)')"
  assert_denied
}

@test "a literal value spliced between quoted command substitutions is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '"$(a)"sk-live-9f3a1c4e8b7d2064"$(b)"')"
  assert_denied
}

@test "a literal value is denied even when a command substitution follows it" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064$(whoami)')"
  assert_denied
}

# --- The other allowlist arms mean "wholly" too ---
#
# The command-substitution arm is not the only one that has to resist a splice.
# `<…>` had the identical defect (`.` matches `>`), and the `your-` / `example`
# arms matched a prefix with nothing anchoring the tail, so any value merely
# *starting* like a placeholder was allowed whatever followed it.

@test "a literal value between two angle-bracket placeholders is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '<a>sk-live-9f3a1c4e8b7d2064<b>')"
  assert_denied
}

@test "a literal value carrying an example- placeholder prefix is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'example-sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a literal value carrying a your- placeholder prefix is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'your-key-sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

# --- A shell declaration keyword does not hide the assignment ---
#
# The name grep anchors the suspicious name to the start of the line, so a
# declaration keyword in front of it took the line out of the scan entirely,
# and no allowlist arm was ever consulted.

@test "an exported literal value is denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a local-declared literal value is denied" {
  run_hook_write "$(printf 'local API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a readonly-declared literal value is denied through Edit too" {
  run_hook_edit "$(printf 'readonly DB_PASSWORD=%s\n' 'hunter2-not-a-placeholder')"
  assert_denied
}

# --- The existing allowlist arms still allow ---

@test "an empty value is allowed" {
  run_hook_write "$(printf 'API_KEY=\n')"
  assert_allowed
}

@test "a bare \$VAR value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$MY_API_KEY')"
  assert_allowed
}

@test "a braced \${VAR} value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${MY_API_KEY}')"
  assert_allowed
}

@test "a named placeholder value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'placeholder')"
  assert_allowed
}

@test "content with no secret shape at all is allowed" {
  run_hook_write "export function add(a, b) { return a + b }"
  assert_allowed
}

# The tightened arms have to stay usable: these are the placeholder values the
# arms exist to admit, and the ones a too-eager anchor would take down with the
# splices above.

@test "an angle-bracket placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '<your-key-here>')"
  assert_allowed
}

@test "a your- placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'your-api-key-here')"
  assert_allowed
}

@test "a bare example placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'example')"
  assert_allowed
}

@test "an example domain placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'example.com')"
  assert_allowed
}

@test "an exported \$VAR value is allowed" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$MY_API_KEY')"
  assert_allowed
}

# Recognizing the declaration keywords pulls shell lines into a rule written for
# dotenv files, and a shell value references a variable far more often than a
# dotenv value does. These are the shapes that carry no literal secret but that
# the bare-identifier `${VAR}` arm alone would deny.

@test "an expansion carrying a default operator is allowed" {
  run_hook_write "$(printf 'export GITHUB_TOKEN=%s\n' '"${GITHUB_TOKEN:-}"')"
  assert_allowed
}

@test "a positional expansion is allowed" {
  run_hook_write "$(printf 'local CACHE_KEY=%s\n' '"${1}"')"
  assert_allowed
}

@test "an expansion followed by a literal path is allowed" {
  run_hook_write "$(printf 'readonly SIGNING_KEY=%s\n' '"${REPO_ROOT}/dev.pem"')"
  assert_allowed
}

@test "a named fake placeholder is allowed" {
  run_hook_write "$(printf 'export GH_TOKEN=%s\n' '"fake-token"')"
  assert_allowed
}

# The expansion allowance is bounded by the same segment rule as the placeholder
# arms: a secret does not stop being a secret for sitting inside a default.

@test "a literal secret inside an expansion default is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${API_KEY:-sk-live-9f3a1c4e8b7d2064}')"
  assert_denied
}

@test "a literal secret concatenated onto an expansion is denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '"${PREFIX}sk-live-9f3a1c4e8b7d2064"')"
  assert_denied
}

# A segmented secret has the same structure a placeholder does, so the operand
# arm requires an EMPTY operand rather than a short one: a default value is
# exactly where a real secret lands, and a UUID clears any per-segment bound.

@test "a segmented secret inside an expansion default is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${API_KEY:-550e8400-e29b-41d4-a716-446655440000}')"
  assert_denied
}

@test "an expansion followed by a non-path literal is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${X}550e8400-e29b-41d4-a716-446655440000')"
  assert_denied
}

# A variable reference inside a command-substitution body must not buy the
# value an expansion arm: that would re-open the very splice the `$(…)` arm
# exists to close.

@test "a substitution whose body references a variable is still spliced, so denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(echo ${X})550e8400-e29b-41d4-a716-446655440000')"
  assert_denied
}

# The placeholder arms require a separator BETWEEN segments. Making it optional
# would let one unbroken run be read as several short ones, which is the bound
# defeating itself.

@test "an unbroken run behind a placeholder prefix cannot be read as segments" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'example550e8400e29b41d4a716446655440000')"
  assert_denied
}

# Segmented placeholders pass at any length; an unbroken run does not. A length
# cap gets both of these backwards, which is why the arms bound the segment.

@test "a long but segmented your- placeholder is allowed" {
  run_hook_write "$(printf 'GITHUB_TOKEN=%s\n' 'your-github-personal-access-token')"
  assert_allowed
}

@test "an underscore-segmented your_ placeholder is allowed" {
  run_hook_write "$(printf 'SUPABASE_ANON_KEY=%s\n' 'your_supabase_anon_key_here')"
  assert_allowed
}

@test "a short unbroken run behind a placeholder prefix is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'your-aB3xK9pQ7zR2wL5t')"
  assert_denied
}

# --- A computed value is allowed: the source line holds no literal secret ---
#
# A value that is wholly a command substitution is resolved at run time, so the
# source line carries nothing to leak. Denying it taught callers to launder the
# assignment through a throwaway variable or an off-target name, which is
# unexplained residue in exchange for no security.
#
# The arm reads shape, not meaning, and the deny cases above are the price of
# keeping that shape honest. A nested `$(op read op://vault/$(hostname))` is
# denied, and `$(echo <a-literal-secret>)` is allowed: no regex tells those
# apart from `$(mint_key)` without reading the command. Neither is pinned here,
# because neither is behavior worth freezing.

@test "a value that is wholly a command substitution is allowed" {
  run_hook_write "$(printf 'AUDIT_KEY="%s"\n' '$(gaia_audit_key "$BASE_SHA")')"
  assert_allowed
}

@test "an unquoted command substitution value is allowed" {
  run_hook_write "$(printf 'SESSION_TOKEN=%s\n' '$(mint_token)')"
  assert_allowed
}

@test "a command substitution is allowed through Edit too" {
  run_hook_edit "$(printf 'AUDIT_KEY="%s"\n' '$(gaia_audit_key "$BASE_SHA")')"
  assert_allowed
}
