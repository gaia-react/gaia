#!/usr/bin/env bash
# read-audit-ci-config.sh: reader + per-author resolver for .gaia/audit-ci.yml.
#
# Two invocation forms:
#
#   read-audit-ci-config.sh
#     Argument-less emit. Resolves the config file at
#     `$(git rev-parse --show-toplevel)/.gaia/audit-ci.yml` (falls back to
#     `./.gaia/audit-ci.yml` if not in a git repo). Emits one `key=value`
#     line per known knob on stdout, in deterministic order, suitable for
#     piping into `>> $GITHUB_OUTPUT`.
#
#   read-audit-ci-config.sh --resolve-author "<login>"
#     Per-author resolve. Resolves the effective audit mode for a single
#     author login and emits the resolved decision (see "Resolve output"
#     below). Both the CI Resolve-audit-decision step and the local merge
#     path call this identical entrypoint, so the effective mode for an
#     author is deterministic and can never diverge between producers.
#
# Why a hand-rolled flat-YAML parser (no `yq`): the schema is flat scalar
# and list keys with no nesting. Pulling in `yq` adds an install step on
# every adopter's CI image and at most saves us ~20 lines of awk. If the
# schema ever grows nested values, swap the parser for `yq` without
# changing the CLI surface.
#
# Bash 3.2 compatible (macOS default). No associative arrays, no
# `mapfile`. No `cd` (per `.claude/rules/shell-cwd.md`).
#
# Emit-all output shape (always all keys, always this order):
#   gate_label=<string-or-empty>
#   budget_seconds=<integer>
#   max_turns=<integer>
#   push_fixes=<true|false>
#   default_mode=<ci|local>
#   override_label=<string>
#   audit_authors=<raw string or empty>
#   retrigger_workflows<<__GAIA_END__
#   <name-1>
#   <name-2>
#   __GAIA_END__
#
# The three new keys (`default_mode`, `override_label`, `audit_authors`)
# emit after `push_fixes` and before the `retrigger_workflows` heredoc; the
# heredoc must stay last so its multiline delimiter is not mis-parsed.
#
# The `retrigger_workflows` value uses GitHub Actions' multiline-output
# heredoc syntax so consumers receive a newline-separated string (workflow
# display names may contain spaces; single-line separators are ambiguous).
#
# Resolve output (--resolve-author):
#   resolved_mode=<ci|local>
#   should_run=<true|false>
#   (followed by the scalar key lines for caller convenience)
#
#   `resolved_mode` and `should_run` are the mandatory contract. Both CI
#   (which stands down on `local`) and the local hook (which runs locally
#   on `local`) read the SAME `resolved_mode` and interpret it for their
#   own side, so they never disagree about WHO runs.
#
#   Override-label presence is a PR property this script cannot read on its
#   own (no gh PR query here). The caller supplies it via the env var
#   `OVERRIDE_LABEL_PRESENT=true` (any case; `1`/`yes` accepted). Absent or
#   anything else → treated as not present.
#
# Resolution precedence (first-match-wins, single source of truth):
#   1. override label present → resolved_mode=ci, should_run=true.
#   2. else first matching `audit_authors` login (case-insensitive) → that
#      pair's mode.
#   3. else `default_mode`.
#
# Normalization:
#   - Login: lowercase both sides before comparison.
#   - Mode token: trim whitespace, case-fold (`CI` → `ci`, `Local ` → local).
#   - Unknown mode (`remote`, etc.) or the literal `off`: coerce to a valid
#     non-off mode by workflow presence (audit workflow file present → ci,
#     absent → local) with a stderr warning.
#   - Malformed pair (`bob=`, `=ci`, a bare token with no `=`): skip with a
#     stderr warning; do not crash; continue scanning remaining pairs.
#   - Duplicate logins: first match wins.
#
# Required-check verification + fail-closed:
#   When the resolved mode (after precedence + normalization) is `local`,
#   confirm `GAIA-Audit` is a registered required status check on the
#   default branch before honoring `local`. Confirmation honors EITHER
#   protection model: classic branch protection (`required_status_checks`
#   context) or a repository ruleset (`required_status_checks[].context`
#   under `rules/branches/<branch>`) -- see `required_check_confirmed`. The
#   ruleset read is maintainer-only (marker-wrapped, stripped at release);
#   adopters confirm via classic protection only, per `setup-gaia.md`'s
#   registration recipe. If it cannot be confirmed under either model (API
#   error, branch unprotected, context absent, `gh` absent or
#   unauthenticated, no repo slug) → fail closed: force resolved_mode=ci and
#   warn on stderr. A `ci` resolution never pays this API cost.
#
#   Exception (GitHub Actions): the confirmation's branch-protection read
#   needs admin the Actions GITHUB_TOKEN lacks (and 404s on ruleset repos),
#   so it is un-runnable in CI. Under GITHUB_ACTIONS=true a `local` resolution
#   is honored WITHOUT the re-check (unguarded it would force every local-mode
#   author into a redundant CI audit that duplicates the local run). The guard
#   stays authoritative on the local merge path, where the caller has admin.
#
# Off-coercion (argument-less emit): an invalid/`off` `default_mode` coerces
# to a valid non-off mode by workflow presence (`.github/workflows/
# code-review-audit.yml` present → ci, absent → local) with a stderr warning.
#
# Resilience:
#   - Missing file        → all defaults.
#   - Missing key         → that key's default.
#   - Commented-out key   → that key's default.
#   - Unrecognized key    → ignored (forward-compat for future knobs).
#   - Invalid integer     → default + stderr warning.
#   - Invalid boolean     → default + stderr warning.
#   - `null` (any case) for `gate_label` → empty.
#   - Empty / `null` `retrigger_workflows` → default list.
#   - Scalar in place of `retrigger_workflows` list → single-item list.
#
# Defaults when a new key is absent / commented / null:
#   - default_mode   → ci
#   - override_label → run-audit
#   - audit_authors  → empty string
#
# Exit code: 0 always. Consumers parse the output lines.

set -euo pipefail

# --- Defaults (frozen by README "Adopter config knobs (frozen)") --------------
#
# `gate_label`'s default is the empty string; it is hard-coded inline in
# the normalize/emit step rather than declared here (a constant would be
# unused; there's no fallback path that needs it because the
# normalizer's only "no value" branch already emits empty).

DEFAULT_BUDGET_SECONDS="1800"
DEFAULT_MAX_TURNS="30"
DEFAULT_PUSH_FIXES="true"
DEFAULT_DEFAULT_MODE="ci"
DEFAULT_OVERRIDE_LABEL="run-audit"
# `audit_authors`'s default is the empty string; it passes through verbatim
# so the resolver sees exactly what the adopter wrote (or nothing).
# `retrigger_workflows` ships defaulted to the GAIA template's required
# check-producing workflows (matching the `name:` field at the top of each
# YAML file). Adopters who rename or replace those workflows update the knob
# to match. Items are newline-separated because workflow display names may
# contain spaces (e.g. "Code Review Audit").
DEFAULT_RETRIGGER_WORKFLOWS="Chromatic
Tests"

# --- Parse arguments ----------------------------------------------------------
#
# No args        → emit-all path (backward-compatible).
# --resolve-author <login> → per-author resolve path.

RESOLVE_AUTHOR=0
RESOLVE_AUTHOR_LOGIN=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-author)
      RESOLVE_AUTHOR=1
      if [ "$#" -lt 2 ]; then
        echo "read-audit-ci-config: --resolve-author requires a <login> argument" >&2
        exit 2
      fi
      RESOLVE_AUTHOR_LOGIN="$2"
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
#   Strips trailing `# comment` (only when the `#` is preceded by whitespace,
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

# workflow_presence_mode
#   Echoes the valid non-off mode dictated by audit-workflow presence:
#   `.github/workflows/code-review-audit.yml` present → `ci`; absent →
#   `local`. The path is resolved against the repo root the script already
#   computes (dirname of `$config_file`'s `.gaia` parent), NOT cwd, so the
#   coercion is stable regardless of where the script is invoked from.
workflow_presence_mode() {
  local root
  if [ -n "${repo_root:-}" ]; then
    root="$repo_root"
  else
    # config_file is `<root>/.gaia/audit-ci.yml`; strip the trailing
    # `/.gaia/audit-ci.yml` to recover the root for the non-git fallback.
    root="${config_file%/.gaia/audit-ci.yml}"
    [ "$root" = "$config_file" ] && root="."
  fi
  if [ -f "$root/.github/workflows/code-review-audit.yml" ]; then
    printf 'ci'
  else
    printf 'local'
  fi
}

# normalize_mode <raw> <default> <key-name-for-warning>
#   Trim + case-fold the mode token. `ci`/`local` pass through. Empty → the
#   supplied default (silent). `off` or any unknown token → coerced to a
#   valid non-off mode by workflow presence, with a stderr warning naming
#   the coerced target.
normalize_mode() {
  local raw="$1"
  local default="$2"
  local key="$3"
  if [ -z "$raw" ]; then
    printf '%s' "$default"
    return 0
  fi
  local lower
  # Trim surrounding whitespace, then case-fold.
  lower=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    ci|local)
      printf '%s' "$lower"
      ;;
    *)
      local coerced
      coerced=$(workflow_presence_mode)
      local reason
      if [ "$lower" = "off" ]; then
        reason="is not a valid audit mode"
      else
        reason="is not a recognized audit mode"
      fi
      local presence
      if [ "$coerced" = "ci" ]; then
        presence="audit workflow present"
      else
        presence="audit workflow absent"
      fi
      echo "read-audit-ci-config: $key=$lower $reason; coercing to $coerced ($presence)" >&2
      printf '%s' "$coerced"
      ;;
  esac
}

# resolve_author_mode <login> <audit_authors-raw> <default_mode>
#   First-match-wins scan of the space-separated `login=mode` pairs.
#   Login comparison is case-insensitive. Mode token is normalized
#   (case-folded, unknown/off coerced by workflow presence). Malformed
#   pairs (`bob=`, `=ci`, a bare token with no `=`) are skipped with a
#   stderr warning. If no pair matches, falls back to <default_mode>
#   (already normalized by the caller). Echoes the resolved mode.
resolve_author_mode() {
  local login="$1"
  local raw_authors="$2"
  local default_mode="$3"

  local login_lc
  login_lc=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')

  # Iterate over whitespace-separated tokens. `set --` splits on IFS;
  # default IFS handles spaces, tabs, and newlines. `set -f` disables pathname
  # expansion first so a glob metacharacter in the value (e.g. a hand-edit typo
  # `*=local`) is never expanded against the cwd before tokenization.
  local pair pair_login pair_mode pair_login_lc
  set -f
  # shellcheck disable=SC2086
  set -- $raw_authors
  set +f
  for pair in "$@"; do
    case "$pair" in
      *=*)
        pair_login=${pair%%=*}
        pair_mode=${pair#*=}
        ;;
      *)
        echo "read-audit-ci-config: audit_authors entry '$pair' is malformed (no '=' login=mode pair); skipping" >&2
        continue
        ;;
    esac
    if [ -z "$pair_login" ]; then
      echo "read-audit-ci-config: audit_authors entry '$pair' is malformed (empty login); skipping" >&2
      continue
    fi
    if [ -z "$pair_mode" ]; then
      echo "read-audit-ci-config: audit_authors entry '$pair' is malformed (empty mode); skipping" >&2
      continue
    fi
    pair_login_lc=$(printf '%s' "$pair_login" | tr '[:upper:]' '[:lower:]')
    if [ "$pair_login_lc" = "$login_lc" ]; then
      # First match wins. Normalize the mode token (coerces unknown/off).
      normalize_mode "$pair_mode" "$default_mode" "audit_authors[$pair_login]"
      return 0
    fi
  done

  # No author pair matched → default_mode.
  printf '%s' "$default_mode"
}

# required_check_confirmed
#   Returns 0 (success) only when `GAIA-Audit` is a registered required
#   status check on the default branch, under EITHER protection model:
#   classic branch protection or a repository ruleset. Returns 1 otherwise
#   (API error, branch unprotected, context absent, `gh` absent or
#   unauthenticated, no repo slug). Callers fail closed on non-zero.
#
#   Classic protection is tried first -- this is the ONLY check an adopter
#   repo (classic protection, per setup-gaia.md) ever needs. The ruleset
#   read only runs when classic protection did not confirm; it is
#   maintainer-only and marker-wrapped so the release scrub strips it,
#   leaving the shipped adopter resolver with the classic check alone.
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
  if printf '%s\n' "$contexts" | grep -qx 'GAIA-Audit'; then
    return 0
  fi

  # gaia:maintainer-only:start
  #
  # Classic protection did not confirm -- either it 404d (a ruleset-
  # protected repo, e.g. this one) or the context is simply absent there.
  # Fall back to reading the repo's active branch rulesets:
  # `GET repos/{owner}/{repo}/rules/branches/{branch}` returns the
  # effective rules for the branch, including any ruleset-sourced
  # `required_status_checks` rule as
  # `.[] | select(.type == "required_status_checks") |
  #   .parameters.required_status_checks[].context`.
  #
  # This read only CONFIRMS the check is registered; it never registers it.
  # Registering `GAIA-Audit` on the live ruleset is a one-time,
  # maintainer-run production step (ask-first cutover command; see the
  # SPEC-034 task-enforcement-resolver notes / PROGRESS.md).
  local ruleset_contexts
  ruleset_contexts=$(gh api "repos/${repo}/rules/branches/${default_branch}" \
    --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context' \
    2>/dev/null || true)
  if printf '%s\n' "$ruleset_contexts" | grep -qx 'GAIA-Audit'; then
    return 0
  fi
  # gaia:maintainer-only:end

  return 1
}

# --- Extract + normalize ------------------------------------------------------

raw_gate_label=$(extract_raw_value "gate_label")
raw_budget_seconds=$(extract_raw_value "budget_seconds")
raw_max_turns=$(extract_raw_value "max_turns")
raw_push_fixes=$(extract_raw_value "push_fixes")
raw_default_mode=$(extract_raw_value "default_mode")
raw_override_label=$(extract_raw_value "override_label")
raw_audit_authors=$(extract_raw_value "audit_authors")
raw_retrigger_workflows=$(extract_list_value "retrigger_workflows")

gate_label=$(normalize_gate_label "$raw_gate_label")
budget_seconds=$(normalize_integer "$raw_budget_seconds" "$DEFAULT_BUDGET_SECONDS" "budget_seconds")
max_turns=$(normalize_integer "$raw_max_turns" "$DEFAULT_MAX_TURNS" "max_turns")
push_fixes=$(normalize_boolean "$raw_push_fixes" "$DEFAULT_PUSH_FIXES" "push_fixes")
# default_mode: empty → ci; invalid/off → coerced by workflow presence.
default_mode=$(normalize_mode "$raw_default_mode" "$DEFAULT_DEFAULT_MODE" "default_mode")
if [ -z "$raw_override_label" ]; then
  override_label="$DEFAULT_OVERRIDE_LABEL"
else
  override_label="$raw_override_label"
fi
# audit_authors passes through verbatim (the resolver tokenizes it).
audit_authors="$raw_audit_authors"
if [ -z "$raw_retrigger_workflows" ]; then
  retrigger_workflows="$DEFAULT_RETRIGGER_WORKFLOWS"
else
  retrigger_workflows="$raw_retrigger_workflows"
fi

# emit_scalar_keys
#   Emits the scalar key=value lines (everything except the retrigger
#   heredoc), shared between the emit-all path and the resolve path.
emit_scalar_keys() {
  printf 'gate_label=%s\n' "$gate_label"
  printf 'budget_seconds=%s\n' "$budget_seconds"
  printf 'max_turns=%s\n' "$max_turns"
  printf 'push_fixes=%s\n' "$push_fixes"
  printf 'default_mode=%s\n' "$default_mode"
  printf 'override_label=%s\n' "$override_label"
  printf 'audit_authors=%s\n' "$audit_authors"
}

# --- Dispatch: resolve path vs emit-all path ----------------------------------

if [ "$RESOLVE_AUTHOR" -eq 1 ]; then
  # --- Per-author resolve -----------------------------------------------------

  # Precedence rule 1: override label present → ci, run.
  override_present=$(normalize_boolean "${OVERRIDE_LABEL_PRESENT:-}" "false" "OVERRIDE_LABEL_PRESENT")
  if [ "$override_present" = "true" ]; then
    resolved_mode="ci"
  else
    # Rules 2 + 3: first matching author pair, else default_mode.
    resolved_mode=$(resolve_author_mode "$RESOLVE_AUTHOR_LOGIN" "$audit_authors" "$default_mode")
  fi

  # Required-check verification: only a would-be `local` resolution pays the
  # branch-protection API cost. Fail closed to `ci` when unconfirmable.
  #
  # Skipped under GitHub Actions: the confirmation reads branch protection,
  # which needs admin the Actions GITHUB_TOKEN never carries (and
  # 404s on ruleset-protected repos), so it can NEVER succeed in CI. Left
  # unguarded it forces every local-mode author into a redundant full CI audit
  # that duplicates the authoritative local run. In CI we trust the resolved
  # mode and stand down; a registered GAIA-Audit still blocks a button-merge
  # via the pending status the stand-down posts, and setup owns registering
  # that gate. The guard stays authoritative on the local merge path (the
  # other --resolve-author caller), where the invoking user has admin.
  if [ "$resolved_mode" = "local" ]; then
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      echo "read-audit-ci-config: CI context; honoring resolved local mode without the branch-protection re-check" >&2
    elif ! required_check_confirmed; then
      default_branch_for_warn=""
      if [ -n "${repo_root:-}" ]; then
        default_branch_for_warn=$(git -C "$repo_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##') || true
      fi
      [ -n "$default_branch_for_warn" ] || default_branch_for_warn="main"
      echo "read-audit-ci-config: GAIA-Audit required check not confirmed on $default_branch_for_warn; forcing ci (fail-closed)" >&2
      resolved_mode="ci"
    fi
  fi

  # should_run: true when the resolved mode means "the audit runs on the
  # producer being asked". `ci` → run; `local` → stand down (the local hook
  # runs it instead).
  if [ "$resolved_mode" = "local" ]; then
    should_run="false"
  else
    should_run="true"
  fi

  printf 'resolved_mode=%s\n' "$resolved_mode"
  printf 'should_run=%s\n' "$should_run"
  emit_scalar_keys
  exit 0
fi

# --- Emit (deterministic order) -----------------------------------------------

emit_scalar_keys
# Multiline output: GitHub Actions reads this via the `<<DELIMITER` heredoc
# syntax and exposes it as a newline-separated string. Workflow display
# names may contain spaces, so a single-line separator (space, comma) would
# be ambiguous. The heredoc stays last so its delimiter is not mis-parsed.
printf 'retrigger_workflows<<__GAIA_END__\n'
printf '%s\n' "$retrigger_workflows"
printf '__GAIA_END__\n'
