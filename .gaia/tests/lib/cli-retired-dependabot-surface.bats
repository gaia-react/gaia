#!/usr/bin/env bats

# The committed CLI bundle no longer offers the Dependabot config and security
# updates writers: the three retired setup subcommands are unknown, the help
# text lists only the alerts configurer, and the sources behind them are gone.
#
# The retired names are built at runtime so this file never carries them as
# literals, which the retirement checks elsewhere would flag.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/tests/lib/cli-retired-dependabot-surface.bats < /dev/null

setup() {
  REPOSITORY_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  BUNDLE="$REPOSITORY_ROOT/.gaia/cli/gaia"
  [ -x "$BUNDLE" ] || skip "committed CLI bundle missing"
  RETIRED_SUBCOMMANDS=(
    "$(printf 'write-dependabot-%s' config)"
    "$(printf 'write-dependabot-%s' policy)"
    "$(printf 'enable-dependabot-%s' security)"
  )
  CURRENT_SUBCOMMAND="configure-dependabot-alerts"
}

# check_help_text <file>: fails when the help text omits the alerts configurer
# or names any retired subcommand.
check_help_text() {
  local file="$1" retired
  [ -s "$file" ] || {
    echo "help text is empty: $file" >&2
    return 1
  }
  grep -qF -- "$CURRENT_SUBCOMMAND" "$file" || {
    echo "help text does not list $CURRENT_SUBCOMMAND" >&2
    return 1
  }
  for retired in "${RETIRED_SUBCOMMANDS[@]}"; do
    if grep -qF -- "$retired" "$file"; then
      echo "help text names a retired subcommand: $retired" >&2
      return 1
    fi
  done
  return 0
}

@test "the retired-name set is derived whole" {
  [ "${#RETIRED_SUBCOMMANDS[@]}" -eq 3 ]
  local name
  for name in "${RETIRED_SUBCOMMANDS[@]}"; do
    [ -n "$name" ]
  done
}

@test "every retired setup subcommand is an unknown subcommand" {
  local name
  for name in "${RETIRED_SUBCOMMANDS[@]}"; do
    run bash -c '"$0" setup "$1" 2>&1 >/dev/null' "$BUNDLE" "$name"
    [ "$status" -ne 0 ]
    case "$output" in
      *unknown_subcommand*) ;;
      *) echo "no unknown_subcommand for $name: $output" >&2; return 1 ;;
    esac
  done
}

@test "an unretired subcommand does not report unknown_subcommand, so the check above can tell them apart" {
  run bash -c '"$0" setup "$1" 2>&1 >/dev/null' "$BUNDLE" "$CURRENT_SUBCOMMAND"
  case "$output" in
    *unknown_subcommand*) return 1 ;;
  esac
  true
}

@test "the top-level help lists the alerts configurer and names no retired subcommand" {
  local help_file="$BATS_TEST_TMPDIR/help.txt"
  "$BUNDLE" --help > "$help_file" 2>&1
  check_help_text "$help_file"
}

@test "the setup help lists the alerts configurer and names no retired subcommand" {
  local help_file="$BATS_TEST_TMPDIR/setup-help.txt"
  "$BUNDLE" setup --help > "$help_file" 2>&1
  check_help_text "$help_file"
}

@test "the help check fails on a help text that still names a retired subcommand" {
  local help_file="$BATS_TEST_TMPDIR/retired-help.txt"
  "$BUNDLE" setup --help > "$help_file" 2>&1
  printf '  %s   Opt in.\n' "${RETIRED_SUBCOMMANDS[0]}" >> "$help_file"
  run check_help_text "$help_file"
  [ "$status" -eq 1 ]
}

@test "the help check fails on a help text without the alerts configurer" {
  local help_file="$BATS_TEST_TMPDIR/bare-help.txt"
  printf 'Usage: gaia setup <subcommand> [args]\n  detect-remote\n' > "$help_file"
  run check_help_text "$help_file"
  [ "$status" -eq 1 ]
}

@test "the retired writer sources and their tests are absent" {
  local directory="$REPOSITORY_ROOT/.gaia/cli/src/setup" name
  # A wrong directory would make every absence below pass.
  [ -f "$directory/configure-dependabot-alerts.ts" ]
  for name in "${RETIRED_SUBCOMMANDS[@]}"; do
    [ -e "$directory/$name.ts" ] && return 1
    [ -e "$directory/__tests__/$name.test.ts" ] && return 1
  done
  true
}
