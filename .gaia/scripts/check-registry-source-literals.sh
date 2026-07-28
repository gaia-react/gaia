#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check B -- registry <-> tracked-source path literals (state-registry
# conformance model, foundations task 2.3, design
# analysis/registry-design.md §4.2).
#
# Over TRACKED SOURCE (never the runtime .gaia/local/, which is gitignored
# and empty in CI -- see D-024): two directions.
#
#   1. literal -> registry: every `.gaia/local/<path>` string literal a
#      shipped writer/reader names should map to a registry entry (live or
#      residue), via gaia_registry_classify.
#   2. registry -> literal: every live registry entry (except a
#      `writer: not-yet-live` entry, which is explicitly allowlisted for a
#      writer that has not shipped -- see the registry's own field
#      rationale) should have at least one real reference somewhere in
#      shipped source.
#
# Two source tiers, because a meaningful share of GAIA's "shipped
# writers/readers" are prompt-driven skills/commands, not shell or
# TypeScript:
#
#   CODE tier   -- .sh/.mjs/.ts production files. Used for BOTH directions.
#                  Direction 1's literal extraction is scoped to this tier
#                  only and skips comment lines, so a path merely mentioned
#                  in a header comment or prose aside does not count as a
#                  writer/reader naming it.
#   SKILL tier  -- .claude/commands/*.md, .claude/skills/**/*.md,
#                  .claude/agents/*.md, .specify/extensions/gaia/commands/*.md.
#                  Used ONLY for direction 2 (registry -> literal). These are
#                  the actual runtime instruction surface for LLM-driven
#                  writers (e.g. the forensics report path is named in
#                  .claude/skills/gaia/references/forensics.md and the
#                  security-notes path in .claude/agents/code-audit-frontend.md,
#                  neither in any .sh/.ts file) -- excluding them from
#                  direction 2 would misreport those entries as phantom. They are excluded from
#                  direction 1's literal extraction because prose paths in a
#                  command/skill body are numerous and conversational (path
#                  fragments in examples, alternates, prose asides); scanning
#                  them for "unmapped literals" would swamp the report with
#                  noise direction 1 is not designed to triage.
#
# Both tiers explicitly exclude wiki/ (documentation *about* the system, not
# a shipped writer/reader itself), .bats suites and __tests__/*.test.ts
# (test fixtures reference paths as test data, not as a shipped writer), and
# .github/ (CI config).
#
# Dual-mode: source it for the functions below, or run it directly (see
# "Executable entry" at the bottom).
#
# gaia_check_registry_source_literals <repo_root>
#   Prints the full report (both directions) to stdout. ALWAYS returns 0 --
#   see the report-mode note below. Requires jq (via state-registry-lib.sh)
#   and git.
#
# Report-mode note (design §4.2, task instruction): at this phase most call
# sites still hardcode `.gaia/local/...` directly; Phase 3 converts them to
# read the registry/resolver. So direction 1 (literal -> registry) is
# EXPECTED to surface unmapped literals today, and this script reports them
# rather than failing CI on them -- forcing it green by loosening the
# matcher would hide the very thing Phase 3 is supposed to fix. Direction 2
# (registry -> literal, "no phantom entries") is a stricter invariant this
# script exposes via its own labeled exit-code function
# (gaia_check_registry_no_phantom_entries) so a caller (the bats suite) can
# hard-gate on it independently while direction 1 stays report-only.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/state-registry-lib.sh"

# Tier 1: production code. Literal extraction runs over this tier only.
GAIA_CHECKB_CODE_PATHSPECS=(
  '.claude/hooks/*.sh'
  '.claude/hooks/lib/*.sh'
  '.gaia/scripts/*.sh'
  '.gaia/scripts/*.mjs'
  '.specify/extensions/gaia/lib/*.sh'
  '.gaia/cli/src/**/*.ts'
  ':!.gaia/cli/src/**/__tests__/**'
  ':!.gaia/cli/src/**/*.test.ts'
)

# Tier 2: the skill/command instruction surface. Direction 2 (registry ->
# literal) only -- see the header note above.
GAIA_CHECKB_SKILL_PATHSPECS=(
  '.claude/commands/*.md'
  '.claude/skills/**/*.md'
  '.claude/agents/*.md'
  '.specify/extensions/gaia/commands/*.md'
)

# _gaia_checkb_code_files <repo_root>: tier-1 files that contain the literal
# ".gaia/local/" at least once, one per line.
_gaia_checkb_code_files() {
  local repo_root="$1"
  git -C "$repo_root" grep -lIF '.gaia/local/' -- "${GAIA_CHECKB_CODE_PATHSPECS[@]}" 2>/dev/null
}

# _gaia_checkb_is_comment_line <line> <ext>: true when <line>, trimmed of
# leading whitespace, is a comment line for a file of type <ext> ("sh",
# "mjs", or "ts").
_gaia_checkb_is_comment_line() {
  local line="$1" ext="$2" trimmed
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$ext" in
    sh) [[ "$trimmed" == \#* ]] ;;
    mjs | ts) [[ "$trimmed" == //* || "$trimmed" == \** ]] ;;
    *) return 1 ;;
  esac
}

# _gaia_checkb_normalize <frag>: collapses bash/TS variable interpolation
# inside a path fragment to a single '*' wildcard (so
# "audit/${m_digest:-<unavailable>}.${m}.ok" reads as "audit/*.*.ok", the
# same shape the registry's own glob entries describe), then trims a single
# trailing '.' (a sentence period landing directly against the fragment,
# with no separating space) and any unbalanced trailing '}' (the mirror
# case, a fragment ending in stray prose punctuation).
_gaia_checkb_normalize() {
  local frag="$1"
  # ${...} (braced interpolation, including ${x:-<default>} and ${x:0:8}) -> *
  # The single-quoted '${' / '}' below are literal glob text matched against
  # $frag, not an expansion.
  # shellcheck disable=SC2016
  while [[ "$frag" == *'${'*'}'* ]]; do
    frag="$(printf '%s' "$frag" | sed -E 's/\$\{[^}]*\}/*/')"
  done
  # bare $word -> *
  frag="$(printf '%s' "$frag" | sed -E 's/\$[A-Za-z_][A-Za-z0-9_]*/*/g')"
  # printf-style format specifiers (%s, %d, ...) -> *
  frag="$(printf '%s' "$frag" | sed -E 's/%[A-Za-z]/*/g')"
  # collapse a run of consecutive '*' from adjoining wildcards
  frag="$(printf '%s' "$frag" | sed -E 's/\*+/*/g')"
  # trailing sentence period with no separating space
  frag="${frag%.}"
  # unbalanced trailing '}'
  local opens closes
  while [[ "$frag" == *'}' ]]; do
    opens="$(printf '%s' "$frag" | tr -dc '{' | wc -c | tr -d ' ')"
    closes="$(printf '%s' "$frag" | tr -dc '}' | wc -c | tr -d ' ')"
    [ "$opens" -lt "$closes" ] || break
    frag="${frag%?}"
  done
  printf '%s' "$frag"
}

# _gaia_checkb_extract <repo_root>: prints "<normalized-relpath>\t<file:line>"
# for every non-comment ".gaia/local/<path>" literal in the tier-1 code
# files, one per occurrence (not deduplicated -- dedup happens in the
# caller, which also picks a representative citation per unique relpath).
_gaia_checkb_extract() {
  local repo_root="$1" file ext ln text frag rel
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      *.sh) ext="sh" ;;
      *.mjs) ext="mjs" ;;
      *.ts) ext="ts" ;;
      *) continue ;;
    esac
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      _gaia_checkb_is_comment_line "$text" "$ext" && continue
      while read -r frag; do
        [ -n "$frag" ] || continue
        rel="${frag#.gaia/local/}"
        rel="$(_gaia_checkb_normalize "$rel")"
        [ -n "$rel" ] || continue
        printf '%s\t%s:%s\n' "$rel" "$file" "$ln"
      done < <(grep -oE '\.gaia/local/[A-Za-z0-9_./*@:%<>{}$\-]+' <<<"$text")
    done < <(grep -n -F '.gaia/local/' "$repo_root/$file")
  done < <(_gaia_checkb_code_files "$repo_root")
}

# _gaia_checkb_entry_alt_pattern <alt>: turns one '|'-joined registry path
# alternative into an ERE substring pattern: '.' escaped, '*' and
# '<placeholder>' both become '.*'.
_gaia_checkb_entry_alt_pattern() {
  local alt="$1"
  printf '%s' "$alt" \
    | sed -E 's/\./\\./g' \
    | sed -E 's/<[^>]*>/.*/g' \
    | sed -E 's/\*/.*/g'
}

# gaia_check_registry_no_phantom_entries <repo_root>
#   Direction 2. Every live entry whose writer is not "not-yet-live" (the
#   registry's own documented exemption -- an allowlisted writer that has
#   not shipped yet) must have at least one reference across BOTH tiers.
#   Prints one "PHANTOM: <id> (<path>)" line per violation. Returns 0 when
#   none, 1 otherwise. This is the hard-gatable half of Check B.
gaia_check_registry_no_phantom_entries() {
  local repo_root="$1"
  local registry
  registry="$(gaia_registry_path)" || return 1
  local -a all_pathspecs=("${GAIA_CHECKB_CODE_PATHSPECS[@]}" "${GAIA_CHECKB_SKILL_PATHSPECS[@]}")
  local id path writer found alt pattern rc=0
  while IFS=$'\t' read -r id path writer; do
    [ -n "$id" ] || continue
    [ "$writer" = "not-yet-live" ] && continue
    found=0
    local saved_ifs="$IFS"
    IFS='|'
    local -a alts
    read -ra alts <<<"$path"
    IFS="$saved_ifs"
    for alt in "${alts[@]}"; do
      pattern="$(_gaia_checkb_entry_alt_pattern "$alt")"
      if git -C "$repo_root" grep -qIE -- "$pattern" "${all_pathspecs[@]}" 2>/dev/null; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      printf 'PHANTOM: %s (%s)\n' "$id" "$path"
      rc=1
    fi
  done < <(jq -r '.entries[] | [.id, .path, .writer] | @tsv' "$registry")
  return $rc
}

# gaia_check_registry_source_literals <repo_root>
#   The full report: direction 1 (unmapped literals, report-only) then
#   direction 2 (phantom entries, hard-gatable -- see the function above).
#   ALWAYS returns 0; see the report-mode note in the file header. Callers
#   that want direction 2 as a hard gate call
#   gaia_check_registry_no_phantom_entries directly.
gaia_check_registry_source_literals() {
  local repo_root="${1:?gaia_check_registry_source_literals requires a repo_root argument}"

  printf '== Check B, direction 1: tracked-source literal -> registry ==\n'
  local raw rel cite scope
  raw="$(_gaia_checkb_extract "$repo_root")"
  local -a seen=()
  local unmapped_count=0 total_unique=0
  if [ -n "$raw" ]; then
    while IFS=$'\t' read -r rel cite; do
      [ -n "$rel" ] || continue
      local already=0 s
      for s in "${seen[@]:-}"; do
        [ "$s" = "$rel" ] && already=1 && break
      done
      [ "$already" -eq 1 ] && continue
      seen+=("$rel")
      total_unique=$((total_unique + 1))
      scope="$(gaia_registry_classify "$rel" 2>/dev/null)"
      if [ "$scope" = "unknown" ]; then
        unmapped_count=$((unmapped_count + 1))
        printf 'UNMAPPED: %s  (first seen %s)\n' "$rel" "$cite"
      fi
    done <<<"$raw"
  fi
  printf 'literal relpaths seen: %d unique, %d unmapped (report-only; expected non-zero until Phase 3 converts call sites to read the registry)\n' \
    "$total_unique" "$unmapped_count"

  printf '\n== Check B, direction 2: registry entry -> tracked-source reference ==\n'
  gaia_check_registry_no_phantom_entries "$repo_root"
  local phantom_rc=$?
  if [ "$phantom_rc" -eq 0 ]; then
    printf 'no phantom entries: every live entry has at least one shipped source reference\n'
  fi

  return 0
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-registry-source-literals: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_registry_source_literals "$repo_root"
  exit $?
fi
