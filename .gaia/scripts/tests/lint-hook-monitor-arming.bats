#!/usr/bin/env bats
# SC2016 is intentional file-wide: the fixture writers below are single-quoted
# precisely so the command-substitution form in the registration reaches the
# file as literal text, which is what makes it a fixture of the real spelling
# rather than of what this shell would expand it to.
# shellcheck disable=SC2016
#
# Conformance suite for .gaia/scripts/lint-hook-monitor-arming.sh -- the gate
# that reds when a command-reading PreToolUse guard is bound to `Bash` alone, or
# when a matcher that does reach `Monitor` sits over a hook whose own
# `tool_name` test still stands it down on one.
#
# This suite IS the blocking runner. shell-lint.sh invokes the check a second
# way, but a gate run against a tree whose matchers are already correct reports
# clean whether its predicates work or not, so an inert predicate is
# indistinguishable from an honest tree there. Every test drives the check
# through its <repo_root> parameter against a fixture tree shaped one way at a
# time, and each predicate gets its own test rather than being trusted.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-hook-monitor-arming.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/lint-hook-monitor-arming.sh"
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

# write_settings <dir> <matcher:hook,hook...>...
#
# Each argument is one PreToolUse row: the matcher, a colon, then the hooks it
# registers separated by commas. Rows are written in the order given, in the
# command spelling .claude/settings.json actually uses.
write_settings() {
  local dir="$1"
  shift
  local spec matcher hooks hook first=1 inner
  {
    printf '{\n  "hooks": {\n    "PreToolUse": [\n'
    for spec in "$@"; do
      matcher="${spec%%:*}"
      hooks="${spec#*:}"
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '      {\n        "matcher": "%s",\n        "hooks": [\n' "$matcher"
      inner=1
      while [ -n "$hooks" ]; do
        hook="${hooks%%,*}"
        [ "$inner" -eq 1 ] || printf ',\n'
        inner=0
        printf '          {\n            "type": "command",\n'
        printf '            "command": "\\"$(git rev-parse --show-toplevel)/.claude/hooks/%s\\""\n' "$hook"
        printf '          }'
        case "$hooks" in
          *,*) hooks="${hooks#*,}" ;;
          *) hooks='' ;;
        esac
      done
      printf '\n        ]\n      }'
    done
    printf '\n    ]\n  }\n}\n'
  } >"$dir/.claude/settings.json"
}

# write_hook <dir> <basename> <kind>
#
# kind=blocking     reads tool_input.command, pins tool_name to Bash, denies
# kind=dualgated    reads tool_input.command, admits Bash and Monitor, denies
# kind=ungated      reads tool_input.command, tests no tool_name at all, denies
# kind=advisory     reads tool_input.command, pins tool_name to Bash, exits 0
# kind=pathonly     never reads tool_input.command, denies on a file path
# kind=talker       admits Bash only, but NAMES Monitor in a header comment
write_hook() {
  local dir="$1" name="$2" kind="$3"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\npayload=$(cat)\n'
    printf "tool_name=\$(jq -r '.tool_name // \"\"' <<<\"\$payload\")\n"
    case "$kind" in
      blocking)
        printf '[ "$tool_name" = "Bash" ] || exit 0\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      dualgated)
        printf 'case "$tool_name" in\n  Bash | Monitor) ;;\n  *) exit 0 ;;\nesac\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      ungated)
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      advisory)
        printf '[ "$tool_name" = "Bash" ] || exit 0\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\necho noted >&2\nexit 0\n"
        ;;
      pathonly)
        printf '[ "$tool_name" = "Bash" ] || exit 0\n'
        printf "p=\$(jq -r '.tool_input.file_path' <<<\"\$payload\")\nexit 2\n"
        ;;
      talker)
        # The header discusses Monitor without the gate ever admitting one, so a
        # match that counted comments would grade this as armed.
        printf '# This header explains why Monitor matters and admits none.\n'
        printf '[ "$tool_name" = "Bash" ] || exit 0\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      prose_mention)
        # A non-comment line NAMES Monitor -- a deny-reason string, the shape a
        # repair prose naturally reaches for -- without the tool_name test ever
        # admitting it. A bare substring search over non-comment lines reads
        # this as armed; only a search for an actual gating construct catches
        # it.
        printf '[ "$tool_name" = "Bash" ] || exit 0\n'
        printf 'reason="this shape is denied however it is armed, Bash or Monitor"\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      paren_mention)
        # A near miss for the case-arm pattern: Monitor immediately precedes a
        # `)` on a prose line, `(Bash or Monitor)`, without the line being a
        # case-arm pattern list at all. An unanchored case-arm probe (Monitor
        # bounded by a non-alnum character and followed by `)`) matches this;
        # anchoring the probe at the start of the (already stripped) line does
        # not, because the line does not begin with a bar-separated identifier
        # list.
        printf '[ "$tool_name" = "Bash" ] || exit 0\n'
        printf 'reason="this shape is denied on either tool (Bash or Monitor)"\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      assign_mention)
        # A near miss for the equality probe: a plain bash assignment whose
        # VALUE starts with the literal word Monitor, `reason="Monitor and
        # Bash..."`. An equality probe with no leading-whitespace requirement
        # matches the `=` this assignment carries; requiring a whitespace
        # character before the operator does not, because a bash assignment
        # carries none.
        printf '[ "$tool_name" = "Bash" ] || exit 0\n'
        printf 'reason="Monitor and Bash both hand this hook the same command"\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
      equality_dualgated)
        # The equality-comparison shape of admits_monitor's positive arm,
        # exercised on its own: every other "clean" fixture in this suite
        # gates through the case-arm shape, which leaves the equality branch
        # untested by any passing fixture.
        printf 'if [ "$tool_name" = "Bash" ] || [ "$tool_name" = "Monitor" ]; then\n  :\nelse\n  exit 0\nfi\n'
        printf "cmd=\$(jq -r '.tool_input.command' <<<\"\$payload\")\nexit 2\n"
        ;;
    esac
  } >"$dir/.claude/hooks/$name"
  chmod +x "$dir/.claude/hooks/$name"
}

# --- the clean shapes --------------------------------------------------------

@test "clean: a blocking command-reader on a Bash|Monitor row, gated for both, passes" {
  local dir
  dir="$(make_fixture clean-dual)"
  write_hook "$dir" guard.sh dualgated
  write_settings "$dir" 'Bash|Monitor:guard.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}

@test "clean: a hook that tests no tool_name needs no widening of its own" {
  local dir
  dir="$(make_fixture clean-ungated)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" open.sh ungated
  write_settings "$dir" 'Bash|Monitor:guard.sh,open.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "clean: an advisory command-reader on a Bash-only row is left alone" {
  # The posture split is the whole point: arming a recorder on a second tool
  # changes what it counts, so this gate says nothing about one either way.
  local dir
  dir="$(make_fixture clean-advisory)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" tally.sh advisory
  write_settings "$dir" 'Bash|Monitor:guard.sh' 'Bash:tally.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "clean: a blocking hook that never reads tool_input.command is out of scope" {
  local dir
  dir="$(make_fixture clean-pathonly)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" pather.sh pathonly
  write_settings "$dir" 'Bash|Monitor:guard.sh' 'Bash:pather.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "clean: a row whose matcher never reaches Bash carries no obligation" {
  # A Bash-only reading of the matcher would demand Monitor of an
  # Edit|Write|MultiEdit row, which binds no shell command at all.
  local dir
  dir="$(make_fixture clean-editrow)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" writer.sh pathonly
  write_settings "$dir" 'Bash|Monitor:guard.sh' 'Edit|Write|MultiEdit:writer.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "clean: a script no registration names is out of scope" {
  local dir
  dir="$(make_fixture clean-unregistered)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" standalone.sh blocking
  write_settings "$dir" 'Bash|Monitor:guard.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

# --- arm A: the under-armed matcher ------------------------------------------

@test "red: a blocking command-reader on a Bash-only row is reported" {
  local dir
  dir="$(make_fixture red-bashonly)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" naked.sh blocking
  write_settings "$dir" 'Bash|Monitor:guard.sh' 'Bash:naked.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'naked.sh' <<<"$output"
  grep -qF -- 'reaches Bash but not Monitor' <<<"$output"
}

@test "red: the judgement is per row, so a second row's Monitor does not satisfy it" {
  # Two rows registering one hook also run it twice wherever both matchers
  # select the same tool, so the repair is one row naming both tools rather
  # than a pair of rows that between them cover the surface.
  local dir
  dir="$(make_fixture red-splitrows)"
  write_hook "$dir" guard.sh dualgated
  write_settings "$dir" 'Bash:guard.sh' 'Monitor:guard.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'reaches Bash but not Monitor' <<<"$output"
}

@test "red: an alternation reaching Bash without Monitor is still under-armed" {
  # The matcher is an unanchored regex over the tool name, so a check reading it
  # as a literal would call this row armed for every tool it merely lists.
  local dir
  dir="$(make_fixture red-alternation)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" naked.sh blocking
  write_settings "$dir" 'Bash|Monitor:guard.sh' 'Bash|Agent:naked.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'naked.sh' <<<"$output"
}

# --- arm B: the inert internal gate ------------------------------------------

@test "red: a Monitor-armed row over a hook that still pins tool_name to Bash" {
  # The half a reader of the settings diff cannot see: the matcher says armed
  # and the hook stands itself down, so nothing reaches the payload read.
  local dir
  dir="$(make_fixture red-inert)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" halffixed.sh blocking
  write_settings "$dir" 'Bash|Monitor:guard.sh,halffixed.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'halffixed.sh' <<<"$output"
  grep -qF -- 'admits Bash alone' <<<"$output"
}

@test "red: naming Monitor in a comment does not satisfy the internal gate" {
  # The match region is the whole claim. Every hook here discusses the tools it
  # binds in its header, so a probe that counted comments would grade a
  # paragraph as an arm.
  local dir
  dir="$(make_fixture red-talker)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" talker.sh talker
  write_settings "$dir" 'Bash|Monitor:guard.sh,talker.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'talker.sh' <<<"$output"
}

@test "red: a non-comment mention of Monitor does not satisfy admits_monitor" {
  # The regression fixture for the finding a code-audit-maintainer-shell round
  # raised against this gate's own arm B: a hook whose deny-reason string
  # SAYS Monitor, on a code line rather than a comment, while its own
  # tool_name test still admits Bash alone. names_outside_comments('Monitor')
  # read that as armed; admits_monitor requires an actual gating construct
  # (a case-arm pattern list or an equality comparison) and correctly does not.
  local dir
  dir="$(make_fixture red-prose-mention)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" mentioner.sh prose_mention
  write_settings "$dir" 'Bash|Monitor:guard.sh,mentioner.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'mentioner.sh' <<<"$output"
}

@test "red: Monitor immediately preceding a prose ) does not satisfy the case-arm probe" {
  # The regression fixture for a second code-audit-maintainer-shell round's
  # finding against the FIRST repair: an unanchored case-arm probe (Monitor
  # bounded by a non-alnum character, followed by `)`) matched a prose line
  # that is not a case-arm pattern list at all, `(Bash or Monitor)`. Anchoring
  # the probe at the start of the stripped line closes it.
  local dir
  dir="$(make_fixture red-paren-mention)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" mentioner.sh paren_mention
  write_settings "$dir" 'Bash|Monitor:guard.sh,mentioner.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'mentioner.sh' <<<"$output"
}

@test "red: a bash assignment whose value starts with Monitor does not satisfy the equality probe" {
  # The regression fixture for the same round's second finding: an equality
  # probe with no leading-whitespace requirement matched a plain assignment,
  # `reason="Monitor and Bash..."`, that carries no space before its `=`.
  # Requiring a whitespace character before the operator closes it, because a
  # bash assignment carries none while a `[ ]`/`[[ ]]` comparison always does.
  local dir
  dir="$(make_fixture red-assign-mention)"
  write_hook "$dir" guard.sh dualgated
  write_hook "$dir" mentioner.sh assign_mention
  write_settings "$dir" 'Bash|Monitor:guard.sh,mentioner.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'mentioner.sh' <<<"$output"
}

@test "clean: an equality comparison against Monitor satisfies admits_monitor" {
  # Every other clean fixture in this suite gates through the case-arm shape;
  # this one exercises admits_monitor's equality branch on its own, so a
  # regression in that branch alone has a passing fixture to break.
  local dir
  dir="$(make_fixture clean-equality)"
  write_hook "$dir" guard.sh equality_dualgated
  write_settings "$dir" 'Bash|Monitor:guard.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}

# --- fail-closed discovery ---------------------------------------------------

@test "exits 2 when no hook is registered on PreToolUse" {
  local dir
  dir="$(make_fixture empty-registration)"
  write_hook "$dir" guard.sh dualgated
  printf '{"hooks":{}}\n' >"$dir/.claude/settings.json"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'found no hook registered on PreToolUse' <<<"$output"
}

@test "exits 2 when no registration's matcher reaches Bash" {
  local dir
  dir="$(make_fixture no-bash-rows)"
  write_hook "$dir" writer.sh pathonly
  write_settings "$dir" 'Edit|Write|MultiEdit:writer.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'whose matcher reaches Bash' <<<"$output"
}

@test "exits 2 when no blocking command-reader is registered on a Bash row" {
  local dir
  dir="$(make_fixture no-subjects)"
  write_hook "$dir" tally.sh advisory
  write_settings "$dir" 'Bash:tally.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'no blocking, command-reading PreToolUse hook' <<<"$output"
}

@test "exits 2 on a matcher grep cannot read as an ERE" {
  # A matcher this gate silently read as matching nothing would exempt its row
  # from both arms, which is the one outcome a gate against a silent bypass
  # must not produce.
  local dir
  dir="$(make_fixture bad-matcher)"
  write_hook "$dir" guard.sh dualgated
  write_settings "$dir" 'Bash|Monitor:guard.sh' 'Bash[:guard.sh'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot read as an ERE' <<<"$output"
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

# --- the live tree -----------------------------------------------------------

@test "the repository's own PreToolUse registrations are clean" {
  local root
  root="$(cd "$SCRIPT_DIR/../.." && pwd)"

  run bash "$CHECK" "$root"
  [ "$status" -eq 0 ]
}
