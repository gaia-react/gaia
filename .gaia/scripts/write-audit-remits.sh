#!/usr/bin/env bash
# SC2016 is intentional file-wide: single-quoted awk programs and printf format
# strings where any $ or backtick is literal output text, not a shell expansion.
# shellcheck disable=SC2016
# write-audit-remits.sh: generates each Code Audit Team member's remit region
# from the roster.
#
# Every member declares which files it owns twice: once in the roster
# (.gaia/audit-ci.yml), which decides dispatch and the clearance the merge gate
# demands, and once in its own .claude/agents/code-audit-<name>.md prose, which
# the spawned agent filters the changed-file list against. Nothing checks that
# the two agree, so they drift. This script makes the prose a GENERATED
# statement of the roster: it rewrites each member's marker-delimited remit
# region (between `<!-- gaia:audit-remit:start -->` and
# `<!-- gaia:audit-remit:end -->`) from the roster's raw globs, and is
# idempotent on an already-agreeing tree -- a second run changes nothing.
#
# It obtains the roster's raw globs from verify-audit-roster.sh's read-only
# `--emit-roster` mode rather than carrying a second YAML scrape: that mode
# reuses the check's own _verify_roster_read_globs reader, so the roster is
# parsed exactly twice between the two scripts (the scrape, and the
# classifier), never a third time here.
#
# It never modifies anything outside a member's remit markers. The one
# exception: a definition that carries no region yet, where it inserts one
# after the `## Remit and self-skip` heading (or, failing that, after the
# YAML frontmatter) and leaves everything else on the page untouched.
#
# A dispatched Code Audit Team member is denied this script entirely by
# .claude/hooks/block-selfheal-paths.sh: repairing a drifted remit is the
# orchestrator's action, taken between dispatches, never a member's own. A
# member that notices its region has drifted reports it as a finding instead.
#
# Reads the roster and each agent file; writes only inside a member's own
# markers, or inserts a fresh pair. Never touches the roster itself, the
# machinery lists, or any wiki page.
#
# DO NOT add `set -e` (matches verify-audit-roster.sh): several checks below
# rely on grep and comparison exit status without aborting the script.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`, no
# `${var^^}`. Never `cd` outside the source-time self-location resolution.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: write-audit-remits.sh [--root <dir>] [--config <file>]
  --root <dir>     repo root. Default: the repo holding this script.
                   Injection point for the agent files.
  --config <file>  roster. Default: <root>/.gaia/audit-ci.yml.
                   Injection point for the roster.
  --help | -h      this text.

Exit codes:
  0  every member's region is in the generated state (whether or not
     anything changed).
  1  a hard failure: the check script is missing, the --emit-roster call
     failed, or a definition's markers are duplicated, unbalanced, or the
     definition has no insertion anchor.
  2  usage error, including a roster that does not exist.
USAGE
}

START_MARKER='<!-- gaia:audit-remit:start -->'
END_MARKER='<!-- gaia:audit-remit:end -->'
REMIT_HEADING='## Remit and self-skip'

# Contract C5: the two canonical region sentences, verbatim. Neither names a
# path. Kept here, not in the check: the check does not compare sentence text
# (see verify-audit-roster.sh's remit invariant), so this is their one home.
CLAIMANT_SENTENCE='Filter the changed-file list against the globs above. **If none match, self-skip cleanly.** Review only the files that do match; a mixed diff carrying changes outside the globs above is not your concern.'
DEFAULT_SENTENCE='Your globs above are a **second precedence tier**: every claimant member'\''s globs are matched first, first-match-wins over roster order, and a path any claimant claims belongs to that claimant even when a glob above also matches it. Only a path no claimant claims reaches you. The roster is the whole truth about your reach; nothing outside this region grants you a file it does not declare.'

root=""
config=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --root|--config)
      if [ $# -lt 2 ]; then
        printf 'write-audit-remits: %s needs a value\n' "$1" >&2
        exit 2
      fi
      case "$1" in
        --root)   root="$2" ;;
        --config) config="$2" ;;
      esac
      shift 2
      ;;
    *)
      printf 'write-audit-remits: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$root" ]; then
  root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$root" ]; then
  printf 'write-audit-remits: could not resolve the repo root (pass --root)\n' >&2
  exit 2
fi
[ -n "$config" ] || config="${root}/.gaia/audit-ci.yml"
if [ ! -f "$config" ]; then
  printf 'write-audit-remits: roster not found: %s\n' "$config" >&2
  exit 2
fi

# Script-relative on purpose: in the bats reader-drift sandbox a perturbed copy
# of the check sits beside a copy of this writer, and the writer must observe
# that perturbation rather than resolving the repo's real check.
check_script="$(dirname "${BASH_SOURCE[0]}")/verify-audit-roster.sh"
if [ ! -f "$check_script" ]; then
  printf 'write-audit-remits: check script not found: %s\n' "$check_script" >&2
  exit 1
fi

# Always pass BOTH --root and --config: a sandbox copy is not a git repo, so
# the check's default root resolution would fail there with exit 2.
if ! records="$(bash "$check_script" --emit-roster --root "$root" --config "$config")"; then
  printf 'write-audit-remits: --emit-roster failed for %s\n' "$config" >&2
  exit 1
fi

member_list="$(printf '%s\n' "$records" | awk -F'\t' '$1 == "MEMBER" { print $2 }')"
default_name="$(printf '%s\n' "$records" | awk -F'\t' '$1 == "DEFAULT" { print $2; exit }')"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/write-audit-remits.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

overall_failed=0

while IFS= read -r name; do
  [ -n "$name" ] || continue

  agent="$root/.claude/agents/${name}.md"
  if [ ! -f "$agent" ]; then
    printf '%s: agent file not found, skipped\n' "$name" >&2
    continue
  fi

  globs="$(printf '%s\n' "$records" | awk -F'\t' -v m="$name" '$1 == "RAW" && $2 == m { print $3 }')"

  is_default=0
  [ "$name" = "$default_name" ] && is_default=1

  nstart="$(grep -cxF -- "$START_MARKER" "$agent")"
  nend="$(grep -cxF -- "$END_MARKER" "$agent")"

  # A single balanced pair is still malformed if the end marker precedes the
  # start marker: nothing then marks where the region actually begins and
  # ends in file order, and the replace state machine below would print
  # through the start marker, emit the new body, then drop every remaining
  # line to EOF looking for an end marker it will never see (because the one
  # on disk is already behind it). Caught here, before mode selection, so
  # that shape is refused rather than silently destructive.
  reversed=0
  if [ "$nstart" -eq 1 ] && [ "$nend" -eq 1 ]; then
    start_line="$(grep -nxF -- "$START_MARKER" "$agent" | cut -d: -f1)"
    end_line="$(grep -nxF -- "$END_MARKER" "$agent" | cut -d: -f1)"
    [ "$start_line" -lt "$end_line" ] || reversed=1
  fi

  if [ "$nstart" -eq 1 ] && [ "$nend" -eq 1 ] && [ "$reversed" -eq 0 ]; then
    mode="replace"
  elif [ "$nstart" -eq 0 ] && [ "$nend" -eq 0 ]; then
    mode="insert"
  elif [ "$reversed" -eq 1 ]; then
    printf 'write-audit-remits: %s: remit markers in %s are reversed (end marker at line %d appears before start marker at line %d); fix the order by hand and re-run\n' \
      "$name" "$agent" "$end_line" "$start_line" >&2
    overall_failed=1
    continue
  else
    printf 'write-audit-remits: %s: markers duplicated or unbalanced in %s (start=%d end=%d); delete the extra or unbalanced markers and re-run\n' \
      "$name" "$agent" "$nstart" "$nend" >&2
    overall_failed=1
    continue
  fi

  # The old region's glob bullets (REPLACE mode only), in file order.
  old_globs=""
  if [ "$mode" = "replace" ]; then
    old_globs="$(awk -v s="$START_MARKER" -v e="$END_MARKER" '
      $0 == s { infl = 1; next }
      $0 == e { infl = 0; next }
      infl && /^- `.*`$/ { line = $0; sub(/^- `/, "", line); sub(/`$/, "", line); print line }
    ' "$agent")"
  fi

  awk_mode="replace"
  if [ "$mode" = "insert" ]; then
    if grep -qxF -- "$REMIT_HEADING" "$agent"; then
      awk_mode="insert_heading"
    elif [ "$(head -n 1 "$agent")" = "---" ] && [ "$(grep -cxF -- "---" "$agent")" -ge 2 ]; then
      awk_mode="insert_frontmatter"
    else
      printf 'write-audit-remits: %s: no anchor found in %s (need "%s" or YAML frontmatter); not modified\n' \
        "$name" "$agent" "$REMIT_HEADING" >&2
      overall_failed=1
      continue
    fi
  fi

  # Region body (contract C1 + C5): one bullet per roster glob, in roster
  # order, a blank line, then the canonical sentence for this member's shape.
  # Written to a file and never through awk -v, so no character in a glob
  # (backtick, *, .) is ever interpreted.
  body_file="$tmpdir/body"
  : > "$body_file"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    printf -- '- `%s`\n' "$g" >> "$body_file"
  done <<EOF
$globs
EOF
  printf '\n' >> "$body_file"
  if [ "$is_default" -eq 1 ]; then
    printf '%s\n' "$DEFAULT_SENTENCE" >> "$body_file"
  else
    printf '%s\n' "$CLAIMANT_SENTENCE" >> "$body_file"
  fi
  new_body="$(cat "$body_file")"

  old_body=""
  if [ "$mode" = "replace" ]; then
    old_body="$(awk -v s="$START_MARKER" -v e="$END_MARKER" '
      $0 == s { infl = 1; next }
      $0 == e { infl = 0; next }
      infl { print }
    ' "$agent")"
  fi

  # The glob delta (contract C3): globs the roster grants that the old region
  # lacks are "+", globs the old region carried that the roster no longer
  # grants are "-". Empty for INSERT mode's old_globs (everything is "+").
  added=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if ! printf '%s\n' "$old_globs" | grep -qxF -- "$g"; then
      added="${added}+${g} "
    fi
  done <<EOF
$globs
EOF
  added="${added% }"

  removed=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if ! printf '%s\n' "$globs" | grep -qxF -- "$g"; then
      removed="${removed}-${g} "
    fi
  done <<EOF
$old_globs
EOF
  removed="${removed% }"

  # Rewrite mechanics: awk to a temp file, then mv over the original. Never
  # sed -i (the BSD/GNU -i forms disagree, and the region body carries
  # backticks, *, and . a sed replacement would mangle).
  tmp="$tmpdir/out"
  if ! awk -v bodyfile="$body_file" -v start="$START_MARKER" -v end="$END_MARKER" \
      -v mode="$awk_mode" -v anchor="$REMIT_HEADING" '
    function emit_body(   line) {
      while ((getline line < bodyfile) > 0) print line
      close(bodyfile)
    }
    function emit_region() {
      print start
      emit_body()
      print end
    }
    BEGIN { skip = 0; inserted = 0; ndash = 0 }
    mode == "replace" && $0 == start && !skip {
      print
      emit_body()
      skip = 1
      next
    }
    mode == "replace" && $0 == end && skip {
      print
      skip = 0
      next
    }
    mode == "replace" && skip { next }
    mode == "insert_heading" && !inserted && $0 == anchor {
      print
      print ""
      emit_region()
      inserted = 1
      next
    }
    mode == "insert_frontmatter" && !inserted && $0 == "---" {
      ndash++
      print
      if (ndash == 2) {
        print ""
        emit_region()
        inserted = 1
      }
      next
    }
    { print }
  ' "$agent" > "$tmp"; then
    printf 'write-audit-remits: %s: failed to generate the regenerated region for %s; not modified\n' \
      "$name" "$agent" >&2
    overall_failed=1
    continue
  fi

  was_exec=0
  [ -x "$agent" ] && was_exec=1
  if ! mv "$tmp" "$agent"; then
    printf 'write-audit-remits: %s: failed to install the regenerated %s; not modified\n' \
      "$name" "$agent" >&2
    overall_failed=1
    continue
  fi
  [ "$was_exec" -eq 1 ] && chmod +x "$agent"

  if [ "$mode" = "insert" ]; then
    printf '%s: region inserted %s\n' "$name" "$added"
  elif [ "$old_body" = "$new_body" ]; then
    printf '%s: unchanged\n' "$name"
  elif [ -n "$added" ] || [ -n "$removed" ]; then
    if [ -n "$added" ] && [ -n "$removed" ]; then
      printf '%s: %s %s\n' "$name" "$added" "$removed"
    else
      printf '%s: %s\n' "$name" "${added}${removed}"
    fi
  else
    printf '%s: region rewritten\n' "$name"
  fi
done <<EOF
$member_list
EOF

if [ "$overall_failed" -eq 1 ]; then
  exit 1
fi
exit 0
