#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
#
# check-script-capabilities.sh -- reconcile what every allowlisted GAIA script
# is DECLARED to do against what the tree actually lets it do.
#
# A `permissions.allow` entry in .claude/settings.json that names a GAIA script
# is a standing, prompt-free grant, and its real scope is whatever that script
# does at the moment it runs. .gaia/script-capabilities.json declares that
# scope; this check holds the declaration to the code in BOTH directions --
# undeclared reach and declared-but-unreached are each a finding, so a blanket
# declaration fails on its first run.
#
# What this buys is detection at review time, not prevention. Nothing here
# mediates what a pre-approved script does once it runs: a local session
# executes a widened script before any CI run sees it, and the manifest itself
# is editable under a standing Edit grant. The value is that a widening becomes
# visible and has to be argued for, not that it becomes impossible.
#
# Reach is TRANSITIVE. An allowlisted script's own lines are only half of it:
# every script it invokes, sourced or executed, contributes its own reach to the
# caller, recursively, whether or not the target is itself allowlisted. The
# repository carries the case that motivates this -- a local-file writer that
# reaches an authenticated commit-status POST through one variable-target hook
# invocation, which a purely lexical scan of the allowlisted script reports
# clean.
#
# Dual-mode, mirroring the repo's other check scripts: source it for the
# functions below, or run it directly.
#
#   bash .gaia/scripts/check-script-capabilities.sh [<repo_root>]
#   bash .gaia/scripts/check-script-capabilities.sh [<repo_root>] --print-reach [<script>]
#
# <repo_root> defaults to `git rev-parse --show-toplevel` and is the injection
# point every test drives the check through; an argument beginning with `-` is
# never the positional. `--print-reach` is a diagnostic, not a gate: it needs no
# manifest on disk and always exits 0.
#
# Exit 0 clean, 1 on at least one finding, 2 on the check's own failure.

GAIA_CAPCHECK_MANIFEST_REL=".gaia/script-capabilities.json"
GAIA_CAPCHECK_SCHEMA_REL=".gaia/script-capabilities.schema.json"
GAIA_CAPCHECK_SETTINGS_REL=".claude/settings.json"
GAIA_CAPCHECK_EXCLUDE_REL=".gaia/release-exclude"

# The static-analysis oracle -- detectors, resolution idioms, and the closure
# walk -- lives beside this file. Resolved from THIS file's own on-disk
# location, never cwd, so a fixture tree driven through <repo_root> still loads
# the one oracle the check was shipped with. Parameter expansion rather than
# `dirname`, so an empty PATH reaches the jq preflight and reports the real
# missing dependency instead of failing here first.
_gaia_capcheck_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_gaia_capcheck_lib_dir" = "${BASH_SOURCE[0]}" ] && _gaia_capcheck_lib_dir="."
_gaia_capcheck_lib_dir="$(cd "$_gaia_capcheck_lib_dir" 2>/dev/null && pwd)"
if [ -f "$_gaia_capcheck_lib_dir/capability-oracle-lib.sh" ]; then
  # shellcheck source=.gaia/scripts/capability-oracle-lib.sh
  . "$_gaia_capcheck_lib_dir/capability-oracle-lib.sh"
else
  printf 'check-script-capabilities: capability-oracle-lib.sh is missing beside this script\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Manifest readers
# ---------------------------------------------------------------------------

_gaia_capcheck_manifest_scripts() {
  local m="$1/$GAIA_CAPCHECK_MANIFEST_REL"
  [ -f "$m" ] || return 0
  jq -r '.scripts[]? | .script // empty' "$m" 2>/dev/null
}

_gaia_capcheck_declared() {
  local m="$1/$GAIA_CAPCHECK_MANIFEST_REL"
  [ -f "$m" ] || return 0
  jq -r --arg s "$2" '.scripts[]? | select(.script == $s) | .capabilities[]?' "$m" 2>/dev/null
}

_gaia_capcheck_is_waived() {
  local m="$1/$GAIA_CAPCHECK_MANIFEST_REL"
  [ -f "$m" ] || return 1
  local hit
  hit="$(jq -r --arg s "$2" --arg c "$3" \
    '[.scripts[]? | select(.script == $s) | (.waived // [])[] | select(.capability == $c)] | length' \
    "$m" 2>/dev/null)"
  [ -n "$hit" ] && [ "$hit" != "0" ]
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# gaia_capcheck_obligated <repo_root>
#   C-5. Prints one obligated script path per recognized `permissions.allow`
#   grant, and a BAD-GRANT line per allow entry that names a `.sh` path in an
#   unrecognized form. An entry with no `.sh`-terminated token carries no
#   obligation and is skipped silently -- most entries contain the letters
#   `sh` inside the word `bash`, which is not a path.
gaia_capcheck_obligated() {
  local repo_root="${1:?gaia_capcheck_obligated requires a repo_root argument}"
  local settings="$repo_root/$GAIA_CAPCHECK_SETTINGS_REL"
  local grant='^Bash\(bash ([^ )]+\.sh):\*\)$'
  local dotsh='\.sh([^A-Za-z0-9]|$)'
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [[ $entry =~ $grant ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      continue
    fi
    [[ $entry =~ $dotsh ]] && printf 'BAD-GRANT %s\n' "$entry"
  done < <(jq -r '.permissions.allow[]?' "$settings" 2>/dev/null)
  return 0
}

_gaia_capcheck_obligated_paths() {
  gaia_capcheck_obligated "$1" | grep -v '^BAD-GRANT ' || true
}

# gaia_capcheck_coverage <repo_root>
#   NO-ENTRY (an obligated script with no manifest entry), ORPHAN (a manifest
#   entry no allow grant names), DUPLICATE (two entries naming the same
#   script; never a silent last-wins).
gaia_capcheck_coverage() {
  local repo_root="${1:?gaia_capcheck_coverage requires a repo_root argument}"
  local rc=0 obligated declared s
  obligated="$(_gaia_capcheck_obligated_paths "$repo_root")"
  declared="$(_gaia_capcheck_manifest_scripts "$repo_root")"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qxF -- "$s" <<<"$declared" || { printf 'NO-ENTRY %s\n' "$s"; rc=1; }
  done <<EOF
$obligated
EOF
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qxF -- "$s" <<<"$obligated" || { printf 'ORPHAN %s\n' "$s"; rc=1; }
  done <<EOF
$declared
EOF
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    printf 'DUPLICATE %s\n' "$s"
    rc=1
  done < <(printf '%s\n' "$declared" | grep -v '^$' | LC_ALL=C sort | uniq -d)
  return $rc
}

# gaia_capcheck_schema <repo_root>
#   BAD-SCHEMA. Structural conformance of the manifest against the frozen
#   entry shape: every required key present, `maintainer_only` a boolean on
#   every entry so the marking reconciliation runs in both directions, `why`
#   non-empty, `script` a repo-relative .sh path, `capabilities` an array, and
#   every waiver carrying both of its own required fields.
gaia_capcheck_schema() {
  local repo_root="${1:?gaia_capcheck_schema requires a repo_root argument}"
  local m="$repo_root/$GAIA_CAPCHECK_MANIFEST_REL"
  [ -f "$m" ] || return 0
  local rc=0 detail
  while IFS= read -r detail; do
    [ -n "$detail" ] || continue
    printf 'BAD-SCHEMA %s\n' "$detail"
    rc=1
  done < <(jq -r '
    def entry_label: (.script // "<no script key>");
    [
      (if (has("$schema") | not) then "top level is missing $schema" else empty end),
      (if (has("scripts") | not) then "top level is missing scripts" else empty end),
      (if ((.scripts // []) | length) == 0 then "scripts is empty" else empty end),
      (.scripts[]? |
        (if (has("script") | not) then "entry is missing script" else empty end),
        (if (has("capabilities") | not) then "\(entry_label): missing capabilities" else empty end),
        (if (has("why") | not) then "\(entry_label): missing why" else empty end),
        (if (has("maintainer_only") | not) then "\(entry_label): missing maintainer_only" else empty end),
        (if (has("maintainer_only") and ((.maintainer_only | type) != "boolean")) then "\(entry_label): maintainer_only is not a boolean" else empty end),
        (if (has("capabilities") and ((.capabilities | type) != "array")) then "\(entry_label): capabilities is not an array" else empty end),
        (if (has("why") and (((.why | type) != "string") or ((.why | length) == 0))) then "\(entry_label): why is empty" else empty end),
        (if (has("script") and ((.script | type != "string") or (.script | test("^[^/~][^ ]*\\.sh$") | not))) then "\(entry_label): script is not a repo-relative .sh path" else empty end),
        (.waived[]? |
          (if (has("capability") | not) then "waiver is missing capability" else empty end),
          (if (has("why") and (((.why | type) != "string") or ((.why | length) == 0))) then "waiver has an empty why" else empty end),
          (if (has("why") | not) then "waiver is missing why" else empty end)
        )
      )
    ] | .[]' "$m" 2>/dev/null)
  return $rc
}

# gaia_capcheck_vocabulary <repo_root>
#   BAD-TERM. The closed six-term vocabulary, plus the two rules a JSON Schema
#   pattern cannot express: an `invokes:` target carries no `..` segment and
#   names a file that exists, and an `fs-write:` glob is repo-relative and
#   well-formed. Both apply to DECLARED terms only, after resolution has
#   already normalized every live target, so a `..`-bearing invocation site
#   stays declarable while a `..`-bearing declaration is rejected.
gaia_capcheck_vocabulary() {
  local repo_root="${1:?gaia_capcheck_vocabulary requires a repo_root argument}"
  local rc=0 s term
  while IFS=$'\t' read -r s term; do
    [ -n "$term" ] || continue
    _gaia_capcheck_term_ok "$repo_root" "$term" && continue
    printf 'BAD-TERM %s %s\n' "$s" "$term"
    rc=1
  done < <(_gaia_capcheck_all_terms "$repo_root")
  return $rc
}

_gaia_capcheck_all_terms() {
  local m="$1/$GAIA_CAPCHECK_MANIFEST_REL"
  [ -f "$m" ] || return 0
  jq -r '.scripts[]? | (.script // "?") as $s
         | ((.capabilities // [])[], ((.waived // [])[] | .capability // empty))
         | "\($s)\t\(.)"' "$m" 2>/dev/null
}

_gaia_capcheck_term_ok() {
  local repo_root="$1" term="$2" value
  case "$term" in
    network|github-write|git-write|tmp) return 0 ;;
    fs-write:*)
      value="${term#fs-write:}"
      [ -n "$value" ] || return 1
      case "$value" in
        /*|'~'*|*' '*) return 1 ;;
        ..|../*|*/../*|*/..) return 1 ;;
      esac
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

# _gaia_capcheck_sites <repo_root> <script>: the closure walk's records for one
# script, with idiom 6 applied. A declared `invokes:` target that no resolved
# site already accounts for clears the script's unresolvable INVOCATION lines,
# which is what makes "declare the target" a real second route out of an
# UNRESOLVED finding rather than a route into a SURPLUS one. It clears
# invocation lines only: an unresolvable write target is untouched by it.
#
# The clearing is per script rather than per line, because an unresolvable
# token is by definition not matchable against a declared path. A script with
# one declared-but-unresolved target and two unresolvable call sites therefore
# clears both, which is the coarseness this route costs.
_gaia_capcheck_sites() {
  local repo_root="$1" script="$2"
  local declared sites resolved unmatched d
  declared="$(_gaia_capcheck_declared "$repo_root" "$script" | sed -n 's/^invokes://p')"
  sites="$(_gaia_capcheck_closure "$repo_root" "$script" "$declared")"
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

# gaia_capcheck_reach <repo_root> <script>
#   The computed closure reach for one script: one sorted, deduped capability
#   term per line, in the manifest's own spelling.
gaia_capcheck_reach() {
  local repo_root="${1:?gaia_capcheck_reach requires a repo_root argument}"
  local script="${2:?gaia_capcheck_reach requires a script argument}"
  _gaia_capcheck_sites "$repo_root" "$script" \
    | grep -v '^UNRESOLVED	' \
    | cut -f1 \
    | grep -v '^$' \
    | LC_ALL=C sort -u
  return 0
}

# gaia_capcheck_reconcile <repo_root>
#   UNDECLARED / SURPLUS / UNRESOLVED over every obligated script, in both
#   directions, with waiver suppression applied to exactly the two
#   reconciliation directions of a waived script-capability pair.
gaia_capcheck_reconcile() {
  local repo_root="${1:?gaia_capcheck_reconcile requires a repo_root argument}"
  local rc=0 script declared sites reached term loc line covered d
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    declared="$(_gaia_capcheck_declared "$repo_root" "$script")"
    sites="$(_gaia_capcheck_sites "$repo_root" "$script")"

    # Undeclared reach, attributed to the allowlisted caller and located at the
    # line that reaches for it, which for a transitively-reached capability is
    # a line in the invoked file.
    reached="$(printf '%s\n' "$sites" | grep -v '^UNRESOLVED	' | LC_ALL=C sort -u -t$'\t' -k1,1)"
    while IFS=$'\t' read -r term loc; do
      [ -n "$term" ] || continue
      covered=0
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$d" = "$term" ]; then covered=1; break; fi
        case "$d$term" in
          fs-write:*fs-write:*)
            if _gaia_capcheck_glob_match "${d#fs-write:}" "${term#fs-write:}"; then
              covered=1; break
            fi
            ;;
        esac
      done <<EOF
$declared
EOF
      [ "$covered" -eq 1 ] && continue
      _gaia_capcheck_is_waived "$repo_root" "$script" "$term" && continue
      printf 'UNDECLARED %s %s %s\n' "$script" "$term" "$loc"
      rc=1
    done <<EOF
$reached
EOF

    # Declared but unreached. A declared `invokes:` target counts as reached by
    # definition, so clearing an unresolvable line by declaring its target
    # never turns that declaration into a surplus finding.
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in invokes:*) continue ;; esac
      _gaia_capcheck_term_ok "$repo_root" "$d" || continue
      covered=0
      while IFS=$'\t' read -r term loc; do
        [ -n "$term" ] || continue
        if [ "$d" = "$term" ]; then covered=1; break; fi
        case "$d$term" in
          fs-write:*fs-write:*)
            if _gaia_capcheck_glob_match "${d#fs-write:}" "${term#fs-write:}"; then
              covered=1; break
            fi
            ;;
        esac
      done <<EOF
$reached
EOF
      [ "$covered" -eq 1 ] && continue
      _gaia_capcheck_is_waived "$repo_root" "$script" "$d" && continue
      printf 'SURPLUS %s %s\n' "$script" "$d"
      rc=1
    done <<EOF
$declared
EOF

    # Indecision is a finding. The text names both routes that clear it.
    while IFS=$'\t' read -r term loc line; do
      [ "$term" = "UNRESOLVED" ] || continue
      printf 'UNRESOLVED %s %s %s -- make the call literal, or declare invokes:<path> for the target\n' \
        "$script" "$loc" "$line"
      rc=1
    done <<EOF
$sites
EOF
  done < <(_gaia_capcheck_obligated_paths "$repo_root")
  return $rc
}

# gaia_capcheck_marking <repo_root>
#   MARKING (C-10). `maintainer_only: true` must agree with
#   .gaia/release-exclude withholding the script, in both directions. The
#   exclude file is PREFIX-matched on a path-component boundary, never as a
#   raw string prefix: a line withholds a path when the path equals it or
#   begins with it plus `/`.
gaia_capcheck_marking() {
  local repo_root="${1:?gaia_capcheck_marking requires a repo_root argument}"
  local m="$repo_root/$GAIA_CAPCHECK_MANIFEST_REL"
  [ -f "$m" ] || return 0
  local rc=0 script declared_mo excluded
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    declared_mo="$(jq -r --arg s "$script" \
      '[.scripts[]? | select(.script == $s) | .maintainer_only]
        | if length == 0 then empty else (.[0] | tostring) end' "$m" 2>/dev/null)"
    [ -n "$declared_mo" ] || continue
    excluded=false
    _gaia_capcheck_is_excluded "$repo_root" "$script" && excluded=true
    if [ "$declared_mo" != "$excluded" ]; then
      printf 'MARKING %s manifest=%s release-exclude=%s\n' "$script" "$declared_mo" "$excluded"
      rc=1
    fi
  done < <(_gaia_capcheck_obligated_paths "$repo_root")
  return $rc
}

_gaia_capcheck_is_excluded() {
  local repo_root="$1" path="$2" line
  local file="$repo_root/$GAIA_CAPCHECK_EXCLUDE_REL"
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

# gaia_capcheck_waivers <repo_root>
#   Every live waiver, printed on passing and failing runs alike so a waiver
#   can never go quiet. WAIVER lines do not affect the exit code by
#   themselves.
gaia_capcheck_waivers() {
  local repo_root="${1:?gaia_capcheck_waivers requires a repo_root argument}"
  local m="$repo_root/$GAIA_CAPCHECK_MANIFEST_REL"
  [ -f "$m" ] || return 0
  jq -r '.scripts[]? | (.script // "?") as $s | (.waived // [])[]
         | "WAIVER \($s) \(.capability // "?") \(.why // "")"' "$m" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Preflight and the composed gate
# ---------------------------------------------------------------------------

# _gaia_capcheck_preflight <repo_root> <mode>: everything that is the check's
# OWN failure rather than a reconciliation finding. Returns 2 on any of them,
# so the gate can never exit 0 on a crash. The missing-manifest failure is
# scoped to gate mode; print-reach expects to run before the manifest exists.
_gaia_capcheck_preflight() {
  local repo_root="$1" mode="$2" s
  if ! command -v jq >/dev/null 2>&1; then
    printf 'check-script-capabilities: jq not found on PATH\n' >&2
    return 2
  fi
  if [ ! -d "$repo_root" ]; then
    printf 'check-script-capabilities: no such repo root: %s\n' "$repo_root" >&2
    return 2
  fi
  local settings="$repo_root/$GAIA_CAPCHECK_SETTINGS_REL"
  if [ ! -r "$settings" ]; then
    printf 'check-script-capabilities: missing or unreadable %s\n' "$GAIA_CAPCHECK_SETTINGS_REL" >&2
    return 2
  fi
  if ! jq empty "$settings" >/dev/null 2>&1; then
    printf 'check-script-capabilities: %s is not valid JSON\n' "$GAIA_CAPCHECK_SETTINGS_REL" >&2
    return 2
  fi
  if [ ! -f "$repo_root/$GAIA_CAPCHECK_EXCLUDE_REL" ]; then
    printf 'check-script-capabilities: missing %s\n' "$GAIA_CAPCHECK_EXCLUDE_REL" >&2
    return 2
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ -e "$repo_root/$s" ] && [ ! -r "$repo_root/$s" ]; then
      printf 'check-script-capabilities: unreadable obligated script: %s\n' "$s" >&2
      return 2
    fi
  done < <(_gaia_capcheck_obligated_paths "$repo_root")
  [ "$mode" = "gate" ] || return 0
  local m="$repo_root/$GAIA_CAPCHECK_MANIFEST_REL"
  if [ ! -r "$m" ]; then
    printf 'check-script-capabilities: missing or unreadable %s\n' "$GAIA_CAPCHECK_MANIFEST_REL" >&2
    return 2
  fi
  if ! jq empty "$m" >/dev/null 2>&1; then
    printf 'check-script-capabilities: %s is not valid JSON\n' "$GAIA_CAPCHECK_MANIFEST_REL" >&2
    return 2
  fi
  local sch="$repo_root/$GAIA_CAPCHECK_SCHEMA_REL"
  if [ ! -r "$sch" ]; then
    printf 'check-script-capabilities: missing or unreadable %s\n' "$GAIA_CAPCHECK_SCHEMA_REL" >&2
    return 2
  fi
  if ! jq empty "$sch" >/dev/null 2>&1; then
    printf 'check-script-capabilities: %s is not valid JSON\n' "$GAIA_CAPCHECK_SCHEMA_REL" >&2
    return 2
  fi
  return 0
}

# gaia_check_script_capabilities <repo_root>
#   The composed gate. 0 clean, 1 on at least one finding, 2 on the check's own
#   failure.
gaia_check_script_capabilities() {
  local repo_root="${1:?gaia_check_script_capabilities requires a repo_root argument}"
  _gaia_capcheck_preflight "$repo_root" gate || return 2
  local rc=0 grants
  grants="$(gaia_capcheck_obligated "$repo_root" | grep '^BAD-GRANT ' || true)"
  if [ -n "$grants" ]; then printf '%s\n' "$grants"; rc=1; fi
  gaia_capcheck_coverage "$repo_root" || rc=1
  gaia_capcheck_schema "$repo_root" || rc=1
  gaia_capcheck_vocabulary "$repo_root" || rc=1
  gaia_capcheck_reconcile "$repo_root" || rc=1
  gaia_capcheck_marking "$repo_root" || rc=1
  gaia_capcheck_waivers "$repo_root"
  if [ "$rc" -eq 0 ]; then
    printf 'script capabilities: every allowlisted script declares exactly the reach it has\n'
  fi
  return $rc
}

# gaia_capcheck_print_reach <repo_root> [<script>]
#   The diagnostic. One term per line for one script, or `<script>\t<term>`
#   lines for every obligated script. A script that reaches for nothing still
#   gets its own line, carrying a `-` sentinel, so "pure" and "not enumerated"
#   are distinguishable. Unresolvable sites are stderr diagnostics here rather
#   than a fatal condition, and the mode always exits 0.
gaia_capcheck_print_reach() {
  local repo_root="$1" only="${2:-}"
  local script terms unres n
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    if [ -n "$only" ] && [ "$script" != "$only" ]; then continue; fi
    local sites
    sites="$(_gaia_capcheck_sites "$repo_root" "$script")"
    unres="$(printf '%s\n' "$sites" | grep '^UNRESOLVED	' || true)"
    if [ -n "$unres" ]; then
      printf '%s\n' "$unres" | sed "s|^UNRESOLVED\t|UNRESOLVED $script |" >&2
    fi
    terms="$(printf '%s\n' "$sites" | grep -v '^UNRESOLVED	' | cut -f1 | grep -v '^$' | LC_ALL=C sort -u)"
    n="$(printf '%s\n' "$terms" | grep -c . || true)"
    if [ -n "$only" ]; then
      [ "$n" -gt 0 ] && printf '%s\n' "$terms"
    elif [ "$n" -gt 0 ]; then
      printf '%s\n' "$terms" | sed "s|^|$script	|"
    else
      printf '%s\t-\n' "$script"
    fi
  done < <(_gaia_capcheck_obligated_paths "$repo_root")
  return 0
}

_gaia_capcheck_usage() {
  cat <<'EOF'
usage: check-script-capabilities.sh [<repo_root>]
       check-script-capabilities.sh [<repo_root>] --print-reach [<repo-relative-script>]

Reconciles every allowlisted script's declared capabilities against its actual
reach. <repo_root> defaults to the current git toplevel. --print-reach is a
diagnostic that needs no manifest and always exits 0.

Exit 0 clean, 1 on a finding, 2 on the check's own failure.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _capcheck_root=""
  _capcheck_mode="gate"
  _capcheck_target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --print-reach)
        _capcheck_mode="print-reach"
        if [ "$#" -gt 1 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
          _capcheck_target="$2"
          shift
        fi
        ;;
      -*)
        _gaia_capcheck_usage >&2
        exit 2
        ;;
      *)
        if [ -n "$_capcheck_root" ]; then
          printf 'check-script-capabilities: unexpected argument: %s\n' "$1" >&2
          _gaia_capcheck_usage >&2
          exit 2
        fi
        _capcheck_root="$1"
        ;;
    esac
    shift
  done
  if [ -z "$_capcheck_root" ]; then
    _capcheck_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _capcheck_root=""
    if [ -z "$_capcheck_root" ]; then
      printf 'check-script-capabilities: not a git repository and no repo_root argument given\n' >&2
      exit 2
    fi
  fi
  if [ "$_capcheck_mode" = "print-reach" ]; then
    _gaia_capcheck_preflight "$_capcheck_root" print-reach || exit 2
    gaia_capcheck_print_reach "$_capcheck_root" "$_capcheck_target"
    exit 0
  fi
  gaia_check_script_capabilities "$_capcheck_root"
  exit $?
fi
