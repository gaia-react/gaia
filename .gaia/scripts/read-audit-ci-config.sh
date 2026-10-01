#!/usr/bin/env bash
# read-audit-ci-config.sh: reader + author resolver for .gaia/audit-ci.yml.
#
# Two invocation forms:
#
#   read-audit-ci-config.sh
#     Argument-less emit. Resolves the config file at
#     `$(git rev-parse --show-toplevel)/.gaia/audit-ci.yml` (falls back to
#     `./.gaia/audit-ci.yml` if not in a git repo). Emits the known knobs on
#     stdout, in deterministic order.
#
#   read-audit-ci-config.sh --resolve-author "<login>"
#     Resolve entrypoint kept for the callers that ask who audits a PR. Every
#     audit is local, so the answer is always `local`; see "Resolve output".
#
# Why a hand-rolled flat-YAML parser (no `yq`): the schema is flat scalar
# and list keys with no nesting. Pulling in `yq` adds an install step and at
# most saves us ~20 lines of awk. If the schema ever grows nested values,
# swap the parser for `yq` without changing the CLI surface.
#
# Bash 3.2 compatible (macOS default). No associative arrays, no
# `mapfile`. No `cd` (per `.claude/rules/shell-cwd.md`).
#
# Emit-all output shape (always all keys, always this order):
#   push_fixes=<true|false>
#   retrigger_workflows<<__GAIA_END__
#   <name-1>
#   <name-2>
#   __GAIA_END__
#
# The `retrigger_workflows` value uses a multiline heredoc so consumers
# receive a newline-separated string (workflow display names may contain
# spaces; single-line separators are ambiguous). The heredoc stays last so
# its delimiter is not mis-parsed.
#
# Resolve output (--resolve-author):
#   resolved_mode=local
#   should_run=false
#   push_fixes=<true|false>
#
#   The audit always runs on the developer's machine, so `resolved_mode` is
#   `local` whatever the config file holds, whatever files exist under
#   `.github/workflows/`, and whatever the caller's environment says. A key
#   left over from an older version of the file (a mode, an author map,
#   an override label) is ignored without a warning.
#
# Required-check confirmation, advisory only:
#   Report whether `GAIA-Audit` is a registered required status check on the
#   default branch. Confirmation honors EITHER protection model: classic
#   branch protection (`required_status_checks` context) or a repository
#   ruleset (`required_status_checks[].context` under
#   `rules/branches/<branch>`) -- see `required_check_confirmed`. Registering
#   `GAIA-Audit` remains a one-time, human-run step regardless of which model
#   confirms it. If neither model confirms (API error, branch unprotected,
#   context absent, `gh` absent or unauthenticated, no repo slug), the
#   resolver warns on stderr naming both models it tried. The warning never
#   changes `resolved_mode` and never fails the run.
#
# Resilience:
#   - Missing file        → all defaults.
#   - Missing key         → that key's default.
#   - Commented-out key   → that key's default.
#   - Unrecognized key    → ignored (forward-compat for future knobs).
#   - Invalid boolean     → default + stderr warning.
#   - Empty / `null` `retrigger_workflows` → default list.
#   - Scalar in place of `retrigger_workflows` list → single-item list.
#
# Exit code: 0 on success, 2 on a usage error. Consumers parse the output lines.

set -euo pipefail

# --- Defaults -----------------------------------------------------------------

DEFAULT_PUSH_FIXES="true"
# `retrigger_workflows` ships defaulted to the GAIA template's required
# check-producing workflows (matching the `name:` field at the top of each
# YAML file). Adopters who rename or replace those workflows update the knob
# to match. Items are newline-separated because workflow display names may
# contain spaces.
DEFAULT_RETRIGGER_WORKFLOWS="Chromatic
Tests"

# --- Parse arguments ----------------------------------------------------------
#
# No args        → emit-all path (backward-compatible).
# --resolve-author <login> → resolve path.

RESOLVE_AUTHOR=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-author)
      RESOLVE_AUTHOR=1
      if [ "$#" -lt 2 ]; then
        echo "read-audit-ci-config: --resolve-author requires a <login> argument" >&2
        exit 2
      fi
      # The login is required for the CLI surface but never read: every
      # author resolves the same way.
      shift 2
      ;;
    *)
      echo "read-audit-ci-config: unrecognized argument '$1'" >&2
      exit 2
      ;;
  esac
done

# --- Resolve the config file path --------------------------------------------

config_file=""
if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  config_file="$repo_root/.gaia/audit-ci.yml"
else
  # Defensive: not in a git repo (should never happen). Fall back
  # to the cwd-relative path.
  config_file="./.gaia/audit-ci.yml"
fi

# --- Helpers ------------------------------------------------------------------

# extract_raw_value <key>
#   Echoes the raw post-`:` value for the given key from `$config_file`,
#   or empty if the key is absent / commented out / file missing.
#
#   Matches lines of the form:    `^[[:space:]]*<key>[[:space:]]*:[[:space:]]*VALUE`
#   Strips trailing `# comment` (only when the `#` is preceded by whitespace,
#   this avoids eating a `#` that appears inside a string label like
#   `some_key: needs-review#urgent`, since YAML comment syntax requires
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
      # Strip a trailing `# comment` (only when ` #`, leading space
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

# extract_list_value <key>
#   Emits one item per line on stdout for a YAML list at the given key.
#   Supports block style (`- item` lines indented under `key:`) and flow
#   style (`key: [a, b, c]`). Items are trimmed and unquoted. A scalar
#   value in place of a list is treated as a single-item list (forward
#   compatibility for adopters who write `retrigger_workflows: Chromatic`).
#   Empty / `null` / `~` value with no block items emits nothing → caller
#   substitutes the default.
extract_list_value() {
  local key="$1"
  [ -f "$config_file" ] || return 0
  awk -v key="$key" '
    function strip_quotes(s) {
      if (s ~ /^".*"$/) return substr(s, 2, length(s) - 2)
      if (s ~ /^'\''.*'\''$/) return substr(s, 2, length(s) - 2)
      return s
    }
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    BEGIN { in_list = 0 }
    {
      line = $0
      if (in_list == 1) {
        # Block-style list item: `<indent>- <value>`.
        if (line ~ /^[[:space:]]+-[[:space:]]+/) {
          item = line
          sub(/^[[:space:]]+-[[:space:]]+/, "", item)
          sub(/[[:space:]]+#.*$/, "", item)
          item = trim(item)
          item = strip_quotes(item)
          if (item != "") print item
          next
        }
        # Blank lines and comments are tolerated mid-list.
        if (line ~ /^[[:space:]]*$/) next
        if (line ~ /^[[:space:]]*#/) next
        # Anything else (next key or unrelated content) ends the list.
        exit
      }
      pattern = "^[[:space:]]*" key "[[:space:]]*:"
      if (line !~ pattern) next
      sub(pattern, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      line = trim(line)
      # Flow style: `[a, b, c]`.
      if (line ~ /^\[.*\]$/) {
        inside = substr(line, 2, length(line) - 2)
        n = split(inside, parts, ",")
        for (i = 1; i <= n; i++) {
          item = strip_quotes(trim(parts[i]))
          if (item != "") print item
        }
        exit
      }
      # Empty / null / ~ → look for block-style items on subsequent lines.
      lower = tolower(line)
      if (line == "" || lower == "null" || line == "~") {
        in_list = 1
        next
      }
      # Scalar where a list was expected; accept as a single-item list.
      print strip_quotes(line)
      exit
    }
  ' "$config_file"
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


# required_check_confirmed
#   Returns 0 (success) only when `GAIA-Audit` is a registered required
#   status check on the default branch, under EITHER protection model:
#   classic branch protection or a repository ruleset. Returns 1 otherwise
#   (API error, branch unprotected, context absent, `gh` absent or
#   unauthenticated, no repo slug). Callers treat a non-zero return as
#   advisory-only: they warn, and never change the resolved mode.
#
#   Classic protection is tried first -- this is the ONLY check an adopter
#   repo (classic protection, per setup-gaia.md) ever needs. The ruleset
#   read only runs when classic protection did not confirm, and it ships to
#   adopters too, so a repository whose protection is a ruleset rather than
#   classic branch protection still confirms correctly.
#
#   Default branch: resolved from `origin/HEAD`, falling back to `main`.
#   Repo slug: `$GITHUB_REPOSITORY` if set, else `gh repo view`.
required_check_confirmed() {
  command -v gh >/dev/null 2>&1 || return 1

  local repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then
    repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
  fi
  [ -n "$repo" ] || return 1

  local default_branch=""
  if [ -n "${repo_root:-}" ]; then
    default_branch=$(git -C "$repo_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##') || true
  fi
  [ -n "$default_branch" ] || default_branch="main"

  local contexts
  contexts=$(gh api "repos/${repo}/branches/${default_branch}/protection/required_status_checks" \
    --jq '.contexts[]?' 2>/dev/null || true)
  if grep -qx 'GAIA-Audit' <<<"$contexts"; then
    return 0
  fi

  #
  # Classic protection did not confirm -- either it 404d (this happens on a
  # ruleset-protected repository) or the context is simply absent there.
  # Fall back to reading the repo's active branch rulesets:
  # `GET repos/{owner}/{repo}/rules/branches/{branch}` returns the
  # effective rules for the branch, including any ruleset-sourced
  # `required_status_checks` rule as
  # `.[] | select(.type == "required_status_checks") |
  #   .parameters.required_status_checks[].context`.
  #
  # This read only CONFIRMS the check is registered; it never registers it.
  # Registering `GAIA-Audit` on the live ruleset stays a one-time, human-run
  # step, exactly as it does under classic branch protection.
  local ruleset_contexts
  ruleset_contexts=$(gh api "repos/${repo}/rules/branches/${default_branch}" \
    --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context' \
    2>/dev/null || true)
  if grep -qx 'GAIA-Audit' <<<"$ruleset_contexts"; then
    return 0
  fi

  return 1
}


# --- Extract + normalize ------------------------------------------------------

raw_push_fixes=$(extract_raw_value "push_fixes")
raw_retrigger_workflows=$(extract_list_value "retrigger_workflows")

push_fixes=$(normalize_boolean "$raw_push_fixes" "$DEFAULT_PUSH_FIXES" "push_fixes")
if [ -z "$raw_retrigger_workflows" ]; then
  retrigger_workflows="$DEFAULT_RETRIGGER_WORKFLOWS"
else
  retrigger_workflows="$raw_retrigger_workflows"
fi

# --- Dispatch: resolve path vs emit-all path ----------------------------------

if [ "$RESOLVE_AUTHOR" -eq 1 ]; then
  # Every audit is local: the answer does not depend on the login, the file,
  # or the environment.
  if ! required_check_confirmed; then
    default_branch_for_warn=""
    if [ -n "${repo_root:-}" ]; then
      default_branch_for_warn=$(git -C "$repo_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##') || true
    fi
    [ -n "$default_branch_for_warn" ] || default_branch_for_warn="main"
    echo "read-audit-ci-config: GAIA-Audit registration not confirmed on $default_branch_for_warn (tried classic branch protection and the repository ruleset); resolved_mode is unchanged" >&2
  fi

  printf 'resolved_mode=local\n'
  printf 'should_run=false\n'
  printf 'push_fixes=%s\n' "$push_fixes"
  exit 0
fi

# --- Emit (deterministic order) -----------------------------------------------

printf 'push_fixes=%s\n' "$push_fixes"
printf 'retrigger_workflows<<__GAIA_END__\n'
printf '%s\n' "$retrigger_workflows"
printf '__GAIA_END__\n'
