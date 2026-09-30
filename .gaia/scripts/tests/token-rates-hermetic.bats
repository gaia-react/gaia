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
#   export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
#   export GAIA_RATES_FEED_DISABLE=1
# A suite that exercises the feed points GAIA_RATES_FEED_URL at a local stub
# or a file:// URL instead of disabling it.
#
# Suites that only mention the scripts in comments are not in scope: the name
# match reads non-comment lines only.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  SELF="$(basename "$BATS_TEST_FILENAME")"
}

# non_comment <file>: the file's lines that do not start with a comment marker.
non_comment() {
  grep -Ev '^[[:space:]]*#' "$1" || true
}

# hermetic_violations <dir>...: prints one line per suite under the dirs that
# names a pricing-path script on a non-comment line but does not isolate its
# state dir and the feed; returns non-zero when any exist.
hermetic_violations() {
  local dir file body bad=0
  local reaches='token-tally\.sh|token-rollup\.sh|token-tally-git-op\.sh|token-tally-review\.sh|token-rollup-merge\.sh'
  local seam='GAIA_RATES_STATE_DIR=.*(\$\{?BATS_(TEST|FILE|RUN)_TMPDIR|mktemp)'
  local disable='GAIA_RATES_FEED_DISABLE=["'\'']?1(["'\'']|[^0-9A-Za-z_]|$)'
  local feedurl='GAIA_RATES_FEED_URL=.*(RATES_STUB_URL|RATES_PLAIN_URL|127\.0\.0\.1|file://)'
  for dir in "$@"; do
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      [ "$(basename "$file")" = "token-rates-hermetic.bats" ] && continue
      body="$(non_comment "$file")"
      printf '%s\n' "$body" | grep -Eq -- "$reaches" || continue
      if ! printf '%s\n' "$body" | grep -Eq -- "$seam"; then
        printf '%s: no GAIA_RATES_STATE_DIR assignment under a bats temp dir\n' "$file"
        bad=1
      elif ! printf '%s\n' "$body" | grep -Eq -- "$disable" &&
        ! printf '%s\n' "$body" | grep -Eq -- "$feedurl"; then
        printf '%s: neither GAIA_RATES_FEED_DISABLE=1 nor a local GAIA_RATES_FEED_URL\n' "$file"
        bad=1
      fi
    done < <(find "$dir" -type f -name '*.bats' | sort)
  done
  return "$bad"
}

# reaching_suites <dir>...: the suites the guard evaluates (those that name a
# pricing-path script on a non-comment line), excluding the guard itself.
reaching_suites() {
  local dir file
  for dir in "$@"; do
    while IFS= read -r file; do
      [ "$(basename "$file")" = "$SELF" ] && continue
      non_comment "$file" |
        grep -Eq 'token-tally\.sh|token-rollup\.sh|token-tally-git-op\.sh|token-tally-review\.sh|token-rollup-merge\.sh' &&
        printf '%s\n' "$file"
    done < <(find "$dir" -type f -name '*.bats' | sort)
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
  local found f n=0
  found="$(find "$REPO_ROOT/.gaia/scripts/tests" "$REPO_ROOT/.gaia/tests" -type f -name '*.bats' | sed "s|^$REPO_ROOT/||" | sort)"
  while IFS= read -r -d '' f; do
    n=$((n + 1))
    printf '%s\n' "$found" | grep -qxF -- "$f" || {
      echo "tracked suite missed by the scan: $f"
      return 1
    }
  done < <(git -C "$REPO_ROOT" ls-files -z -- '.gaia/scripts/tests/*.bats' '.gaia/tests/*.bats')
  [ "$n" -gt 0 ]
}

# The fixture suites below carry literal `$VAR` text the guard must read
# unexpanded, so single-quoted `$` is deliberate.
# shellcheck disable=SC2016
@test "driven into its failing state: non-compliant scratch suites are named, a compliant one passes" {
  local d="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$d"

  printf '%s\n' '@test "x" { bash token-tally.sh; }' >"$d/neither.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIR=/tmp/x'
    printf '%s\n' '  export GAIA_RATES_FEED_DISABLE=1'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-rollup.sh; }'
  } >"$d/nontemp-seam.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/s"'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-tally-git-op.sh; }'
  } >"$d/no-disable.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/s"'
    printf '%s\n' '  export GAIA_RATES_FEED_URL=https://raw.githubusercontent.com/gaia-react/gaia/main/.gaia/scripts/token-rates.json'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-tally-review.sh; }'
  } >"$d/real-url.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/s"'
    printf '%s\n' '  export GAIA_RATES_FEED_DISABLE=1'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-tally.sh; }'
  } >"$d/compliant.bats"
  {
    printf '%s\n' 'setup() {'
    printf '%s\n' '  export GAIA_RATES_STATE_DIR="$(mktemp -d)"'
    printf '%s\n' '  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"'
    printf '%s\n' '}'
    printf '%s\n' '@test "x" { bash token-rollup-merge.sh; }'
  } >"$d/compliant-stub.bats"
  # A comment naming the script is out of scope even with no isolation.
  printf '%s\n' '# runs token-tally.sh elsewhere' '@test "x" { true; }' >"$d/comment-only.bats"

  run hermetic_violations "$d"
  [ "$status" -ne 0 ]
  local name
  for name in neither nontemp-seam no-disable real-url; do
    printf '%s\n' "$output" | grep -qF -- "$d/$name.bats" || {
      echo "not named: $name"
      echo "$output"
      return 1
    }
  done
  local ok
  for ok in compliant compliant-stub comment-only; do
    printf '%s\n' "$output" | grep -qF -- "$d/$ok.bats" && {
      echo "wrongly flagged: $ok"
      return 1
    }
  done

  rm -f "$d/neither.bats" "$d/nontemp-seam.bats" "$d/no-disable.bats" "$d/real-url.bats"
  run hermetic_violations "$d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
