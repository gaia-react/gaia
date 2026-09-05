#!/usr/bin/env bats
# SC2016 is intentional file-wide: the fixture writers below are single-quoted
# precisely so that the command-substitution form in the fixture registration
# and the backticks in the fixture markdown reach the file as literal text,
# which is what makes them fixtures of the real spellings rather than of what
# this shell would expand them to.
# shellcheck disable=SC2016
#
# Conformance suite for .gaia/scripts/lint-hook-advisory-classification.sh --
# the gate that reds when a hook which stops a tool call is filed under an
# Advisory heading on a wiki page.
#
# This suite IS the blocking runner. shell-lint.sh invokes the check a second,
# advisory way, but a gate run against a tree whose classifications are already
# correct reports clean whether its predicate works or not, so a broken
# predicate is indistinguishable from an honest page there. That is not a
# hypothetical here: the check's first draft classified with a
# `grep -v | grep -q` pipeline and reported CLEAN over the live defect it was
# written for, because `grep -q` closes the pipe, the upstream grep takes
# SIGPIPE, and `pipefail` promoted 141 to the pipeline's status. Every test
# therefore drives the check through its <repo_root> parameter against a
# fixture tree shaped one way at a time, and the oracle gets its own tests
# rather than being trusted.
#
# NO REAL-TREE TEST, deliberately, on the same reasoning the sibling
# lint-wiki-cached-version.bats gives: shell-lint.sh's `**/*.md`, `**/*.sh` and
# `.claude/settings.json` paths-filter entries already arm this check on every
# pull request that could introduce the defect.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-hook-advisory-classification.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/lint-hook-advisory-classification.sh"
  PAGE_REL="wiki/concepts/Fixture Hooks.md"
}

# make_fixture <name>: a fresh fixture root under BATS_TEST_TMPDIR.
#
# A real git repository, because the page sweep discovers over `git ls-files`.
#
# There is no teardown, deliberately: every fixture lives under
# BATS_TEST_TMPDIR, which bats removes per test.
make_fixture() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/.claude/hooks" "$dir/wiki/concepts"
  git -C "$dir" init -q
  git -C "$dir" config user.email fixture@example.invalid
  git -C "$dir" config user.name fixture
  printf '%s' "$dir"
}

track_fixture() {
  git -C "$1" add -A
}

# write_settings <dir> <hook-basename>...
#
# Register each named hook under a PreToolUse entry, in the command spelling
# .claude/settings.json actually uses.
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
  } >"$dir/.claude/settings.json"
}

# write_post_settings <dir> <hook-basename>
#
# The same registration on PostToolUse, the event that cannot stop anything.
write_post_settings() {
  local dir="$1" hook="$2"
  {
    printf '{\n  "hooks": {\n'
    printf '    "PreToolUse": [\n'
    printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
    printf '          {\n            "type": "command",\n'
    printf '            "command": "\\"$(git rev-parse --show-toplevel)/.claude/hooks/denier.sh\\""\n'
    printf '          }\n        ]\n      }\n    ],\n'
    printf '    "PostToolUse": [\n'
    printf '      {\n        "matcher": "Bash",\n        "hooks": [\n'
    printf '          {\n            "type": "command",\n'
    printf '            "command": "\\"$(git rev-parse --show-toplevel)/.claude/hooks/%s\\""\n' "$hook"
    printf '          }\n        ]\n      }\n    ]\n  }\n}\n'
  } >"$dir/.claude/settings.json"
}

# write_hook <dir> <basename> <kind>
#
# kind=deny      emits a permissionDecision
# kind=exit2     stops by exiting 2
# kind=advisory  prints and exits 0
# kind=comment   exits 0, but its header COMMENT contains the words `exit 2`
write_hook() {
  local dir="$1" name="$2" kind="$3"
  {
    printf '#!/usr/bin/env bash\n'
    case "$kind" in
      deny)
        printf 'jq -n --arg r "no" %s\n' "'{hookSpecificOutput:{permissionDecision:\"deny\",permissionDecisionReason:\$r}}'"
        ;;
      exit2)
        printf 'echo "stopped" >&2\nexit 2\n'
        ;;
      comment)
        printf '# A sourced library that fails to parse abandons the shell at exit 2,\n'
        printf '# which this hook does not itself do.\n'
        printf 'exit 0\n'
        ;;
      *)
        printf 'echo "a nudge"\nexit 0\n'
        ;;
    esac
  } >"$dir/.claude/hooks/$name"
  chmod +x "$dir/.claude/hooks/$name"
}

# write_page <dir> <advisory-entry>...
#
# A page with a blocking section and an advisory section, the entries in the
# shape the real pages use.
write_page() {
  local dir="$1"
  shift
  local entry
  {
    printf '# Fixture Hooks\n\n## Bundled hooks\n\n'
    printf '### Blocking (Bash)\n\n- **`denier.sh`**: denies things.\n\n'
    printf '### Advisory (Bash)\n\n'
    for entry in "$@"; do
      printf -- '- **`%s`**: a fixture entry.\n' "$entry"
    done
  } >"$dir/$PAGE_REL"
}

@test "structural: the check is executable" {
  [ -x "$CHECK" ]
}

@test "an advisory section naming only advisory hooks passes" {
  local dir
  dir="$(make_fixture healthy)"
  write_settings "$dir" denier.sh nudger.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" nudger.sh advisory
  write_page "$dir" nudger.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}

@test "a permissionDecision-emitting hook filed as advisory fails, naming page, line and hook" {
  local dir
  dir="$(make_fixture misfiled_deny)"
  write_settings "$dir" denier.sh misfiled.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" misfiled.sh deny
  write_page "$dir" misfiled.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'misfiled.sh' <<<"$output"
  grep -qF -- "$PAGE_REL" <<<"$output"
}

@test "a hook that stops by exiting 2 is blocking too, and reds when filed as advisory" {
  local dir
  dir="$(make_fixture misfiled_exit2)"
  write_settings "$dir" denier.sh stopper.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" stopper.sh exit2
  write_page "$dir" stopper.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'stopper.sh' <<<"$output"
}

@test "a hook whose header COMMENT says exit 2 is not classified as blocking" {
  local dir
  dir="$(make_fixture comment_only)"
  write_settings "$dir" denier.sh talker.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" talker.sh comment
  write_page "$dir" talker.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a blocking hook MENTIONED after the colon is not graded, only the entry position is" {
  local dir
  dir="$(make_fixture mention_only)"
  write_settings "$dir" denier.sh nudger.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" nudger.sh advisory
  {
    printf '# Fixture Hooks\n\n### Advisory (Bash)\n\n'
    printf -- '- **`nudger.sh`**: unlike denier.sh, this one only nudges.\n'
  } >"$dir/$PAGE_REL"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "an entry that names no hook in its leading code span grades nothing, whatever its prose names" {
  local dir
  dir="$(make_fixture prose_led_entry)"
  write_settings "$dir" denier.sh nudger.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" nudger.sh advisory
  # The discriminating fixture for the entry-span narrowing, and the one the
  # test above cannot be: there, the entry name is the FIRST `.sh` on the line,
  # so scanning the whole line and scanning the entry span find the same name
  # and agree. Here the only `.sh` on the line sits in the prose, so the two
  # answers differ and the narrowing is what decides. Without it this line
  # grades a blocking hook the entry never classified.
  {
    printf '# Fixture Hooks\n\n### Advisory (Bash)\n\n'
    printf -- '- The nudge layer: see denier.sh for the shape a refusal takes instead.\n'
  } >"$dir/$PAGE_REL"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a prose bullet carrying no colon at all grades nothing, the case a colon-keyed narrowing misses" {
  local dir
  dir="$(make_fixture prose_no_colon)"
  write_settings "$dir" denier.sh nudger.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" nudger.sh advisory
  # A colon-keyed narrowing falls back to the whole line when the item carries
  # no colon, so this ordinary cross-reference reds the check and the author is
  # told to move an entry that is not one. It is the sentence the guard's own
  # header names as prose that must not be graded, so the header is a claim
  # about this repository and this is the test that answers it.
  {
    printf '# Fixture Hooks\n\n### Advisory (Bash)\n\n'
    printf -- '- Unlike denier.sh, this one only nudges and never stops the call\n'
  } >"$dir/$PAGE_REL"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a prose bullet naming a hook ahead of a later colon grades nothing" {
  local dir
  dir="$(make_fixture prose_late_colon)"
  write_settings "$dir" denier.sh nudger.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" nudger.sh advisory
  # The other half of the colon-keyed fallback: the colon exists but falls after
  # the name, so the text before it still holds the mention.
  {
    printf '# Fixture Hooks\n\n### Advisory (Bash)\n\n'
    printf -- '- When denier.sh denies a call this one does nothing: it only records.\n'
  } >"$dir/$PAGE_REL"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a bullet whose prose names a hook ahead of its own code span grades nothing" {
  local dir
  dir="$(make_fixture prose_before_span)"
  write_settings "$dir" denier.sh nudger.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" nudger.sh advisory
  # The input that separates the span-START test from the closing-backtick test
  # alone. Every other prose fixture here has no hook name before its first
  # backtick, so dropping the start test still finds nothing and the suite
  # agrees under either rule. Here the prose ahead of the span names a blocking
  # hook, so only the start test keeps this line ungraded.
  {
    printf '# Fixture Hooks\n\n### Advisory (Bash)\n\n'
    printf -- '- unlike denier.sh, see `nudger.sh` below for the nudging one\n'
  } >"$dir/$PAGE_REL"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "an entry whose code span is unwrapped by bold is still graded" {
  local dir
  dir="$(make_fixture plain_span_entry)"
  write_settings "$dir" denier.sh misfiled.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" misfiled.sh deny
  # The bold wrapper is optional on these pages, so dropping it must not drop
  # the grading with it: narrowing that only reads the bolded shape would be a
  # silent fail-open on every plainly-spanned entry.
  {
    printf '# Fixture Hooks\n\n### Advisory (Bash)\n\n'
    printf -- '- `misfiled.sh`: a fixture entry with no bold wrapper.\n'
  } >"$dir/$PAGE_REL"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'misfiled.sh' <<<"$output"
}

@test "an entry carrying a parenthetical after its code span is still graded" {
  local dir
  dir="$(make_fixture annotated_entry)"
  write_settings "$dir" denier.sh misfiled.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" misfiled.sh deny
  # The shape the real pages use for a hook whose event matters, and the one a
  # narrowing keyed to the first colon would also read correctly; it is here so
  # the span narrowing is held to the same live shapes.
  {
    printf '# Fixture Hooks\n\n### Advisory (Bash)\n\n'
    printf -- '- **`misfiled.sh`** (PreToolUse, Bash): a fixture entry.\n'
  } >"$dir/$PAGE_REL"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'misfiled.sh' <<<"$output"
}

@test "a hook registered only on PostToolUse cannot stop a call and is never blocking" {
  local dir
  dir="$(make_fixture post_only)"
  write_post_settings "$dir" recorder.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" recorder.sh exit2
  write_page "$dir" recorder.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the advisory section ends at the next heading of the same or shallower level" {
  local dir
  dir="$(make_fixture section_bounds)"
  write_settings "$dir" denier.sh nudger.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" nudger.sh advisory
  {
    printf '# Fixture Hooks\n\n### Advisory (Bash)\n\n'
    printf -- '- **`nudger.sh`**: a fixture entry.\n\n'
    printf '### Blocking (Bash)\n\n'
    printf -- '- **`denier.sh`**: denies things.\n'
  } >"$dir/$PAGE_REL"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "every misfiled entry is reported, not just the first" {
  local dir
  dir="$(make_fixture misfiled_many)"
  write_settings "$dir" denier.sh one.sh two.sh
  write_hook "$dir" denier.sh deny
  write_hook "$dir" one.sh deny
  write_hook "$dir" two.sh exit2
  write_page "$dir" one.sh two.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'one.sh' <<<"$output"
  grep -qF -- 'two.sh' <<<"$output"
}

@test "an unparseable settings.json exits 2 rather than reporting clean" {
  local dir
  dir="$(make_fixture bad_json)"
  printf 'not json\n' >"$dir/.claude/settings.json"
  write_page "$dir" nudger.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'not valid JSON' <<<"$output"
}

@test "a settings.json registering no PreToolUse hook exits 2 rather than reporting clean" {
  local dir
  dir="$(make_fixture no_pretooluse)"
  printf '{"hooks":{"PostToolUse":[]}}\n' >"$dir/.claude/settings.json"
  write_page "$dir" nudger.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'no hook registered on PreToolUse' <<<"$output"
}

@test "a tree whose every PreToolUse hook reads as advisory exits 2 rather than grading against an empty set" {
  local dir
  dir="$(make_fixture no_blockers)"
  write_settings "$dir" nudger.sh
  write_hook "$dir" nudger.sh advisory
  write_page "$dir" nudger.sh
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'classified every PreToolUse hook' <<<"$output"
}

@test "a tree with no wiki directory exits 2 rather than reporting clean" {
  local dir="$BATS_TEST_TMPDIR/no_wiki"
  mkdir -p "$dir/.claude/hooks"
  printf '{"hooks":{"PreToolUse":[]}}\n' >"$dir/.claude/settings.json"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'wiki directory not found' <<<"$output"
}

# The empty-discovery arm, which is a byte-for-byte sibling of the one in
# lint-wiki-cached-version.sh with no shared source between them. Covered here
# too, deliberately: with the arm tested on one copy only, a repair or a
# regression landing on the other has nothing red. Three conditions reach it and
# the repair differs for each.

@test "empty discovery, cause 1: a wiki directory holding no tracked markdown" {
  local dir
  dir="$(make_fixture empty_wiki)"
  write_settings "$dir" denier.sh
  write_hook "$dir" denier.sh deny
  git -C "$dir" add -A

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'discovery listed no tracked markdown' <<<"$output"
  grep -qF -- 'holds no tracked page' <<<"$output"
}

@test "empty discovery, cause 2: a root that is not a git repository" {
  local dir="$BATS_TEST_TMPDIR/not_a_repo_cls"
  mkdir -p "$dir/.claude/hooks" "$dir/wiki"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\\"$(git rev-parse --show-toplevel)/.claude/hooks/denier.sh\\""}]}]}}\n' >"$dir/.claude/settings.json"
  printf '#!/usr/bin/env bash\nexit 2\n' >"$dir/.claude/hooks/denier.sh"
  chmod +x "$dir/.claude/hooks/denier.sh"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'not a usable git repository' <<<"$output"
  grep -qE -- 'not a git repository|fatal' <<<"$output"
}

@test "empty discovery, cause 3: a root below its repository toplevel" {
  local dir
  dir="$(make_fixture below_toplevel_cls)"
  write_settings "$dir" denier.sh
  write_hook "$dir" denier.sh deny
  write_page "$dir" nudger.sh
  mkdir -p "$dir/sub/.claude/hooks" "$dir/sub/wiki"
  cp "$dir/.claude/settings.json" "$dir/sub/.claude/settings.json"
  cp "$dir/.claude/hooks/denier.sh" "$dir/sub/.claude/hooks/denier.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir/sub"
  [ "$status" -eq 2 ]
  grep -qF -- 'sits below its repository toplevel' <<<"$output"
  grep -qF -- 'holds no tracked page' <<<"$output" && return 1
  true
}

@test "a root argument that is not a directory exits 2" {
  run bash "$CHECK" "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  grep -qF -- 'not a directory' <<<"$output"
}

@test "more than one argument exits 2 with usage" {
  run bash "$CHECK" a b
  [ "$status" -eq 2 ]
  grep -qF -- 'usage:' <<<"$output"
}
