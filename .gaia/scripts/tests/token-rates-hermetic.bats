#!/usr/bin/env bats
#
# Hermeticity guard for the machine-local rate table. Pricing seeds and writes
# <main>/.gaia/local/telemetry and, on a missing model, reaches the network, so
# a bats suite that runs the tally or roll-up without isolating both would
# write the developer's real local state and could fetch from the real feed.
#
# The rule is suite-level on purpose: an invocation through a $SCRIPT variable
# or a hook cannot be matched per call, so every suite that reaches the pricing
# path isolates itself once, in setup:
#   export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
#   export GAIA_RATES_FEED_DISABLE=1
# A suite that exercises the feed points GAIA_RATES_FEED_URL at a local stub
# or a file:// URL instead of disabling it.
#
# Suites that only mention the scripts in comments are not in scope: the name
# match reads non-comment lines only.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  SELF="$(basename "$BATS_TEST_FILENAME")"
}

# The scripts that reach the pricing path; both the violation scan and the
# reaching-suites derivation read this one pattern.
PRICING_PATH_SCRIPTS='token-tally\.sh|token-rollup\.sh|token-tally-git-op\.sh|token-tally-review\.sh|token-rollup-merge\.sh|usage\.sh|usage-merge\.sh'

# non_comment <file>: the file's lines that do not start with a comment marker.
non_comment() {
  grep -Ev '^[[:space:]]*#' "$1" || true
}

# hermetic_violations <directory>...: prints one line per suite under the dirs that
# names a pricing-path script on a non-comment line but does not isolate its
# state dir and the feed; returns non-zero when any exist.
hermetic_violations() {
  local directory file body bad=0
  local reaches="$PRICING_PATH_SCRIPTS"
  local seam='GAIA_RATES_STATE_DIRECTORY=.*(\$\{?BATS_(TEST|FILE|RUN)_TMPDIR|mktemp)'
  local disable='GAIA_RATES_FEED_DISABLE=["'\'']?1(["'\'']|[^0-9A-Za-z_]|$)'
  local feed_url_pattern='GAIA_RATES_FEED_URL=.*(RATES_STUB_URL|RATES_PLAIN_URL|127\.0\.0\.1|file://)'
  for directory in "$@"; do
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      [ "$(basename "$file")" = "token-rates-hermetic.bats" ] && continue
      body="$(non_comment "$file")"
      printf '%s\n' "$body" | grep -Eq -- "$reaches" || continue
      if ! printf '%s\n' "$body" | grep -Eq -- "$seam"; then
        printf '%s: no GAIA_RATES_STATE_DIRECTORY assignment under a bats temp dir\n' "$file"
        bad=1
      elif ! printf '%s\n' "$body" | grep -Eq -- "$disable" &&
        ! printf '%s\n' "$body" | grep -Eq -- "$feed_url_pattern"; then
        printf '%s: neither GAIA_RATES_FEED_DISABLE=1 nor a local GAIA_RATES_FEED_URL\n' "$file"
        bad=1
      fi
    done < <(find "$directory" -type f -name '*.bats' | sort)
  done
  return "$bad"
}

# reaching_suites <directory>...: the suites the guard evaluates (those that name a
# pricing-path script on a non-comment line), excluding the guard itself.
reaching_suites() {
  local directory file
  for directory in "$@"; do
    while IFS= read -r file; do
      [ "$(basename "$file")" = "$SELF" ] && continue
      non_comment "$file" |
        grep -Eq "$PRICING_PATH_SCRIPTS" &&
        printf '%s\n' "$file"
    done < <(find "$directory" -type f -name '*.bats' | sort)
  done
  return 0
}

@test "every suite that reaches the pricing path isolates its rates state and the feed" {
  run hermetic_violations "$REPO_ROOT/.gaia/scripts/tests" "$REPO_ROOT/.gaia/tests"
  if [ "$status" -ne 0 ]; then
    printf 'NON-HERMETIC SUITES:\n%s\n' "$output"
    return 1
  fi
  true
}

@test "the derived set is non-empty and covers the tally, roll-up, and tally git-op hook suites" {
  local set
  set="$(reaching_suites "$REPO_ROOT/.gaia/scripts/tests" "$REPO_ROOT/.gaia/tests")"
  [ -n "$set" ]
  printf '%s\n' "$set" | grep -q '/\.gaia/scripts/tests/token-tally\.bats$' || return 1
  printf '%s\n' "$set" | grep -q '/\.gaia/scripts/tests/token-rollup\.bats$' || return 1
  printf '%s\n' "$set" | grep -q '/\.gaia/tests/hooks/token-tally-git-op\.bats$' || return 1
  true
}

@test "the filesystem scan sees every tracked suite under the two dirs (no short read)" {
  local found tracked_path tracked_count=0
  found="$(find "$REPO_ROOT/.gaia/scripts/tests" "$REPO_ROOT/.gaia/tests" -type f -name '*.bats' | sed "s|^$REPO_ROOT/||" | sort)"
  while IFS= read -r -d '' tracked_path; do
    tracked_count=$((tracked_count + 1))
    printf '%s\n' "$found" | grep -qxF -- "$tracked_path" || {
      echo "tracked suite missed by the scan: $tracked_path"
      return 1
    }
  done < <(git -C "$REPO_ROOT" ls-files -z -- '.gaia/scripts/tests/*.bats' '.gaia/tests/*.bats')
  [ "$tracked_count" -gt 0 ]
}

# The fixture suites below carry literal `$VAR` text the guard must read
# unexpanded, so single-quoted `$` is deliberate.
# shellcheck disable=SC2016
@test "driven into its failing state: non-compliant scratch suites are named, a compliant one passes" {
  local scratch_directory="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$scratch_directory"

  printf '%s\n' '@test "x" { bash token-tally.sh; }' >"$scratch_directory/neither.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIRECTORY=/tmp/x'
    printf '%s\n' '  export GAIA_RATES_FEED_DISABLE=1'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-rollup.sh; }'
  } >"$scratch_directory/nontemp-seam.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/s"'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-tally-git-op.sh; }'
  } >"$scratch_directory/no-disable.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/s"'
    printf '%s\n' '  export GAIA_RATES_FEED_URL=https://raw.githubusercontent.com/gaia-react/gaia/main/.gaia/scripts/token-rates.json'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-tally-review.sh; }'
  } >"$scratch_directory/real-url.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/s"'
    printf '%s\n' '  export GAIA_RATES_FEED_DISABLE=1'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-tally.sh; }'
  } >"$scratch_directory/compliant.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIRECTORY="$(mktemp -d)"'
    printf '%s\n' '  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-rollup-merge.sh; }'
  } >"$scratch_directory/compliant-stub.bats"
  # A comment naming the script is out of scope even with no isolation.
  printf '%s\n' '# runs token-tally.sh elsewhere' '@test "x" { true; }' >"$scratch_directory/comment-only.bats"

  run hermetic_violations "$scratch_directory"
  [ "$status" -ne 0 ]
  local name
  for name in neither nontemp-seam no-disable real-url; do
    printf '%s\n' "$output" | grep -qF -- "$scratch_directory/$name.bats" || {
      echo "not named: $name"
      echo "$output"
      return 1
    }
  done
  local ok
  for ok in compliant compliant-stub comment-only; do
    printf '%s\n' "$output" | grep -qF -- "$scratch_directory/$ok.bats" && {
      echo "wrongly flagged: $ok"
      return 1
    }
  done

  rm -f "$scratch_directory/neither.bats" "$scratch_directory/nontemp-seam.bats" "$scratch_directory/no-disable.bats" "$scratch_directory/real-url.bats"
  run hermetic_violations "$scratch_directory"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a suite that runs the usage scripts without isolation is reported by both the violation scan and the reaching-suites derivation" {
  local scratch_directory="$BATS_TEST_TMPDIR/usage-fixtures" name
  mkdir -p "$scratch_directory"
  printf '%s\n' '@test "x" { bash .gaia/scripts/usage.sh pr 1; }' >"$scratch_directory/bare-usage.bats"
  printf '%s\n' '@test "x" { bash .gaia/scripts/usage-merge.sh; }' >"$scratch_directory/bare-merge.bats"

  run hermetic_violations "$scratch_directory"
  [ "$status" -ne 0 ]
  for name in bare-usage bare-merge; do
    printf '%s\n' "$output" | grep -qF -- "$scratch_directory/$name.bats" || {
      echo "violation scan missed: $name"
      return 1
    }
  done

  run reaching_suites "$scratch_directory"
  for name in bare-usage bare-merge; do
    printf '%s\n' "$output" | grep -qF -- "$scratch_directory/$name.bats" || {
      echo "reaching_suites missed: $name"
      return 1
    }
  done
}
