#!/usr/bin/env bats

# No shipped file names the retired Dependabot surface: the opt-in setting, its
# writer subcommands, the enabler subcommand, the old report section, or the old
# skill tagline. The check reads a path list on stdin and fails naming each file
# that carries a retired name. The real test feeds it the tracked files an
# adopter receives, so the committed CLI bundle is covered too.
#
# Every retired name is built at runtime so this file never carries one.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/tests/lib/dependabot-retired-surface.bats < /dev/null

setup() {
  REPOSITORY_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RETIRED_NAMES=(
    "$(printf 'dependabot_security_%s' updates)"
    "$(printf 'write-dependabot-%s' policy)"
    "$(printf 'write-dependabot-%s' config)"
    "$(printf 'enable-dependabot-%s' security)"
    "$(printf 'Residual %s' advisories)"
    "$(printf 'Autonomous %s' Dependabot)"
  )
}

# check_retired_surface <root>: reads relative paths on stdin; fails naming each
# listed file under <root> that contains a retired name.
check_retired_surface() {
  local root="$1" path name found=0
  while IFS= read -r path; do
    [ -f "$root/$path" ] || continue
    for name in "${RETIRED_NAMES[@]}"; do
      if grep -qF -- "$name" "$root/$path"; then
        echo "retired name '$name' in $path" >&2
        found=1
      fi
    done
  done
  return "$found"
}

# is_exempt_path <path>: history ledgers, audit reports, and test
# infrastructure, which may name a retired surface.
is_exempt_path() {
  case "$1" in
    CHANGELOG.md | wiki/log.md | wiki/hot.md | wiki/meta/* | .gaia/tests/*) return 0 ;;
  esac
  return 1
}

# is_release_excluded <path>: true when .gaia/release-exclude names the path or a
# directory above it, the way tar --exclude-from reads a literal entry.
is_release_excluded() {
  local path="$1" entry
  while IFS= read -r entry; do
    case "$entry" in '' | '#'*) continue ;; esac
    entry="${entry%/}"
    case "$path" in
      "$entry" | "$entry"/*) return 0 ;;
    esac
  done <"$REPOSITORY_ROOT/.gaia/release-exclude"
  return 1
}

# shipped_paths: the tracked files an adopter receives, which this check scans.
shipped_paths() {
  local path
  while IFS= read -r -d '' path; do
    is_exempt_path "$path" && continue
    is_release_excluded "$path" && continue
    printf '%s\n' "$path"
  done < <(git -C "$REPOSITORY_ROOT" ls-files -z)
}

check_shipped_files() {
  shipped_paths | check_retired_surface "$REPOSITORY_ROOT"
}

@test "the retired-name set is derived whole" {
  [ "${#RETIRED_NAMES[@]}" -eq 6 ]
  local name
  for name in "${RETIRED_NAMES[@]}"; do
    [ -n "$name" ]
  done
}

@test "no shipped file names the retired Dependabot surface" {
  run check_shipped_files
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "the committed CLI bundle is among the scanned files" {
  run shipped_paths
  [ "$status" -eq 0 ]
  [[ $'\n'"$output"$'\n' == *$'\n.gaia/cli/gaia\n'* ]]
}

@test "every retired name makes the check fail" {
  local name
  for name in "${RETIRED_NAMES[@]}"; do
    printf 'prefix %s suffix\n' "$name" >"$BATS_TEST_TMPDIR/carrier.txt"
    run check_retired_surface "$BATS_TEST_TMPDIR" <<<"carrier.txt"
    [ "$status" -eq 1 ] || { echo "check passed for: $name" >&2; return 1; }
    [[ "$output" == *"carrier.txt"* ]]
  done
}

@test "a file with no retired name passes the check" {
  printf 'nothing retired here\n' >"$BATS_TEST_TMPDIR/clean.txt"
  run check_retired_surface "$BATS_TEST_TMPDIR" <<<"clean.txt"
  [ "$status" -eq 0 ]
}

@test "an exempt path is not scanned" {
  is_exempt_path CHANGELOG.md
  is_exempt_path wiki/meta/report.md
  is_exempt_path .gaia/tests/lib/example.bats
  ! is_exempt_path README.md
}

@test "a release-excluded path is not scanned and a shipped one is" {
  is_release_excluded "wiki/decisions/Dependabot Security Updates.md"
  ! is_release_excluded ".gaia/cli/gaia"
}
