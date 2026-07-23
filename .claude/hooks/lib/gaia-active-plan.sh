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

# Echoes the absolute path of the plan directory whose RUNNING sentinel names the
# current branch, or nothing when none match. The search is anchored to the MAIN
# checkout -- the working tree that owns the shared .git dir -- via the shared
# resolver (.gaia/scripts/main-root-lib.sh), sourced here rather than into any
# top-level scope so this lib's "no side effects at source time" contract holds
# (the sourced-lib placement rule; matches state-registry-lib.sh's own
# gaia_registry_path). A linked worktree symlinks only the fixed shared-state
# set .gaia/scripts/link-worktree.sh names; .gaia/local/specs and
# .gaia/local/plans are NOT among them, so a RUNNING sentinel is visible only
# from the main checkout, and a plan executed in a linked worktree still
# resolves through it. When several plans match, disambiguates on the
# lexicographically latest `started:` value (ISO-8601 sorts correctly as a
# string): the most recently started run wins. A RUNNING file missing a
# `branch:` or `started:` line is skipped, not an error.
resolve_active_plan_dir() {
  local cur main_root running_file file_branch file_started best_dir best_started

  cur="$(git branch --show-current 2>/dev/null)" || true
  [ -n "$cur" ] || return 0

  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 0
  # shellcheck disable=SC1091
  source "$self_dir/../../../.gaia/scripts/main-root-lib.sh" 2>/dev/null || return 0
  main_root="$(gaia_resolve_main_root 2>/dev/null)" || return 0
  [ -n "$main_root" ] || return 0

  best_dir=""
  best_started=""
  for running_file in "$main_root"/.gaia/local/plans/*/RUNNING "$main_root"/.gaia/local/specs/*/plan/RUNNING "$main_root"/.gaia/local/specs/*/plan-*/RUNNING; do
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
