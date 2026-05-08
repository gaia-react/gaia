#!/usr/bin/env bash
# read-audit-ci-config.sh — reader for .gaia/audit-ci.yml.
#
# Argument-less. Resolves the config file at
# `$(git rev-parse --show-toplevel)/.gaia/audit-ci.yml` (falls back to
# `./.gaia/audit-ci.yml` if not in a git repo). Emits one `key=value`
# line per known knob on stdout, in deterministic order, suitable for
# piping into `>> $GITHUB_OUTPUT`.
#
# Why a hand-rolled flat-YAML parser (no `yq`): the schema is four
# scalar keys with no nesting and no quoting edge-cases. Pulling in
# `yq` adds an install step on every adopter's CI image and at most
# saves us ~20 lines of awk. The frozen contract in
# `.gaia/local/plans/code-review-audit-ci/README.md` documents the
# four keys; if the schema ever grows nested values, swap the parser
# for `yq` without changing the CLI surface.
#
# Bash 3.2 compatible (macOS default). No associative arrays, no
# `mapfile`. No `cd` (per `.claude/rules/shell-cwd.md`).
#
# Output shape (always all four lines, always this order):
#   gate_label=<string-or-empty>
#   budget_seconds=<integer>
#   max_turns=<integer>
#   push_fixes=<true|false>
#
# Resilience:
#   - Missing file        → all defaults.
#   - Missing key         → that key's default.
#   - Commented-out key   → that key's default.
#   - Unrecognized key    → ignored (forward-compat for future knobs).
#   - Invalid integer     → default + stderr warning.
#   - Invalid boolean     → default + stderr warning.
#   - `null` (any case) for `gate_label` → empty.
#
# Exit code: 0 always. Consumers parse the four output lines.

set -euo pipefail

# --- Defaults (frozen by README "Adopter config knobs (frozen)") --------------
#
# `gate_label`'s default is the empty string; it is hard-coded inline in
# the normalize/emit step rather than declared here (a constant would be
# unused — there's no fallback path that needs it because the
# normalizer's only "no value" branch already emits empty).

DEFAULT_BUDGET_SECONDS="1800"
DEFAULT_MAX_TURNS="30"
DEFAULT_PUSH_FIXES="true"

# --- Resolve the config file path --------------------------------------------

config_file=""
if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  config_file="$repo_root/.gaia/audit-ci.yml"
else
  # Defensive: not in a git repo (should never happen in CI). Fall back
  # to the cwd-relative path.
  config_file="./.gaia/audit-ci.yml"
fi

# --- Helpers ------------------------------------------------------------------

# extract_raw_value <key>
#   Echoes the raw post-`:` value for the given key from `$config_file`,
#   or empty if the key is absent / commented out / file missing.
#
#   Matches lines of the form:    `^[[:space:]]*<key>[[:space:]]*:[[:space:]]*VALUE`
#   Strips trailing `# comment` (only when the `#` is preceded by whitespace —
#   this avoids eating a `#` that appears inside a string label like
#   `gate_label: needs-review#urgent`, since YAML comment syntax requires
#   a leading space before the `#`).
#   Trims leading/trailing whitespace.
#   Strips surrounding single or double quotes.
#   First match wins (later duplicates ignored).
extract_raw_value() {
  local key="$1"
  [ -f "$config_file" ] || { printf ''; return 0; }

  awk -v key="$key" '
    BEGIN { found = 0 }
    found == 1 { next }
    {
      line = $0
      # Skip blank lines and full-line comments.
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*#/) next
      # Match `<spaces><key><spaces>:<rest>`.
      pattern = "^[[:space:]]*" key "[[:space:]]*:"
      if (line !~ pattern) next
      # Strip the key + colon prefix.
      sub(pattern, "", line)
      # Strip a trailing `# comment` (only when ` #` — leading space
      # required, per YAML comment rules; this preserves `#` inside
      # unquoted string values like `foo#bar`).
      sub(/[[:space:]]+#.*$/, "", line)
      # Trim leading/trailing whitespace.
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      # Strip surrounding double or single quotes.
      if (line ~ /^".*"$/) {
        line = substr(line, 2, length(line) - 2)
      } else if (line ~ /^'\''.*'\''$/) {
        line = substr(line, 2, length(line) - 2)
      }
      print line
      found = 1
    }
  ' "$config_file"
}

# normalize_gate_label <raw>
#   Empty / `null` (any case) → empty. Anything else → as-is.
normalize_gate_label() {
  local raw="$1"
  if [ -z "$raw" ]; then
    printf ''
    return 0
  fi
  # Lowercase compare for `null`.
  local lower
  lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  if [ "$lower" = "null" ] || [ "$lower" = "~" ]; then
    printf ''
    return 0
  fi
  printf '%s' "$raw"
}

# normalize_integer <raw> <default> <key-name-for-warning>
normalize_integer() {
  local raw="$1"
  local default="$2"
  local key="$3"
  if [ -z "$raw" ]; then
    printf '%s' "$default"
    return 0
  fi
  case "$raw" in
    ''|*[!0-9]*)
      echo "read-audit-ci-config: $key=$raw is not a non-negative integer; using default $default" >&2
      printf '%s' "$default"
      ;;
    *)
      printf '%s' "$raw"
      ;;
  esac
}

# normalize_boolean <raw> <default> <key-name-for-warning>
#   Accepts: true/True/TRUE/yes/Yes/YES/1 → true
#            false/False/FALSE/no/No/NO/0 → false
#            empty                        → default (silent)
#            anything else                → default (with stderr warning)
normalize_boolean() {
  local raw="$1"
  local default="$2"
  local key="$3"
  if [ -z "$raw" ]; then
    printf '%s' "$default"
    return 0
  fi
  local lower
  lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    true|yes|1)
      printf 'true'
      ;;
    false|no|0)
      printf 'false'
      ;;
    *)
      echo "read-audit-ci-config: $key=$raw is not a recognized boolean; using default $default" >&2
      printf '%s' "$default"
      ;;
  esac
}

# --- Extract + normalize ------------------------------------------------------

raw_gate_label=$(extract_raw_value "gate_label")
raw_budget_seconds=$(extract_raw_value "budget_seconds")
raw_max_turns=$(extract_raw_value "max_turns")
raw_push_fixes=$(extract_raw_value "push_fixes")

gate_label=$(normalize_gate_label "$raw_gate_label")
budget_seconds=$(normalize_integer "$raw_budget_seconds" "$DEFAULT_BUDGET_SECONDS" "budget_seconds")
max_turns=$(normalize_integer "$raw_max_turns" "$DEFAULT_MAX_TURNS" "max_turns")
push_fixes=$(normalize_boolean "$raw_push_fixes" "$DEFAULT_PUSH_FIXES" "push_fixes")

# --- Emit (deterministic order) -----------------------------------------------

printf 'gate_label=%s\n' "$gate_label"
printf 'budget_seconds=%s\n' "$budget_seconds"
printf 'max_turns=%s\n' "$max_turns"
printf 'push_fixes=%s\n' "$push_fixes"
