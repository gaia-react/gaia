#!/usr/bin/env bats
#
# The readout's formatting helpers have one definition each under
# .gaia/scripts, so a second copy cannot drift from the first. A duration
# formatter is any function whose name ends in human_duration; the other two are
# matched by exact name.
#
# The file set is every tracked shell script under .gaia/scripts except test
# fixtures (a fixture may carry a frozen copy of an old definition on purpose).
# A script that is not yet tracked is outside the discovery until it is staged.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
}

script_files() {
  git -C "$REPO_ROOT" ls-files -- '.gaia/scripts/*.sh' | grep -v -E '(^|/)tests/fixtures/' || true
}

# definition_pattern <name-suffix-or-exact> <ends-with|exact>
definition_pattern() {
  local name_part
  if [ "$2" = "ends-with" ]; then name_part="[A-Za-z_0-9]*$1"; else name_part="$1"; fi
  printf '^[[:space:]]*(function[[:space:]]+%s([[:space:]]|\\(|\\{|$)|%s[[:space:]]*\\(\\))' "$name_part" "$name_part"
}

# files_defining <name> <mode>: one file path per line, each file once.
files_defining() {
  local pattern file
  pattern="$(definition_pattern "$1" "$2")"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if grep -q -E "$pattern" "$REPO_ROOT/$file"; then printf '%s\n' "$file"; fi
  done <<<"$(script_files)"
}

@test "the file set is non-empty and includes the render library" {
  files="$(script_files)"
  [ -n "$files" ]
  printf '%s\n' "$files" | grep -q -x '.gaia/scripts/usage-render-lib.sh'
}

@test "each helper is defined in at most one file, and the duration formatter and commify in exactly one" {
  local entry name mode defining count
  for entry in "human_duration:ends-with" "is_unsigned_integer:exact" "commify:exact"; do
    name="${entry%%:*}"
    mode="${entry##*:}"
    defining="$(files_defining "$name" "$mode")"
    count="$(printf '%s' "$defining" | grep -c . || true)"
    if [ "$count" -gt 1 ]; then
      printf '%s defined in %s files:\n%s\n' "$name" "$count" "$defining" >&2
      return 1
    fi
    case "$name" in
      human_duration | commify)
        # A guard that can only find zero would pass if the discovery broke.
        [ "$count" -eq 1 ] || { printf '%s has no definition\n' "$name" >&2; return 1; }
        ;;
    esac
  done
}
