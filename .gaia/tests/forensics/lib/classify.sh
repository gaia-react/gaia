#!/usr/bin/env bash
# Shell implementation of the classifier table lookup defined in
# .claude/skills/gaia/references/forensics/taxonomy.md
#
# Usage:
#   classify_description "$description"   -> prints class to stdout
#   classify_evidence "$class" "$description"  -> prints evidence note to stdout
#
# The taxonomy table (closed set, declared order):
#   init | update | wiki-sync | quality-gate | hook | scaffold | dev-server | other
#
# Classification heuristic: walk table in declared order, case-insensitive
# substring match against signal phrases. First match wins on multi-match.

set -euo pipefail

# classify_description DESC -> prints class tag to stdout
classify_description() {
  local desc
  desc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$desc" | grep -qE 'init|scaffold failed|rename|branding strip'; then
    printf 'init'
    return 0
  fi

  if printf '%s' "$desc" | grep -qE 'update|merge conflict|three-way'; then
    printf 'update'
    return 0
  fi

  if printf '%s' "$desc" | grep -qE 'wiki-sync|sync|wiki commit'; then
    printf 'wiki-sync'
    return 0
  fi

  if printf '%s' "$desc" | grep -qE 'quality gate|quality-gate|typecheck|lint failed'; then
    printf 'quality-gate'
    return 0
  fi

  if printf '%s' "$desc" | grep -qE 'hook|pretooluse|posttooluse|session-start|session-stop'; then
    printf 'hook'
    return 0
  fi

  if printf '%s' "$desc" | grep -qE 'scaffold|new-component|skeleton|template'; then
    printf 'scaffold'
    return 0
  fi

  if printf '%s' "$desc" | grep -qE 'dev server|dev-server|vite|5173|ssr error'; then
    printf 'dev-server'
    return 0
  fi

  printf 'other'
}

# classify_evidence CLASS DESC -> prints evidence note to stdout
# Extracts the matching phrase from the description for the given class.
classify_evidence() {
  local class="$1"
  local desc
  desc="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"

  case "$class" in
    init)
      for phrase in 'init' 'scaffold failed' 'rename' 'branding strip'; do
        if printf '%s' "$desc" | grep -q "$phrase"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    update)
      for phrase in 'update' 'merge conflict' 'three-way'; do
        if printf '%s' "$desc" | grep -q "$phrase"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    wiki-sync)
      for phrase in 'wiki-sync' 'sync' 'wiki commit'; do
        if printf '%s' "$desc" | grep -q "$phrase"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    quality-gate)
      for phrase in 'quality gate' 'quality-gate' 'typecheck' 'lint failed'; do
        if printf '%s' "$desc" | grep -q "$phrase"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    hook)
      for phrase in 'hook' 'pretooluse' 'posttooluse' 'session-start' 'session-stop'; do
        if printf '%s' "$desc" | grep -q "$phrase"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    scaffold)
      for phrase in 'scaffold' 'new-component' 'skeleton' 'template'; do
        if printf '%s' "$desc" | grep -q "$phrase"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    dev-server)
      for phrase in 'dev server' 'dev-server' 'vite' '5173' 'ssr error'; do
        if printf '%s' "$desc" | grep -q "$phrase"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    other)
      printf 'no taxonomy class matched'
      return 0
      ;;
  esac

  printf 'no taxonomy class matched'
}
