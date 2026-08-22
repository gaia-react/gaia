#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
#
# check-hook-capabilities.sh -- reconcile what every REGISTERED hook is
# DECLARED to do against what the tree actually lets it do.
#
# A `hooks` registration in .claude/settings.json is a standing, prompt-free
# grant of a different shape than a `permissions.allow` entry:
# .gaia/scripts/check-script-capabilities.sh closes the allowlisted-script
# axis, this closes the registered-hook one. The registered surface is
# arguably the sharper of the two, because a hook needs no invocation at all
# -- an allowlisted script runs when an agent decides to call it, a
# registered hook runs because Claude Code fired a trigger event, with no
# prompt and no line in any transcript that names it.
# .gaia/hook-capabilities.json declares each registered hook's real scope;
# this check holds the declaration to the code in BOTH directions --
# undeclared reach and declared-but-unreached are each a finding, so a
# blanket declaration fails on its first run. `invokes:` is the one
# exemption from the second direction: a declared target counts as reached
# by definition, so that a declaration clearing an unresolvable call never
# turns into a surplus.
#
# What this buys is detection at review time, not prevention. Nothing here
# mediates a registered hook at run time: a local session runs a widened
# hook before any CI run sees it, and the manifest itself is editable under
# a standing Edit grant. The value is that a widening becomes visible and
# has to be argued for, not that it becomes impossible.
#
# Reach is TRANSITIVE, walked by the same shared closure the allowlisted-
# script check uses: every file a hook invokes, sourced or executed,
# contributes its own reach to the caller, recursively, whether or not the
# target is itself a registered hook.
#
# Dual-mode, mirroring the repo's other check scripts: source it for the
# functions below, or run it directly.
#
#   bash .gaia/scripts/check-hook-capabilities.sh [<repo_root>]
#   bash .gaia/scripts/check-hook-capabilities.sh [<repo_root>] --print-reach [<hook>]
#
# <repo_root> defaults to `git rev-parse --show-toplevel` and is the injection
# point every test drives the check through; an argument beginning with `-` is
# never the positional. `--print-reach` is a diagnostic, not a gate: it needs
# no manifest on disk and always exits 0.
#
# Exit 0 clean, 1 on at least one finding, 2 on the check's own failure.

GAIA_HOOKCAP_MANIFEST_REL=".gaia/hook-capabilities.json"
GAIA_HOOKCAP_SCHEMA_REL=".gaia/hook-capabilities.schema.json"
GAIA_HOOKCAP_SETTINGS_REL=".claude/settings.json"
GAIA_HOOKCAP_LOCAL_SETTINGS_REL=".claude/settings.local.json"
GAIA_HOOKCAP_EXCLUDE_REL=".gaia/release-exclude"

# The static-analysis oracle -- detectors, resolution idioms, and the closure
# walk -- lives beside this file and is shared with the allowlisted-script
# check. Resolved from THIS file's own on-disk location, never cwd, so a
# fixture tree driven through <repo_root> still loads the one oracle the
# check was shipped with. Parameter expansion rather than `dirname`, so an
# empty PATH reaches the jq preflight and reports the real missing dependency
# instead of failing here first.
_gaia_hookcap_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_gaia_hookcap_lib_dir" = "${BASH_SOURCE[0]}" ] && _gaia_hookcap_lib_dir="."
_gaia_hookcap_lib_dir="$(cd "$_gaia_hookcap_lib_dir" 2>/dev/null && pwd)"
if [ -f "$_gaia_hookcap_lib_dir/capability-oracle-lib.sh" ]; then
  # shellcheck source=.gaia/scripts/capability-oracle-lib.sh
  . "$_gaia_hookcap_lib_dir/capability-oracle-lib.sh"
else
  printf 'check-hook-capabilities: capability-oracle-lib.sh is missing beside this script\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Registration readers
# ---------------------------------------------------------------------------

# _gaia_hookcap_raw_commands <settings-file>: one raw `.command` string per
# line, walking every event key, every matcher group, and every group's own
# `hooks` array -- the full command stream a `hooks` block can register.
_gaia_hookcap_raw_commands() {
  local settings="$1"
  [ -f "$settings" ] || return 0
  jq -r '(.hooks // {}) | to_entries[]? | (.value // [])[]? | (.hooks // [])[]? | .command // empty' \
    "$settings" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Manifest readers
# ---------------------------------------------------------------------------

_gaia_hookcap_manifest_hooks() {
  local m="$1/$GAIA_HOOKCAP_MANIFEST_REL"
  [ -f "$m" ] || return 0
  jq -r '.hooks[]? | .hook // empty' "$m" 2>/dev/null
}

_gaia_hookcap_declared() {
  local m="$1/$GAIA_HOOKCAP_MANIFEST_REL"
  [ -f "$m" ] || return 0
  jq -r --arg h "$2" '.hooks[]? | select(.hook == $h) | .capabilities[]?' "$m" 2>/dev/null
}

_gaia_hookcap_is_waived() {
  local m="$1/$GAIA_HOOKCAP_MANIFEST_REL"
  [ -f "$m" ] || return 1
  local hit
  hit="$(jq -r --arg h "$2" --arg c "$3" \
    '[.hooks[]? | select(.hook == $h) | (.waived // [])[] | select(.capability == $c)] | length' \
    "$m" 2>/dev/null)"
  [ -n "$hit" ] && [ "$hit" != "0" ]
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# gaia_hookcap_obligated <repo_root>
#   Prints one obligated hook path per recognized `hooks` registration
#   command, deduped, and a BAD-REGISTRATION line per registration in a form
#   the predicate cannot reduce to a repo-relative `.sh` path. Obligation is
#   per PATH, not per registration: the same hook registered at several
#   events carries one obligation, which is why the raw stream is deduped
#   before classification rather than after.
#
#   This deliberately diverges from the allowlisted-script check, which skips
#   a grant carrying no `.sh` token silently -- right there, because most
#   grants are not scripts at all. Wrong here: every `hooks` command is
#   something Claude Code executes automatically with no prompt, so the
#   moment one of them is unobligated the always-boundary this check exists
#   to hold has already failed.
gaia_hookcap_obligated() {
  local repo_root="${1:?gaia_hookcap_obligated requires a repo_root argument}"
  local settings="$repo_root/$GAIA_HOOKCAP_SETTINGS_REL"
  # A bare repo-relative .sh path: no leading /, ~ or $, no whitespace, no
  # pipe. This is what rejects the four unrecognized forms whole: a
  # $HOME-prefixed path and a ${VAR}-interpolated path both start with `$`
  # rather than the allowed leading class; a `bash -c` wrapper and a piped
  # `.sh` path both carry a space or a `|` before the terminal `.sh`.
  local bare='^[A-Za-z0-9_.][^[:space:]|]*\.sh$'
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [[ $entry =~ $bare ]]; then
      printf '%s\n' "$entry"
    else
      printf 'BAD-REGISTRATION %s\n' "$entry"
    fi
  done < <(_gaia_hookcap_raw_commands "$settings" | LC_ALL=C sort -u)
  return 0
}

_gaia_hookcap_obligated_paths() {
  gaia_hookcap_obligated "$1" | grep -v '^BAD-REGISTRATION ' || true
}

# gaia_hookcap_coverage <repo_root>
#   NO-ENTRY (an obligated hook with no manifest entry), ORPHAN (a manifest
#   entry no registration names), DUPLICATE (two entries naming the same
#   hook; never a silent last-wins).
gaia_hookcap_coverage() {
  local repo_root="${1:?gaia_hookcap_coverage requires a repo_root argument}"
  local rc=0 obligated declared h
  obligated="$(_gaia_hookcap_obligated_paths "$repo_root")"
  declared="$(_gaia_hookcap_manifest_hooks "$repo_root")"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    grep -qxF -- "$h" <<<"$declared" || { printf 'NO-ENTRY %s\n' "$h"; rc=1; }
  done <<EOF
$obligated
EOF
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    grep -qxF -- "$h" <<<"$obligated" || { printf 'ORPHAN %s\n' "$h"; rc=1; }
  done <<EOF
$declared
EOF
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    printf 'DUPLICATE %s\n' "$h"
    rc=1
  done < <(printf '%s\n' "$declared" | grep -v '^$' | LC_ALL=C sort | uniq -d)
  return $rc
}

# gaia_hookcap_schema <repo_root>
#   BAD-SCHEMA. Structural conformance of the manifest against the frozen
#   entry shape: every required key present, `maintainer_only` a boolean on
#   every entry so the marking reconciliation runs in both directions, `why`
#   non-empty, `hook` a repo-relative .sh path, `capabilities` an array, and
#   every waiver carrying both of its own required fields.
gaia_hookcap_schema() {
  local repo_root="${1:?gaia_hookcap_schema requires a repo_root argument}"
  local m="$repo_root/$GAIA_HOOKCAP_MANIFEST_REL"
  [ -f "$m" ] || return 0
  local rc=0 detail
  while IFS= read -r detail; do
    [ -n "$detail" ] || continue
    printf 'BAD-SCHEMA %s\n' "$detail"
    rc=1
  done < <(jq -r '
    def entry_label: (.hook // "<no hook key>");
    [
      (if (has("$schema") | not) then "top level is missing $schema" else empty end),
      (if (has("hooks") | not) then "top level is missing hooks" else empty end),
      (if ((.hooks // []) | length) == 0 then "hooks is empty" else empty end),
      (.hooks[]? |
        (if (has("hook") | not) then "entry is missing hook" else empty end),
        (if (has("capabilities") | not) then "\(entry_label): missing capabilities" else empty end),
        (if (has("why") | not) then "\(entry_label): missing why" else empty end),
        (if (has("maintainer_only") | not) then "\(entry_label): missing maintainer_only" else empty end),
        (if (has("maintainer_only") and ((.maintainer_only | type) != "boolean")) then "\(entry_label): maintainer_only is not a boolean" else empty end),
        (if (has("capabilities") and ((.capabilities | type) != "array")) then "\(entry_label): capabilities is not an array" else empty end),
        (if (has("why") and (((.why | type) != "string") or ((.why | length) == 0))) then "\(entry_label): why is empty" else empty end),
        (if (has("hook") and ((.hook | type != "string") or (.hook | test("^[^/~][^ ]*\\.sh$") | not))) then "\(entry_label): hook is not a repo-relative .sh path" else empty end),
        (.waived[]? |
          (if (has("capability") | not) then "waiver is missing capability" else empty end),
          (if (has("why") and (((.why | type) != "string") or ((.why | length) == 0))) then "waiver has an empty why" else empty end),
          (if (has("why") | not) then "waiver is missing why" else empty end)
        )
      )
    ] | .[]' "$m" 2>/dev/null)
  return $rc
}

# gaia_hookcap_vocabulary <repo_root>
#   BAD-TERM. The closed six-term vocabulary, plus the two rules a JSON
#   Schema pattern cannot express: an `invokes:` target carries no `..`
#   segment and names a file that exists, and an `fs-write:` glob is
#   repo-relative, well-formed, and carries a literal prefix unless it is the
#   exact `**` sentinel. Both apply to DECLARED terms only, after resolution
#   has already normalized every live target.
gaia_hookcap_vocabulary() {
  local repo_root="${1:?gaia_hookcap_vocabulary requires a repo_root argument}"
  local rc=0 h term
  while IFS=$'\t' read -r h term; do
    [ -n "$term" ] || continue
    _gaia_hookcap_term_ok "$repo_root" "$term" && continue
    printf 'BAD-TERM %s %s\n' "$h" "$term"
    rc=1
  done < <(_gaia_hookcap_all_terms "$repo_root")
  return $rc
}

_gaia_hookcap_all_terms() {
  local m="$1/$GAIA_HOOKCAP_MANIFEST_REL"
  [ -f "$m" ] || return 0
  jq -r '.hooks[]? | (.hook // "?") as $h
         | ((.capabilities // [])[], ((.waived // [])[] | .capability // empty))
         | "\($h)\t\(.)"' "$m" 2>/dev/null
}

_gaia_hookcap_term_ok() {
  local repo_root="$1" term="$2" value
  case "$term" in
    network|github-write|git-write|tmp) return 0 ;;
    fs-write:*)
      value="${term#fs-write:}"
      [ -n "$value" ] || return 1
      case "$value" in
        /*|*' '*) return 1 ;;
        ..|../*|*/../*|*/..) return 1 ;;
      esac
      # A leading `~/` is the user's home directory, the one root outside this
      # repository a hook writes into, and the term has to say so rather than
      # read as a repo-relative path. Only that spelling: a bare `~`, a
      # `~user/` form, and a `~` anywhere but position one all stay rejected,
      # so the prefix a reader can act on is unambiguous. The literal-prefix
      # rule below still applies to it, `~/.claude/projects` being the prefix.
      # The `~` is data here, a prefix inside a declared term, so it must stay
      # a literal character rather than expanding to this machine's own home
      # path; quoting it is what keeps the check portable.
      # shellcheck disable=SC2088
      case "$value" in
        '~/'?*) case "${value#'~/'}" in *'~'*) return 1 ;; esac ;;
        *'~'*) return 1 ;;
      esac
      if [ "$value" != '**' ]; then
        case "${value%%[*?[]*}" in '') return 1 ;; esac
      fi
      return 0
      ;;
    invokes:*)
      value="${term#invokes:}"
      [ -n "$value" ] || return 1
      case "$value" in
        /*|'~'*|*' '*) return 1 ;;
        ..|../*|*/../*|*/..) return 1 ;;
      esac
      [ -e "$repo_root/$value" ] || return 1
      return 0
      ;;
  esac
  return 1
}

# _gaia_hookcap_sites <repo_root> <hook>: the closure walk's records for one
# hook, with idiom 6 applied. A declared `invokes:` target that no resolved
# site already accounts for clears the hook's unresolvable INVOCATION lines;
# an unresolvable write target is untouched by it.
_gaia_hookcap_sites() {
  local repo_root="$1" hook="$2"
  local declared sites resolved unmatched d
  declared="$(_gaia_hookcap_declared "$repo_root" "$hook" | sed -n 's/^invokes://p')"
  sites="$(_gaia_capcheck_closure "$repo_root" "$hook" "$declared")"
  resolved="$(printf '%s\n' "$sites" | grep '^invokes:' | cut -f1 | sed 's/^invokes://' | LC_ALL=C sort -u)"
  unmatched=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    grep -qxF -- "$d" <<<"$resolved" || unmatched=1
  done <<EOF
$declared
EOF
  if [ "$unmatched" -eq 1 ]; then
    printf '%s\n' "$sites" | grep -v '^UNRESOLVED-CALL	'
  else
    printf '%s\n' "$sites" | sed 's/^UNRESOLVED-CALL	/UNRESOLVED	/'
  fi
  return 0
}

# gaia_hookcap_reach <repo_root> <hook>
#   The computed closure reach for one hook: one sorted, deduped capability
#   term per line, in the manifest's own spelling.
gaia_hookcap_reach() {
  local repo_root="${1:?gaia_hookcap_reach requires a repo_root argument}"
  local hook="${2:?gaia_hookcap_reach requires a hook argument}"
  _gaia_hookcap_sites "$repo_root" "$hook" \
    | grep -v '^UNRESOLVED	' \
    | cut -f1 \
    | grep -v '^$' \
    | LC_ALL=C sort -u
  return 0
}

# gaia_hookcap_reconcile <repo_root>
#   UNDECLARED / SURPLUS / UNRESOLVED over every obligated hook, in both
#   directions, with waiver suppression applied to exactly the two
#   reconciliation directions of a waived hook-capability pair.
gaia_hookcap_reconcile() {
  local repo_root="${1:?gaia_hookcap_reconcile requires a repo_root argument}"
  local rc=0 hook declared sites reached term loc line covered d
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    declared="$(_gaia_hookcap_declared "$repo_root" "$hook")"
    sites="$(_gaia_hookcap_sites "$repo_root" "$hook")"

    reached="$(printf '%s\n' "$sites" | grep -v '^UNRESOLVED	' | LC_ALL=C sort -u -t$'\t' -k1,1)"
    while IFS=$'\t' read -r term loc; do
      [ -n "$term" ] || continue
      covered=0
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$d" = "$term" ]; then covered=1; break; fi
        case "$d$term" in
          fs-write:*fs-write:*)
            [ "$d" = "fs-write:**" ] && continue
            if _gaia_capcheck_glob_match "${d#fs-write:}" "${term#fs-write:}"; then
              covered=1; break
            fi
            ;;
        esac
      done <<EOF
$declared
EOF
      [ "$covered" -eq 1 ] && continue
      _gaia_hookcap_is_waived "$repo_root" "$hook" "$term" && continue
      printf 'UNDECLARED %s %s %s\n' "$hook" "$term" "$loc"
      rc=1
    done <<EOF
$reached
EOF

    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in invokes:*) continue ;; esac
      _gaia_hookcap_term_ok "$repo_root" "$d" || continue
      covered=0
      while IFS=$'\t' read -r term loc; do
        [ -n "$term" ] || continue
        if [ "$d" = "$term" ]; then covered=1; break; fi
        case "$d$term" in
          fs-write:*fs-write:*)
            [ "$d" = "fs-write:**" ] && continue
            if _gaia_capcheck_glob_match "${d#fs-write:}" "${term#fs-write:}"; then
              covered=1; break
            fi
            ;;
        esac
      done <<EOF
$reached
EOF
      [ "$covered" -eq 1 ] && continue
      _gaia_hookcap_is_waived "$repo_root" "$hook" "$d" && continue
      printf 'SURPLUS %s %s\n' "$hook" "$d"
      rc=1
    done <<EOF
$declared
EOF

    while IFS=$'\t' read -r term loc line; do
      [ "$term" = "UNRESOLVED" ] || continue
      printf 'UNRESOLVED %s %s %s -- make the call literal, or declare invokes:<path> for the target\n' \
        "$hook" "$loc" "$line"
      rc=1
    done <<EOF
$sites
EOF
  done < <(_gaia_hookcap_obligated_paths "$repo_root")
  return $rc
}

# gaia_hookcap_marking <repo_root>
#   MARKING. `maintainer_only: true` must agree with .gaia/release-exclude
#   withholding the hook, in both directions. The exclude file is
#   PREFIX-matched on a path-component boundary, never as a raw string
#   prefix, mirroring the allowlisted-script check's own exclude parser
#   rather than inventing a second one.
gaia_hookcap_marking() {
  local repo_root="${1:?gaia_hookcap_marking requires a repo_root argument}"
  local m="$repo_root/$GAIA_HOOKCAP_MANIFEST_REL"
  [ -f "$m" ] || return 0
  local rc=0 hook declared_mo excluded
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    declared_mo="$(jq -r --arg h "$hook" \
      '[.hooks[]? | select(.hook == $h) | .maintainer_only]
        | if length == 0 then empty else (.[0] | tostring) end' "$m" 2>/dev/null)"
    [ -n "$declared_mo" ] || continue
    excluded=false
    _gaia_hookcap_is_excluded "$repo_root" "$hook" && excluded=true
    if [ "$declared_mo" != "$excluded" ]; then
      printf 'MARKING %s manifest=%s release-exclude=%s\n' "$hook" "$declared_mo" "$excluded"
      rc=1
    fi
  done < <(_gaia_hookcap_obligated_paths "$repo_root")
  return $rc
}

_gaia_hookcap_is_excluded() {
  local repo_root="$1" path="$2" line
  local file="$repo_root/$GAIA_HOOKCAP_EXCLUDE_REL"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    line="${line%/}"
    case "$path" in
      "$line"|"$line"/*) return 0 ;;
    esac
  done < "$file"
  return 1
}

# gaia_hookcap_waivers <repo_root>
#   Every live waiver, printed on passing and failing runs alike so a waiver
#   can never go quiet. WAIVER lines do not affect the exit code by
#   themselves.
gaia_hookcap_waivers() {
  local repo_root="${1:?gaia_hookcap_waivers requires a repo_root argument}"
  local m="$repo_root/$GAIA_HOOKCAP_MANIFEST_REL"
  [ -f "$m" ] || return 0
  jq -r '.hooks[]? | (.hook // "?") as $h | (.waived // [])[]
         | "WAIVER \($h) \(.capability // "?") \(.why // "")"' "$m" 2>/dev/null
  return 0
}

# gaia_hookcap_local_registrations <repo_root>
#   LOCAL-REGISTRATION, the plan-authored arm for resolved deferral 5. A
#   .claude/settings.local.json `hooks` command the committed
#   .claude/settings.json does not carry. Absent local settings is the
#   common adopter/CI case and stays silent: no finding, no diagnostic, no
#   non-zero exit. Not waivable, and it participates in no other
#   reconciliation direction -- a local registration creates no manifest
#   obligation, because the manifest is a committed artifact and the local
#   file is not.
#
#   The deregistration case, an edit removing a hook's registration and its
#   manifest entry together, is deliberately out of scope: catching it needs
#   git history, which would make the check stateful and its verdict depend
#   on the base ref.
#
#   What this arm actually buys: the local file is gitignored, so it is
#   absent on every CI runner and this arm is silent there by its own
#   contract. It is not a gated control. It surfaces a finding only on a
#   maintainer's own run, the one context where the file exists.
gaia_hookcap_local_registrations() {
  local repo_root="${1:?gaia_hookcap_local_registrations requires a repo_root argument}"
  local local_settings="$repo_root/$GAIA_HOOKCAP_LOCAL_SETTINGS_REL"
  [ -f "$local_settings" ] || return 0
  local committed rc=0 cmd
  committed="$(_gaia_hookcap_raw_commands "$repo_root/$GAIA_HOOKCAP_SETTINGS_REL" | LC_ALL=C sort -u)"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    grep -qxF -- "$cmd" <<<"$committed" || { printf 'LOCAL-REGISTRATION %s\n' "$cmd"; rc=1; }
  done < <(_gaia_hookcap_raw_commands "$local_settings" | LC_ALL=C sort -u)
  return $rc
}

# ---------------------------------------------------------------------------
# Preflight and the composed gate
# ---------------------------------------------------------------------------

# _gaia_hookcap_preflight <repo_root> <mode>: everything that is the check's
# OWN failure rather than a reconciliation finding. Returns 2 on any of them,
# so the gate can never exit 0 on a crash. The missing-manifest failure is
# scoped to gate mode; print-reach expects to run before the manifest exists.
_gaia_hookcap_preflight() {
  local repo_root="$1" mode="$2" h
  if ! command -v jq >/dev/null 2>&1; then
    printf 'check-hook-capabilities: jq not found on PATH\n' >&2
    return 2
  fi
  if [ ! -d "$repo_root" ]; then
    printf 'check-hook-capabilities: no such repo root: %s\n' "$repo_root" >&2
    return 2
  fi
  local settings="$repo_root/$GAIA_HOOKCAP_SETTINGS_REL"
  if [ ! -r "$settings" ]; then
    printf 'check-hook-capabilities: missing or unreadable %s\n' "$GAIA_HOOKCAP_SETTINGS_REL" >&2
    return 2
  fi
  if ! jq empty "$settings" >/dev/null 2>&1; then
    printf 'check-hook-capabilities: %s is not valid JSON\n' "$GAIA_HOOKCAP_SETTINGS_REL" >&2
    return 2
  fi
  if [ ! -f "$repo_root/$GAIA_HOOKCAP_EXCLUDE_REL" ]; then
    printf 'check-hook-capabilities: missing %s\n' "$GAIA_HOOKCAP_EXCLUDE_REL" >&2
    return 2
  fi
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if [ -e "$repo_root/$h" ] && [ ! -r "$repo_root/$h" ]; then
      printf 'check-hook-capabilities: unreadable obligated hook: %s\n' "$h" >&2
      return 2
    fi
  done < <(_gaia_hookcap_obligated_paths "$repo_root")
  [ "$mode" = "gate" ] || return 0
  local m="$repo_root/$GAIA_HOOKCAP_MANIFEST_REL"
  if [ ! -r "$m" ]; then
    printf 'check-hook-capabilities: missing or unreadable %s\n' "$GAIA_HOOKCAP_MANIFEST_REL" >&2
    return 2
  fi
  if ! jq empty "$m" >/dev/null 2>&1; then
    printf 'check-hook-capabilities: %s is not valid JSON\n' "$GAIA_HOOKCAP_MANIFEST_REL" >&2
    return 2
  fi
  local sch="$repo_root/$GAIA_HOOKCAP_SCHEMA_REL"
  if [ ! -r "$sch" ]; then
    printf 'check-hook-capabilities: missing or unreadable %s\n' "$GAIA_HOOKCAP_SCHEMA_REL" >&2
    return 2
  fi
  if ! jq empty "$sch" >/dev/null 2>&1; then
    printf 'check-hook-capabilities: %s is not valid JSON\n' "$GAIA_HOOKCAP_SCHEMA_REL" >&2
    return 2
  fi
  return 0
}

# gaia_check_hook_capabilities <repo_root>
#   The composed gate. 0 clean, 1 on at least one finding, 2 on the check's
#   own failure.
gaia_check_hook_capabilities() {
  local repo_root="${1:?gaia_check_hook_capabilities requires a repo_root argument}"
  _gaia_hookcap_preflight "$repo_root" gate || return 2
  local rc=0 bad
  bad="$(gaia_hookcap_obligated "$repo_root" | grep '^BAD-REGISTRATION ' || true)"
  if [ -n "$bad" ]; then printf '%s\n' "$bad"; rc=1; fi
  gaia_hookcap_coverage "$repo_root" || rc=1
  gaia_hookcap_schema "$repo_root" || rc=1
  gaia_hookcap_vocabulary "$repo_root" || rc=1
  gaia_hookcap_reconcile "$repo_root" || rc=1
  gaia_hookcap_marking "$repo_root" || rc=1
  gaia_hookcap_local_registrations "$repo_root" || rc=1
  gaia_hookcap_waivers "$repo_root"
  if [ "$rc" -eq 0 ]; then
    printf 'hook capabilities: every registered hook declares exactly the reach it has\n'
  fi
  return $rc
}

# gaia_hookcap_print_reach <repo_root> [<hook>]
#   The diagnostic. One term per line for one hook, or `<hook>\t<term>` lines
#   for every obligated hook. In the all-hooks listing a hook that reaches
#   for nothing still gets its own line, carrying a `-` sentinel, so "pure"
#   and "not enumerated" are distinguishable there. Unresolvable sites are
#   stderr diagnostics here rather than a fatal condition, and the mode
#   always exits 0.
gaia_hookcap_print_reach() {
  local repo_root="$1" only="${2:-}"
  local hook terms unres n
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    if [ -n "$only" ] && [ "$hook" != "$only" ]; then continue; fi
    local sites
    sites="$(_gaia_hookcap_sites "$repo_root" "$hook")"
    unres="$(printf '%s\n' "$sites" | grep '^UNRESOLVED	' || true)"
    if [ -n "$unres" ]; then
      printf '%s\n' "$unres" | sed "s|^UNRESOLVED\t|UNRESOLVED $hook |" >&2
    fi
    terms="$(printf '%s\n' "$sites" | grep -v '^UNRESOLVED	' | cut -f1 | grep -v '^$' | LC_ALL=C sort -u)"
    n="$(printf '%s\n' "$terms" | grep -c . || true)"
    if [ -n "$only" ]; then
      [ "$n" -gt 0 ] && printf '%s\n' "$terms"
    elif [ "$n" -gt 0 ]; then
      printf '%s\n' "$terms" | sed "s|^|$hook	|"
    else
      printf '%s\t-\n' "$hook"
    fi
  done < <(_gaia_hookcap_obligated_paths "$repo_root")
  return 0
}

_gaia_hookcap_usage() {
  cat <<'EOF'
usage: check-hook-capabilities.sh [<repo_root>]
       check-hook-capabilities.sh [<repo_root>] --print-reach [<repo-relative-hook>]

Reconciles every registered hook's declared capabilities against its actual
reach. <repo_root> defaults to the current git toplevel. --print-reach is a
diagnostic that needs no manifest and always exits 0.

Exit 0 clean, 1 on a finding, 2 on the check's own failure.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _hookcap_root=""
  _hookcap_mode="gate"
  _hookcap_target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --print-reach)
        _hookcap_mode="print-reach"
        if [ "$#" -gt 1 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
          _hookcap_target="$2"
          shift
        fi
        ;;
      -*)
        _gaia_hookcap_usage >&2
        exit 2
        ;;
      *)
        if [ -n "$_hookcap_root" ]; then
          printf 'check-hook-capabilities: unexpected argument: %s\n' "$1" >&2
          _gaia_hookcap_usage >&2
          exit 2
        fi
        _hookcap_root="$1"
        ;;
    esac
    shift
  done
  if [ -z "$_hookcap_root" ]; then
    _hookcap_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _hookcap_root=""
    if [ -z "$_hookcap_root" ]; then
      printf 'check-hook-capabilities: not a git repository and no repo_root argument given\n' >&2
      exit 2
    fi
  fi
  if [ "$_hookcap_mode" = "print-reach" ]; then
    _gaia_hookcap_preflight "$_hookcap_root" print-reach || exit 2
    gaia_hookcap_print_reach "$_hookcap_root" "$_hookcap_target"
    exit 0
  fi
  gaia_check_hook_capabilities "$_hookcap_root"
  exit $?
fi
