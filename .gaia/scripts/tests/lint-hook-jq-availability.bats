#!/usr/bin/env bats
# SC2016 is intentional file-wide: the fixture writers below are single-quoted
# precisely so the command-substitution form in the registration reaches the
# file as literal text, which is what makes it a fixture of the real spelling
# rather than of what this shell would expand it to.
# shellcheck disable=SC2016
#
# Conformance suite for .gaia/scripts/lint-hook-jq-availability.sh -- the gate
# that reds when a blocking PreToolUse hook's jq-availability arm stands the
# hook down instead of refusing.
#
# This suite IS the blocking runner. shell-lint.sh invokes the check a second
# way, but a gate run against a tree whose arms are already correct reports
# clean whether its predicates work or not, so an inert predicate is
# indistinguishable from an honest tree there. Every test drives the check
# through its <repo_root> parameter against a fixture tree shaped one way at a
# time, and each predicate gets its own test rather than being trusted.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-hook-jq-availability.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/lint-hook-jq-availability.sh"
}

# make_fixture <name>: a fresh fixture root under BATS_TEST_TMPDIR.
#
# No git repository is needed: this gate discovers over .claude/settings.json
# rather than over a tracked-file listing, and resolves its root from the
# argument. There is no teardown, deliberately: every fixture lives under
# BATS_TEST_TMPDIR, which bats removes per test.
make_fixture() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/.claude/hooks"
  printf '%s' "$dir"
}

# write_settings <dir> <event> <hook-basename>...
#
# Register each named hook under <event>, in the command spelling
# .claude/settings.json actually uses.
write_settings() {
  local dir="$1" event="$2"
  shift 2
  local hook first=1
  {
    printf '{\n  "hooks": {\n    "%s": [\n' "$event"
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

# write_hook <dir> <basename> <kind>
#
# kind=armed        blocking, and reaches the shared arm
# kind=standdown    blocking, and its jq arm exits 0 instead of refusing
# kind=bare         blocking, and carries no jq-availability arm at all
# kind=advisory     never denies, and its jq arm exits 0 (the correct posture)
# kind=nudge        never denies, and carries no jq-availability arm
# kind=nojq         blocking, and never invokes jq, so the gate says nothing
# kind=namesonly    blocking, and NAMES the shared arm in a comment only
# kind=loaderonly   blocking, and carries the loader block that MENTIONS the
#                   shared arm without ever calling it
write_hook() {
  local dir="$1" name="$2" kind="$3"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\npayload=$(cat)\n'
    case "$kind" in
      armed)
        printf ". lib/jq-availability.sh\ngaia_require_jq 'the fixture guard' \"\$payload\" tool_input 'needle'\n"
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      standdown)
        printf 'command -v jq >/dev/null 2>&1 || exit 0\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      bare)
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      advisory)
        printf 'command -v jq >/dev/null 2>&1 || exit 0\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\necho nudge >&2\nexit 0\n"
        ;;
      nudge)
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\necho nudge >&2\nexit 0\n"
        ;;
      nojq)
        printf 'case "$payload" in *danger*) exit 2 ;; esac\nexit 0\n'
        ;;
      namesonly)
        printf '# This header discusses gaia_require_jq without ever calling it.\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      loaderonly)
        # The loader block every armed hook copies, with the call line deleted.
        # It names the shared arm on a non-comment line, so a gate matching the
        # name anywhere grades it clean while its payload read still dies at 127.
        printf 'if ! type gaia_require_jq >/dev/null 2>&1; then\n'
        printf '  printf %s >&2\n' "'BLOCKED: cannot load the arm.\\n'"
        printf '  exit 2\nfi\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
    esac
  } >"$dir/.claude/hooks/$name"
  chmod +x "$dir/.claude/hooks/$name"
}

# --- the clean shapes --------------------------------------------------------

@test "clean: a blocking hook reaching the shared arm passes" {
  local dir
  dir="$(make_fixture clean-armed)"
  write_hook "$dir" armed.sh armed
  write_settings "$dir" PreToolUse armed.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}

@test "clean: an advisory hook standing down passes, and is not held to the refusal" {
  local dir
  dir="$(make_fixture clean-advisory)"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" nudger.sh advisory
  write_settings "$dir" PreToolUse armed.sh nudger.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "clean: a blocking hook that never invokes jq is out of scope" {
  local dir
  dir="$(make_fixture clean-nojq)"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" parseless.sh nojq
  write_settings "$dir" PreToolUse armed.sh parseless.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "clean: a script no registration names is out of scope, whatever its arm" {
  # The scope is the PreToolUse registrations, not the directory listing: a
  # script invoked directly by a caller who sees its exit status owes nothing
  # here, and grading one would red a file with no fail-open to close.
  local dir
  dir="$(make_fixture clean-unregistered)"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" standalone.sh standdown
  write_settings "$dir" PreToolUse armed.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

# --- the findings ------------------------------------------------------------

@test "red: a blocking hook whose jq arm exits 0 is reported" {
  local dir
  dir="$(make_fixture red-standdown)"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" stander.sh standdown
  write_settings "$dir" PreToolUse armed.sh stander.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'stander.sh' <<<"$output"
  grep -qF -- 'no gaia_require_jq call reaches its payload read' <<<"$output"
}

@test "red: a blocking hook with no jq arm at all is reported" {
  local dir
  dir="$(make_fixture red-bare)"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" naked.sh bare
  write_settings "$dir" PreToolUse armed.sh naked.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'naked.sh' <<<"$output"
}

@test "red: naming the shared arm in a comment does not satisfy the check" {
  # The match region is the whole claim. A gate matching anywhere in the file
  # would grade a header paragraph as an arm, which is how this class returns.
  local dir
  dir="$(make_fixture red-namesonly)"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" talker.sh namesonly
  write_settings "$dir" PreToolUse armed.sh talker.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'talker.sh' <<<"$output"
}

@test "red: the loader guard alone does not satisfy the blocking arm" {
  # The match region is the whole assertion. Every armed hook carries a loader
  # block naming the shared arm several lines above the call, so a gate matching
  # the name anywhere on the line is satisfied by the loader alone: a hook that
  # copies the block and omits the call grades clean while its payload read still
  # ends it at 127, which is the fail-open this gate exists to catch.
  local dir
  dir="$(make_fixture red-loaderonly)"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" loader.sh loaderonly
  write_settings "$dir" PreToolUse armed.sh loader.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'loader.sh' <<<"$output"
  grep -qF -- 'no gaia_require_jq call reaches its payload read' <<<"$output"
}

@test "red: an advisory hook with no jq arm at all is reported" {
  local dir
  dir="$(make_fixture red-nudge)"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" nudger.sh nudge
  write_settings "$dir" PreToolUse armed.sh nudger.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'no jq-availability arm stands it down' <<<"$output"
}

# --- fail-closed discovery ---------------------------------------------------

@test "exits 2 when no hook is registered on PreToolUse" {
  local dir
  dir="$(make_fixture empty-registration)"
  write_hook "$dir" armed.sh armed
  printf '{"hooks":{}}\n' >"$dir/.claude/settings.json"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'found no hook registered on PreToolUse' <<<"$output"
}

@test "exits 2 when no registered hook parses its payload with jq" {
  local dir
  dir="$(make_fixture no-parsers)"
  write_hook "$dir" parseless.sh nojq
  write_settings "$dir" PreToolUse parseless.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'parses its payload with jq' <<<"$output"
}

@test "exits 2 when every jq-parsing hook reads as advisory" {
  local dir
  dir="$(make_fixture no-blocking)"
  write_hook "$dir" nudger.sh advisory
  write_settings "$dir" PreToolUse nudger.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'classified every jq-parsing PreToolUse hook as advisory' <<<"$output"
}

@test "exits 2 when the settings file is missing" {
  local dir
  dir="$(make_fixture no-settings)"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'settings file not found' <<<"$output"
}

@test "exits 2 when the settings file is not valid JSON" {
  local dir
  dir="$(make_fixture bad-settings)"
  printf 'not json at all\n' >"$dir/.claude/settings.json"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'not valid JSON' <<<"$output"
}

@test "exits 2 on a root that is not a directory" {
  run bash "$CHECK" "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 2 ]
  grep -qF -- 'not a directory' <<<"$output"
}

@test "exits 2 on too many arguments" {
  run bash "$CHECK" a b
  [ "$status" -eq 2 ]
  grep -qF -- 'too many arguments' <<<"$output"
}

# --- the baseline cannot rot -------------------------------------------------

# stage_check_with_baseline <hook-basename>: a copy of the gate carrying only
# the given baseline entry in place of its real (possibly multi-line) BASELINE
# assignment, and echo its path.
#
# The two tests below exercise the exact-assert over BASELINE, and that assert
# needs the tested entry to be the only one so the assert has a known set to
# check. Parking a fake entry in the shipped gate to feed a test would be
# exactly the standing exemption the assert exists to prevent. So they drive a
# COPY of the gate with the BASELINE assignment substituted and nothing else
# touched, beside a copy of the library the gate loads from its own on-disk
# location. Every predicate under test is the real one byte for byte, because
# the copy is the gate.
stage_check_with_baseline() {
  local entry="$1" dir staged
  dir="$BATS_TEST_TMPDIR/staged-check-$entry"
  mkdir -p "$dir"
  cp "$SCRIPT_DIR/hook-registration-lib.sh" "$dir/hook-registration-lib.sh"
  staged="$dir/lint-hook-jq-availability.sh"
  # The real assignment may span one line (`BASELINE="x"`) or several
  # (`BASELINE="x` ... `y"`), so the whole assignment is replaced rather than
  # one line matched literally: a one-line replacement is emitted in its place,
  # and any continuation line up to the closing quote is swallowed.
  awk -v entry="$entry" '
    skip { if ($0 ~ /"$/) skip = 0; next }
    /^BASELINE=".*"$/ { print "BASELINE=\"" entry "\""; next }
    /^BASELINE="/ { print "BASELINE=\"" entry "\""; skip = 1; next }
    { print }
  ' "$CHECK" >"$staged"
  # A substitution that matched nothing leaves the copy with the real baseline,
  # and both tests below red on their own when it does. What this adds is a
  # named failure at the cause instead of two assertion mismatches pointing at
  # a gate that is behaving correctly. `|| return 1` is load-bearing: the
  # helper is called inside a command substitution, which does not inherit
  # errexit, so a bare failing grep here would run on to the printf and return
  # 0 (.claude/rules/bats-assertions.md, Custom checks).
  grep -qxF -- "BASELINE=\"$entry\"" "$staged" || return 1
  printf '%s' "$staged"
}

@test "red: a baseline entry that no longer fails is reported so it gets deleted" {
  # A baseline whose entries are never re-checked becomes a permanent exemption,
  # and the next hook to regress under one of those names is waved through. The
  # fixture repairs the baselined hook in place.
  local dir entry staged
  dir="$(make_fixture baseline-repaired)"
  entry="baselined-gate.sh"
  staged="$(stage_check_with_baseline "$entry")"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" "$entry" armed
  write_settings "$dir" PreToolUse armed.sh "$entry"

  run bash "$staged" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'baseline entries that no longer fail' <<<"$output"
  grep -qF -- "$entry" <<<"$output"
}

@test "clean: a baselined hook that still fails is carried, not reported" {
  local dir entry staged
  dir="$(make_fixture baseline-live)"
  entry="baselined-gate.sh"
  staged="$(stage_check_with_baseline "$entry")"
  write_hook "$dir" armed.sh armed
  write_hook "$dir" "$entry" standdown
  write_settings "$dir" PreToolUse armed.sh "$entry"

  run bash "$staged" "$dir"
  [ "$status" -eq 0 ]
}

# --- the real tree -----------------------------------------------------------

@test "the live tree is clean" {
  # The fixtures above prove the predicates; this proves the tree they are
  # pointed at. It is cheap, and a regression in either half shows up here as
  # well as in the fixture that isolates it.
  run bash "$CHECK" "$(cd "$SCRIPT_DIR/../.." && pwd)"
  [ "$status" -eq 0 ]
}
