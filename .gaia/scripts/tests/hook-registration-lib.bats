#!/usr/bin/env bats
# SC2016 is intentional file-wide: the fixture writer below is single-quoted
# precisely so the command-substitution form in a registration reaches the file
# as literal text, which is what makes it a fixture of the real spelling rather
# than of what this shell would expand it to.
# shellcheck disable=SC2016
#
# Conformance suite for `GAIA_HOOK_NAME_RE` in
# .gaia/scripts/hook-registration-lib.sh -- the one spelling of a hook name
# inside a registration command -- driven through both of its consumers:
# `gaia_pretooluse_hooks` in the same file, which reads it with `grep -oE`, and
# `hook_registered` in .gaia/tests/helpers/hook-registration.sh, which reads it
# with jq's `match` builtin.
#
# WHY BOTH CONSUMERS ARE DRIVEN. They read one literal through two different
# regex engines and each drops the trailing terminator its own way, so a change
# that repairs one and not the other is green in whichever half the author
# happened to run. The gates that source the library
# (lint-hook-jq-availability.sh, lint-hook-monitor-arming.sh) reach the
# literal only through `gaia_pretooluse_hooks`, so the live-tree test at the
# bottom re-verifies them rather than driving each one separately here.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/hook-registration-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  # shellcheck source=../hook-registration-lib.sh
  . "$REPO_ROOT/.gaia/scripts/hook-registration-lib.sh"
  # The helper sources the library too; the library's own source guard makes
  # that second source a no-op, so `GAIA_HOOK_NAME_RE` is read once here.
  # shellcheck source=../../tests/helpers/hook-registration.sh
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
}

# write_settings <dir> <command-path>
#
# Register one PreToolUse entry whose command points at <command-path> under
# `.claude/hooks/`, in the rooted, quoted spelling .claude/settings.json
# actually uses. <command-path> is the text after `.claude/hooks/`, so a caller
# passes a bare hook name for the sanctioned form and a suffixed one for the
# shapes this suite exists to reject. There is no teardown, deliberately: every
# fixture lives under BATS_TEST_TMPDIR, which bats removes per test.
write_settings() {
  local dir="$1" command_path="$2"
  mkdir -p "$dir/.claude"
  {
    printf '{\n  "hooks": {\n    "PreToolUse": [\n'
    printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
    printf '          {\n            "type": "command",\n'
    printf '            "command": "\\"$(git rev-parse --show-toplevel)/.claude/hooks/%s\\""\n' "$command_path"
    printf '          }\n        ]\n      }\n'
    printf '    ]\n  }\n}\n'
  } >"$dir/.claude/settings.json"
}

@test "gaia_pretooluse_hooks resolves a hook the sanctioned registration names" {
  write_settings "$BATS_TEST_TMPDIR/sanctioned" 'capture-gh-artifact.sh'
  run gaia_pretooluse_hooks "$BATS_TEST_TMPDIR/sanctioned"
  [ "$status" -eq 0 ]
  [ "$output" = 'capture-gh-artifact.sh' ]
}

@test "gaia_pretooluse_hooks resolves nothing from a registration pointing at a suffixed copy" {
  write_settings "$BATS_TEST_TMPDIR/suffixed" 'capture-gh-artifact.sh.bak'
  run gaia_pretooluse_hooks "$BATS_TEST_TMPDIR/suffixed"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gaia_pretooluse_hooks resolves a sibling-named hook as itself" {
  write_settings "$BATS_TEST_TMPDIR/sibling" 'capture-gh-artifact.shim.sh'
  run gaia_pretooluse_hooks "$BATS_TEST_TMPDIR/sibling"
  [ "$status" -eq 0 ]
  [ "$output" = 'capture-gh-artifact.shim.sh' ]
}

@test "hook_registered accepts the sanctioned registration" {
  write_settings "$BATS_TEST_TMPDIR/sanctioned" 'capture-gh-artifact.sh'
  run hook_registered "$BATS_TEST_TMPDIR/sanctioned/.claude/settings.json" \
    '.hooks.PreToolUse[] | select(.matcher == "Bash")' 'capture-gh-artifact.sh'
  [ "$status" -eq 0 ]
}

@test "hook_registered rejects a registration pointing at a suffixed copy" {
  write_settings "$BATS_TEST_TMPDIR/suffixed" 'capture-gh-artifact.sh.bak'
  run hook_registered "$BATS_TEST_TMPDIR/suffixed/.claude/settings.json" \
    '.hooks.PreToolUse[] | select(.matcher == "Bash")' 'capture-gh-artifact.sh'
  [ "$status" -ne 0 ]
}

@test "hook_registered rejects a sibling-named registration" {
  write_settings "$BATS_TEST_TMPDIR/sibling" 'capture-gh-artifact.shim.sh'
  run hook_registered "$BATS_TEST_TMPDIR/sibling/.claude/settings.json" \
    '.hooks.PreToolUse[] | select(.matcher == "Bash")' 'capture-gh-artifact.sh'
  [ "$status" -ne 0 ]
}

# The coverage half. Narrowing the literal fails in the direction of resolving
# FEWER hooks, and the two gates that source the library judge every hook they
# reach through `gaia_pretooluse_hooks`, so a hook the literal stops resolving
# is a hook they stop judging. The expected set is derived from
# .claude/settings.json by a rule that does not share the literal -- the text
# after the last `/.claude/hooks/` in each PreToolUse command, up to the quote
# that closes it -- so the two agree only while the literal terminates at the
# path token. An empty derivation is a failure here rather than a vacuous pass.
@test "gaia_pretooluse_hooks resolves every hook this repo's own settings register" {
  local settings="$REPO_ROOT/.claude/settings.json"
  local expected
  expected="$(jq -r '.hooks.PreToolUse // [] | .[] | .hooks[]? | .command // empty' "$settings" |
    grep -F '.claude/hooks/' |
    sed -e 's#^.*/\.claude/hooks/##' -e 's#".*$##' |
    sort -u)"
  [ -n "$expected" ]
  run gaia_pretooluse_hooks "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}
