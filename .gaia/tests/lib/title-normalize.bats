#!/usr/bin/env bats
# Tests for title-normalize.sh: the shared ledger-title truncation rule
# (collapse whitespace -> first sentence -> bounded word-safe prefix, or a
# hard cut when the over-bound text has no interior word boundary). Dual-mode
# (sourced function + argv/stdin filter); each test spins up its own tmp repo
# via helpers/tmp-spec-repo.sh so the lib is exercised as a real file on disk,
# not the live working tree.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

# Sourced-mode call: bash -c '. "$1"; gaia_normalize_title "$2"' _ "$LIBRARY_PATH" "<raw>"
# Raw text is passed as a positional arg (never interpolated into the script
# string), so embedded quotes/newlines in the raw text are never a hazard.
_normalize_title() {
  bash -c '. "$1"; gaia_normalize_title "$2"' _ "$LIBRARY_PATH" "$1"
}

@test "1: short single-sentence input returns unchanged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  run _normalize_title "Add a widget."
  [ "$status" -eq 0 ]
  [ "$output" = "Add a widget." ]
}

@test "2: within-bound input with no terminator returns the collapsed line unchanged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  run _normalize_title "a short subject with no terminator"
  [ "$status" -eq 0 ]
  [ "$output" = "a short subject with no terminator" ]
}

@test "3: multi-line input collapses to one space-joined line" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  raw="$(printf 'a\n  b\nc')"
  run _normalize_title "$raw"
  [ "$status" -eq 0 ]
  [ "$output" = "a b c" ]
}

@test "4: over-bound first sentence with interior spaces -> word-safe prefix ending in ..." {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  raw='The quick brown fox jumps over the lazy dog while the astonishingly persistent watchdog barks incessantly at the mail carrier every single morning without fail, causing considerable frustration.'
  run _normalize_title "$raw"
  [ "$status" -eq 0 ]
  body="${output%...}"
  [ "$body" != "$output" ]
  [ "${#body}" -le 120 ]
  last="${body:$((${#body} - 1)):1}"
  [ "$last" != " " ]
}

@test "5: single over-bound token with no interior space is hard-cut to 120 chars + ..." {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  token="$(printf 'a%.0s' $(seq 1 200))"
  run _normalize_title "$token"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 123 ]
  first120="${output:0:120}"
  without_letter_a="$(printf '%s' "$first120" | tr -d 'a')"
  [ -z "$without_letter_a" ]
}

@test "6: empty input yields empty output" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  run _normalize_title ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "7: the real SPEC-003 first sentence normalizes to a word-safe prefix, not the defect string" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  # Literal copy of the archived SPEC-003 intent block's opening lines (a
  # multi-line YAML block scalar in the live, gitignored specs ledger data);
  # embedded here so the suite is hermetic and does not depend on that local,
  # untracked file being present. Built with printf (not a heredoc) since a
  # single-quoted heredoc containing an apostrophe confuses bats' own file
  # discovery on stock macOS /bin/bash (3.2).
  raw="$(printf '%s\n%s\n%s' \
    "GAIA's test-driven workflow already instructs the agent to write a failing" \
    "test first, but that \"failing first\" claim is self-certified: nothing checks" \
    "the test actually ran and failed before the agent made it pass. This feature")"
  defect="GAIA's test-driven workflow already instructs the agent to write a failing"
  run _normalize_title "$raw"
  [ "$status" -eq 0 ]
  [ "$output" != "$defect" ]
  body="${output%...}"
  [ "$body" != "$output" ]
}

@test "8: idempotency on source; the same raw over-bound source twice yields identical output" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  raw='The quick brown fox jumps over the lazy dog while the astonishingly persistent watchdog barks incessantly at the mail carrier every single morning without fail, causing considerable frustration.'
  first_output="$(_normalize_title "$raw")"
  second_output="$(_normalize_title "$raw")"
  [ "$first_output" = "$second_output" ]
}

@test "9: filter mode matches the sourced function for the same raw input" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  raw='The quick brown fox jumps over the lazy dog while the astonishingly persistent watchdog barks incessantly at the mail carrier every single morning without fail, causing considerable frustration.'
  sourced_output="$(_normalize_title "$raw")"
  filter_output="$(printf '%s' "$raw" | bash "$LIBRARY_PATH")"
  [ "$sourced_output" = "$filter_output" ]
}

@test "10: output idempotency; an already-...-suffixed over-bound title is a fixed point" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  raw='The quick brown fox jumps over the lazy dog while the astonishingly persistent watchdog barks incessantly at the mail carrier every single morning without fail, causing considerable frustration.'
  first_output="$(_normalize_title "$raw")"
  second_output="$(_normalize_title "$first_output")"
  [ "$first_output" = "$second_output" ]
}

@test "11: sourcing is a silent no-op even with a non-empty positional \$1" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LIBRARY_PATH="$REPO/.specify/extensions/gaia/lib/title-normalize.sh"
  run bash -c 'library="$1"; set -- next; . "$library"' _ "$LIBRARY_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
