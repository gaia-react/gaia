#!/usr/bin/env bash
# Shared, sourced resolver for the plan folder and feature key backing this
# branch's active KICKOFF execution. Hooks source this to key a side effect
# (a tally record, a roll-up render) to the right plan without depending on
# session-scoped state. Pure and side-effect-free; every function always
# returns 0, even when nothing resolves or the repo has no plans directory
# at all.
#
# Usage:
#   . .claude/hooks/lib/gaia-active-plan.sh
#   plan_dir="$(resolve_active_plan_dir)"
#   [ -n "$plan_dir" ] && feature_key="$(resolve_feature_key "$plan_dir")"

# Echoes the repo-relative path of the plan directory whose RUNNING sentinel
# names the current branch, or nothing when none match. When several plans
# match, disambiguates on the lexicographically latest `started:` value
# (ISO-8601 sorts correctly as a string): the most recently started run
# wins. A RUNNING file missing a `branch:` or `started:` line is skipped,
# not an error.
resolve_active_plan_dir() {
  local cur running_file file_branch file_started best_dir best_started

  cur="$(git branch --show-current 2>/dev/null)" || true
  [ -n "$cur" ] || return 0

  best_dir=""
  best_started=""
  for running_file in .gaia/local/plans/*/RUNNING; do
    [ -f "$running_file" ] || continue

    file_branch="$(grep '^branch:' "$running_file" 2>/dev/null | cut -d' ' -f2)" || true
    [ "$file_branch" = "$cur" ] || continue

    file_started="$(grep '^started:' "$running_file" 2>/dev/null | cut -d' ' -f2)" || true
    if [ -z "$best_dir" ] || [[ "$file_started" > "$best_started" ]]; then
      best_dir="$(dirname "$running_file")"
      best_started="$file_started"
    fi
  done

  [ -n "$best_dir" ] && printf '%s' "$best_dir"
  return 0
}

# Echoes the feature key for a plan directory: basename(dirname(SPEC path)),
# read from the `Derived from … (…)` line inside <plan_dir>/README.md's
# `## Source SPEC` section (the same resolution the planning step uses, so
# a feature's spec / plan / execute records all key together). Falls back to
# a bare `SPEC-NNN` scan of that line when the path is unparseable, and
# ultimately to the plan directory's own basename (the slug) for a spec-less
# plan.
resolve_feature_key() {
  local plan_dir="$1" readme source_line path key

  readme="$plan_dir/README.md"
  source_line=""
  if [ -f "$readme" ]; then
    source_line="$(awk '
      /^## Source SPEC/ { insec=1; next }
      insec && /^## / { exit }
      insec && /Derived from/ { print; exit }
    ' "$readme" 2>/dev/null)" || true
  fi

  if [ -n "$source_line" ]; then
    path="$(printf '%s' "$source_line" | sed -nE 's/^[^(]*\(([^)]*)\).*/\1/p')" || true
    if [ -n "$path" ]; then
      key="$(basename "$(dirname "$path")" 2>/dev/null)" || true
      if [ -n "$key" ] && [ "$key" != "." ] && [ "$key" != "/" ]; then
        printf '%s' "$key"
        return 0
      fi
    fi

    key="$(printf '%s' "$source_line" | grep -oE 'SPEC-[0-9]+' | head -1)" || true
    if [ -n "$key" ]; then
      printf '%s' "$key"
      return 0
    fi
  fi

  basename "$plan_dir"
  return 0
}
