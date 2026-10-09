#!/usr/bin/env bats
#
# The usage readout path is network-free: a model absent from the rate tables
# prices as unpriced and never triggers a fetch. Proved two ways: behaviorally
# (curl, wget and nc stubs first on PATH record any call into a sentinel file)
# and structurally (no non-comment line of the readout scripts, and no non-comment
# line of the pricing library, names a network tool or a retired rate-library
# entry point, and the library sources no other file).
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/pricing-no-network.bats

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

# Files whose non-comment lines must name no network tool and no retired
# rate-library entry point. Appending a path here extends the static check.
READOUT_FILES=(usage-render-lib.sh usage-memo-lib.sh usage.sh)
READOUT_PATTERN='curl|wget|/dev/tcp|GAIA_RATES_FEED_|gaia_rates_heal|gaia_rates_prepare|gaia_resolve_rate_table'
LOAD_PATTERN='curl|wget|/dev/tcp|GAIA_RATES_FEED_'
# A source line is `source <path>` or `. <path>` with a quoted, variable or
# path-shaped operand; the bare `. as $name` of a jq program in the library's
# heredoc is not one.
SOURCE_PATTERN='^[[:space:]]*(source[[:space:]]|\.[[:space:]]+["'"'"'$/.~])'

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/pricing"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TELEMETRY_DIRECTORY="$MAIN/.gaia/local/telemetry"
  mkdir -p "$MAIN/.claude" "$TELEMETRY_DIRECTORY" "$TEMPORARY_DIRECTORY/projects" "$TEMPORARY_DIRECTORY/bin"
  git -C "$MAIN" init -q -b main
  cat >"$MAIN/.claude/settings.json" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
EOF
  cp "$FIXTURES_DIRECTORY/usage.jsonl" "$TELEMETRY_DIRECTORY/"
  printf '%s\n' '{"schema_version":1,"kind":"edge","child":"branch:feat/price","parent":"research:net","source":"link-command","ts":"2026-10-01T00:00:00Z","session_id":null,"sidechain":false}' \
    >"$TELEMETRY_DIRECTORY/links.jsonl"
  SENTINEL="$TEMPORARY_DIRECTORY/network-sentinel"
  : >"$SENTINEL"
  local tool_name
  for tool_name in curl wget nc; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$tool_name" "$SENTINEL" >"$TEMPORARY_DIRECTORY/bin/$tool_name"
    chmod +x "$TEMPORARY_DIRECTORY/bin/$tool_name"
  done
  export PATH="$TEMPORARY_DIRECTORY/bin:$PATH"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT
}

# run_initiative [scripts-dir]: the initiative readout over the fixture ledger,
# priced from the distributed table beside the scripts (no --rate-table), where
# claude-aaa-1, claude-ccc-1 and claude-zzz-1 are all absent.
run_initiative() {
  bash "${1:-$SCRIPTS}/usage.sh" initiative research:net --main-root "$MAIN" --projects-root "$TEMPORARY_DIRECTORY/projects"
}

non_comment_matches() { grep -vE '^[[:space:]]*#' "$1" | grep -nE -- "$2" || true; }

# function_body <file> <name>: the function's lines, comments stripped.
function_body() {
  awk -v name="$2" '$0 ~ "^" name "\\(\\) \\{" { inside = 1 } inside { print } inside && /^\}/ { exit }' "$1" |
    grep -vE '^[[:space:]]*#' || true
}

@test "readout: an unpriced claude- model prints the lower-bound marker and calls no network tool" {
  run run_initiative
  [ "$status" -eq 0 ]
  grep -qF '  ! lower bound: unpriced model(s) claude-aaa-1, claude-ccc-1, claude-zzz-1' <<<"$output" ||
    { printf 'no unpriced marker:\n%s\n' "$output" >&2; return 1; }
  [ ! -s "$SENTINEL" ] || { printf 'a network tool was called:\n%s\n' "$(cat "$SENTINEL")" >&2; return 1; }
}

@test "static: the readout scripts name no network tool or retired rate entry point on a non-comment line" {
  local file matches checked=0
  for file in "${READOUT_FILES[@]}"; do
    [ -s "$SCRIPTS/$file" ] || { printf 'missing or empty: %s\n' "$file" >&2; return 1; }
    checked=$((checked + 1))
    matches="$(non_comment_matches "$SCRIPTS/$file" "$READOUT_PATTERN")"
    [ -z "$matches" ] || { printf '%s names a retired entry point:\n%s\n' "$file" "$matches" >&2; return 1; }
  done
  [ "$checked" -eq "${#READOUT_FILES[@]}" ]
}

@test "static: gaia_rates_load names no network tool" {
  local body
  body="$(function_body "$SCRIPTS/token-pricing-lib.sh" gaia_rates_load)"
  [ -n "$body" ] || { printf 'extracted an empty gaia_rates_load body\n' >&2; return 1; }
  grep -qF 'GAIA_RATES_JSON' <<<"$body"
  grep -qE -- "$LOAD_PATTERN" <<<"$body" && { printf 'gaia_rates_load names a network entry point:\n%s\n' "$body" >&2; return 1; }
  true
}

# library_violations <file>: every non-comment line of the pricing library that
# names a network entry point or sources another file; empty when it is clean.
library_violations() {
  non_comment_matches "$1" "$LOAD_PATTERN|$SOURCE_PATTERN"
}

@test "static: the pricing library as a whole names no network tool and sources no other file" {
  local violations
  [ -s "$SCRIPTS/token-pricing-lib.sh" ]
  violations="$(library_violations "$SCRIPTS/token-pricing-lib.sh")"
  [ -z "$violations" ] || { printf 'token-pricing-lib.sh has a network or source line:\n%s\n' "$violations" >&2; return 1; }
}

@test "guard red: a pricing library gaining a source line or a top-level curl call trips the whole-file check" {
  local scratch="$TEMPORARY_DIRECTORY/library-mutant.sh"
  cp "$SCRIPTS/token-pricing-lib.sh" "$scratch"
  [ -z "$(library_violations "$scratch")" ]
  # shellcheck disable=SC2016 # the appended line is literal text to scan, not to expand
  printf '%s\n' 'source "$(dirname "${BASH_SOURCE[0]}")/other-lib.sh" 2>/dev/null || true' >>"$scratch"
  [ -n "$(library_violations "$scratch")" ]
  cp "$SCRIPTS/token-pricing-lib.sh" "$scratch"
  printf '%s\n' 'curl -s https://example.invalid/token-rates.json >/dev/null 2>&1 || true' >>"$scratch"
  [ -n "$(library_violations "$scratch")" ]
}

# mutant_scripts <name>: a scratch copy of the scripts directory (files only, no
# suites) whose gaia_rates_load gains a curl call; sets $MUTANT_SCRIPTS.
mutant_scripts() {
  MUTANT_SCRIPTS="$TEMPORARY_DIRECTORY/mutant-$1"
  rm -rf "$MUTANT_SCRIPTS"
  mkdir -p "$MUTANT_SCRIPTS"
  find "$SCRIPTS" -maxdepth 1 -type f -exec cp {} "$MUTANT_SCRIPTS/" \;
  local lib="$MUTANT_SCRIPTS/token-pricing-lib.sh" anchor='  GAIA_RATES_OVERRIDE_STATUS=none' text
  [ "$(grep -cxF -- "$anchor" "$lib")" -eq 1 ]
  text="$(cat "$lib")"
  printf '%s\n' "${text/"$anchor"/"$anchor"$'\n'"  curl -s https://example.invalid/token-rates.json >/dev/null 2>&1 || true"}" >"$lib"
  [ "$(grep -cF -- 'curl -s https://example.invalid' "$lib")" -eq 1 ]
}

@test "guard red: a pricing lib whose gaia_rates_load calls curl trips both the behavioral and the static check" {
  mutant_scripts curl
  run run_initiative "$MUTANT_SCRIPTS"
  [ "$status" -eq 0 ]
  [ -s "$SENTINEL" ]
  grep -qE -- "$LOAD_PATTERN" <<<"$(function_body "$MUTANT_SCRIPTS/token-pricing-lib.sh" gaia_rates_load)"
}
