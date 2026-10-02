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
  local description
  description="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  if grep -qE 'init|scaffold failed|rename|branding strip' <<<"$description"; then
    printf 'init'
    return 0
  fi

  if grep -qE 'update|merge conflict|three-way' <<<"$description"; then
    printf 'update'
    return 0
  fi

  if grep -qE 'wiki-sync|sync|wiki commit' <<<"$description"; then
    printf 'wiki-sync'
    return 0
  fi

  if grep -qE 'quality gate|quality-gate|typecheck|lint failed' <<<"$description"; then
    printf 'quality-gate'
    return 0
  fi

  if grep -qE 'hook|pretooluse|posttooluse|session-start|session-stop' <<<"$description"; then
    printf 'hook'
    return 0
  fi

  if grep -qE 'scaffold|new-component|skeleton|template' <<<"$description"; then
    printf 'scaffold'
    return 0
  fi

  if grep -qE 'dev server|dev-server|vite|5173|ssr error' <<<"$description"; then
    printf 'dev-server'
    return 0
  fi

  printf 'other'
}

# classify_evidence CLASS DESC -> prints evidence note to stdout
# Extracts the matching phrase from the description for the given class.
classify_evidence() {
  local class="$1"
  local description
  description="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"

  case "$class" in
    init)
      for phrase in 'init' 'scaffold failed' 'rename' 'branding strip'; do
        if grep -q "$phrase" <<<"$description"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    update)
      for phrase in 'update' 'merge conflict' 'three-way'; do
        if grep -q "$phrase" <<<"$description"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    wiki-sync)
      for phrase in 'wiki-sync' 'sync' 'wiki commit'; do
        if grep -q "$phrase" <<<"$description"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    quality-gate)
      for phrase in 'quality gate' 'quality-gate' 'typecheck' 'lint failed'; do
        if grep -q "$phrase" <<<"$description"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    hook)
      for phrase in 'hook' 'pretooluse' 'posttooluse' 'session-start' 'session-stop'; do
        if grep -q "$phrase" <<<"$description"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    scaffold)
      for phrase in 'scaffold' 'new-component' 'skeleton' 'template'; do
        if grep -q "$phrase" <<<"$description"; then
          printf '"%s"' "$phrase"
          return 0
        fi
      done
      ;;
    dev-server)
      for phrase in 'dev server' 'dev-server' 'vite' '5173' 'ssr error'; do
        if grep -q "$phrase" <<<"$description"; then
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
