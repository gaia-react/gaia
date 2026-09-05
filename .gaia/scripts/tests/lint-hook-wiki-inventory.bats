#!/usr/bin/env bats
# SC2016 is intentional file-wide: the fixture writers below are single-quoted
# precisely so that the command-substitution form in the fixture registration
# and the backticks in the fixture markdown reach the file as literal text,
# which is what makes them fixtures of the real spellings rather than of what
# this shell would expand them to.
# shellcheck disable=SC2016
#
# Conformance suite for .gaia/scripts/lint-hook-wiki-inventory.sh -- the gate
# that keeps wiki/concepts/Claude Hooks.md's bundled-hooks inventory from going
# stale as hooks are registered (gaia-react/gaia#1786).
#
# This suite IS the blocking runner. shell-lint.sh invokes the check a second,
# advisory way, but a gate run against a tree whose inventory is already
# complete reports clean whether its predicate works or not, so a broken
# predicate is indistinguishable from a healthy page there. Every behavioral
# test therefore drives the check through its <repo_root> parameter against a
# fixture tree broken one way at a time, the same reasoning
# lint-guard-rule-shell-coverage.bats gives for itself. The real-tree test at
# the end is what fails a build when an actual registered hook lands off the
# page.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-hook-wiki-inventory.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/lint-hook-wiki-inventory.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  INVENTORY_REL="wiki/concepts/Claude Hooks.md"
  SETTINGS_REL=".claude/settings.json"
}

# make_fixture <name>: a fresh fixture root under BATS_TEST_TMPDIR.
#
# No git repo: the check reads its two subjects directly and touches git only
# when it has to resolve a root for itself, which the <repo_root> argument
# every test below passes bypasses entirely.
#
# There is no teardown, deliberately: every fixture lives under
# BATS_TEST_TMPDIR, which bats removes per test.
make_fixture() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.claude" "$dir/wiki/concepts"
  printf '%s' "$dir"
}

# write_settings <dir> <hook-basename>...
#
# Register each named hook under a PreToolUse entry, in the command spelling
# .claude/settings.json actually uses: a quoted absolute path built from a root
# expansion, which is why the check recovers the basename from the path text.
write_settings() {
  local dir="$1"
  shift
  local hook first=1
  {
    printf '{\n  "hooks": {\n    "PreToolUse": [\n'
    for hook in "$@"; do
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
      printf '          {\n            "type": "command",\n'
      printf '            "command": "\\"$(git rev-parse --show-toplevel)/.claude/hooks/%s\\""\n' "$hook"
      printf '          }\n        ]\n      }'
    done
    printf '\n    ]\n  }\n}\n'
  } >"$dir/$SETTINGS_REL"
}

# write_inventory <dir> <mention>...
#
# A minimal page carrying one bullet per mention, in the shape the real entries
# use.
write_inventory() {
  local dir="$1"
  shift
  local mention
  {
    printf '# Claude Hooks\n\n## Bundled hooks\n\n'
    for mention in "$@"; do
      printf -- '- **`%s`**: a fixture entry.\n' "$mention"
    done
  } >"$dir/$INVENTORY_REL"
}

@test "structural: the check is executable" {
  [ -x "$CHECK" ]
}

@test "a fixture whose page mentions every registered hook passes" {
  local dir
  dir="$(make_fixture healthy)"
  write_settings "$dir" alpha.sh beta.sh
  write_inventory "$dir" alpha.sh beta.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}

@test "a registered hook the page never mentions fails, naming that hook and not its inventoried sibling" {
  local dir
  dir="$(make_fixture omitted)"
  write_settings "$dir" alpha.sh beta.sh
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'beta.sh' <<<"$output"
  # alpha.sh is inventoried, so it must not be blamed. The findings block is the
  # only place a hook basename is printed, so alpha.sh appearing at all is the
  # bad case.
  grep -qF -- 'alpha.sh' <<<"$output" && return 1
  grep -qF -- "$INVENTORY_REL" <<<"$output"
}

@test "every omitted hook is reported, not just the first" {
  local dir
  dir="$(make_fixture omitted_many)"
  write_settings "$dir" alpha.sh beta.sh gamma.sh
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'beta.sh' <<<"$output"
  grep -qF -- 'gamma.sh' <<<"$output"
}

@test "a hook mentioned under a path prefix counts as inventoried" {
  local dir
  dir="$(make_fixture prefixed_mention)"
  write_settings "$dir" alpha.sh
  {
    printf '# Claude Hooks\n\n## Bundled hooks\n\n'
    printf -- '- **`.claude/hooks/alpha.sh`**: named with its directory.\n'
  } >"$dir/$INVENTORY_REL"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a hook registered below a subdirectory of .claude/hooks/ still enters the set, and reds when the page omits it" {
  local dir
  dir="$(make_fixture nested_hook)"
  write_settings "$dir" alpha.sh nested/beta.sh
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'nested/beta.sh' <<<"$output"
}

@test "a hook registered below a subdirectory counts as inventoried when the page names it" {
  local dir
  dir="$(make_fixture nested_hook_ok)"
  write_settings "$dir" alpha.sh nested/beta.sh
  write_inventory "$dir" alpha.sh nested/beta.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a registration whose command the name regex cannot read exits 2 rather than comparing a short set" {
  local dir
  dir="$(make_fixture unreadable_spelling)"
  # Two distinct commands naming the directory; the second carries a character
  # the name class does not model, so it yields no name at all. That is the
  # silent partial drop the size check exists to refuse: the set is short
  # rather than empty, so the non-empty arm alone stays satisfied.
  {
    printf '{\n  "hooks": {\n    "PreToolUse": [\n'
    printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
    printf '          {\n            "type": "command",\n'
    printf '            "command": "\\"$(git rev-parse --show-toplevel)/.claude/hooks/alpha.sh\\""\n'
    printf '          }\n        ]\n      },\n'
    printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
    printf '          {\n            "type": "command",\n'
    printf '            "command": "bash .claude/hooks/weird name.sh"\n'
    printf '          }\n        ]\n      }\n'
    printf '    ]\n  }\n}\n'
  } >"$dir/$SETTINGS_REL"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'could be read out of them' <<<"$output"
}

@test "one hook registered on several events is not mistaken for an unreadable spelling" {
  local dir
  dir="$(make_fixture repeated_registration)"
  # The same hook on two events is two commands and one name. The size check
  # compares against DISTINCT commands for exactly this reason, so this must
  # pass rather than red as a short set.
  {
    printf '{\n  "hooks": {\n    "PreToolUse": [\n'
    printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
    printf '          {\n            "type": "command",\n'
    printf '            "command": "\\"$(git rev-parse --show-toplevel)/.claude/hooks/alpha.sh\\""\n'
    printf '          }\n        ]\n      }\n'
    printf '    ],\n    "PostToolUse": [\n'
    printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
    printf '          {\n            "type": "command",\n'
    printf '            "command": "\\"$(git rev-parse --show-toplevel)/.claude/hooks/alpha.sh\\""\n'
    printf '          }\n        ]\n      }\n'
    printf '    ]\n  }\n}\n'
  } >"$dir/$SETTINGS_REL"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "settings registering no hook under .claude/hooks/ exits 2 rather than reporting the page complete" {
  local dir
  dir="$(make_fixture no_hooks)"
  printf '{\n  "hooks": {}\n}\n' >"$dir/$SETTINGS_REL"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'discovery found no hook' <<<"$output"
  # The message must admit both conditions that reach this branch, per
  # .claude/rules/partial-cause-reporting.md.
  grep -qF -- 'registration spelling changed' <<<"$output"
}

@test "a registration naming a directory other than .claude/hooks/ is not counted, and exits 2 when it is the only one" {
  local dir
  dir="$(make_fixture foreign_dir)"
  {
    printf '{\n  "hooks": {\n    "PreToolUse": [\n'
    printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
    printf '          {\n            "type": "command",\n'
    printf '            "command": "bash .gaia/scripts/some-helper.sh"\n'
    printf '          }\n        ]\n      }\n'
    printf '    ]\n  }\n}\n'
  } >"$dir/$SETTINGS_REL"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'discovery found no hook' <<<"$output"
}

@test "an unparseable settings file exits 2, distinguishably from registering nothing" {
  local dir
  dir="$(make_fixture bad_json)"
  printf '{ "hooks": { "PreToolUse": [ \n' >"$dir/$SETTINGS_REL"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'not valid JSON' <<<"$output"
  grep -qF -- 'discovery found no hook' <<<"$output" && return 1
  true
}

@test "a missing settings file exits 2" {
  local dir
  dir="$(make_fixture no_settings)"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'settings file not found' <<<"$output"
}

@test "a missing inventory page exits 2 rather than blaming every registered hook" {
  local dir
  dir="$(make_fixture no_page)"
  write_settings "$dir" alpha.sh beta.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'inventory page not found' <<<"$output"
}

@test "an empty inventory page exits 2, distinguishably from a missing one" {
  local dir
  dir="$(make_fixture empty_page)"
  write_settings "$dir" alpha.sh
  : >"$dir/$INVENTORY_REL"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'inventory page is empty' <<<"$output"
  grep -qF -- 'inventory page not found' <<<"$output" && return 1
  true
}

@test "a <repo_root> that is not a directory exits 2" {
  run bash "$CHECK" "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  grep -qF -- 'not a directory' <<<"$output"
}

@test "more than one argument is a usage error" {
  run bash "$CHECK" "$REPO_ROOT" extra
  [ "$status" -eq 2 ]
  grep -qF -- 'too many arguments' <<<"$output"
}

@test "the real tree passes: every hook registered in settings.json is on the page" {
  run bash "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
