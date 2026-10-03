#!/usr/bin/env bash
# The package-aware half of .husky/pre-commit. The hook is POSIX sh and cannot
# source the bash registry reader, so it asks this helper what to do and acts on the answer.
#
# Usage: bash .gaia/scripts/precommit-packages.sh <repo_root>
#
# Reads the staged set with `git diff --cached --name-status -z -M100%` and
# prints a plan on stdout, one record per line, fields separated by a TAB:
#
#   exempt                  every staged entry is a C13 migration rename; the
#                           hook skips the whole gate. Nothing else is printed
#                           and no registry is loaded (the exemption is a
#                           literal table, independent of the registry).
#   doctor<TAB><dir>        <dir> holds more than one react-doctor config
#   doctor-file<TAB><path>  one such config, repo-relative
#   package<TAB><dir>       a registered package with a staged path that
#                           matches its preCommitSource globs; <dir> is the
#                           registry path (`.` or `frontend`)
#   settings-drift          a staged path feeds the generated package settings
#                           (root `.claude/settings.json`, `.gaia/packages.json`,
#                           or any `*/.claude/settings.{json,overlay.json}`); the
#                           hook runs `check-settings-drift.sh` (C8)
#   retired-add<TAB>p<TAB>q p is an added (or renamed-to) file under a retired
#                           root frontend path while no registered package sits
#                           at `.`; q is its `frontend/` equivalent (MIG-013)
#
# Exit 0 with a plan (possibly empty: nothing to do). Exit 1 with
# GAIA_PACKAGES_ERROR on stderr when the registry or a descriptor cannot be
# read; the hook then fails the commit (C5, no guard allows on a descriptor
# failure). Exit 2 on a usage error or a git failure.
#
# C13: an entry is exempt only when it is an exact rename (R100) whose source is
# a retired root frontend path and whose destination is that source's C6
# counterpart (`<src>` -> `frontend/<src>`), or the single pair `.dockerignore`
# -> `frontend/Dockerfile.dockerignore`. Everything else counts, including an
# R100 rename inside `frontend/`, because a rename can break importers that
# typecheck would catch.
#
# Bash 3.2 compatible; BSD and GNU tools.

set -u

root="${1:-}"
if [ -z "$root" ] || [ ! -d "$root" ]; then
  printf 'precommit-packages: usage: precommit-packages.sh <repo_root>\n' >&2
  exit 2
fi

# The C6 move list, as literal case arms. Never derived from the registry.
# shellcheck disable=SC2249 # every arm is a literal pattern, no default needed
is_retired_source() {
  case "$1" in
    app/* | test/* | public/* | .storybook/* | .playwright/*) return 0 ;;
    vite.config.ts | vitest.config.ts | playwright.config.ts) return 0 ;;
    react-router.config.ts | stylelint.config.mjs | knip.config.ts) return 0 ;;
    doctor.config.ts | tsconfig.json | Dockerfile | .env.example) return 0 ;;
    eslint.config.mjs | .lintstagedrc.json) return 0 ;;
    .claude/skills/a11y-fixes/* | .claude/skills/eslint-fixes/*) return 0 ;;
    .claude/skills/gaia-react-perf/* | .claude/skills/new-component/*) return 0 ;;
    .claude/skills/new-hook/* | .claude/skills/new-route/*) return 0 ;;
    .claude/skills/new-service/* | .claude/skills/playwright-cli/*) return 0 ;;
    .claude/skills/react-code/* | .claude/skills/skeleton-loaders/*) return 0 ;;
    .claude/skills/tailwind/* | .claude/skills/typescript/*) return 0 ;;
    .claude/rules/accessibility.md | .claude/rules/api-service.md) return 0 ;;
    .claude/rules/design-baseline.md | .claude/rules/i18n.md) return 0 ;;
    .claude/rules/playwright.md | .claude/rules/react-router-docs.md) return 0 ;;
    .claude/rules/routes.md | .claude/rules/state-pattern.md) return 0 ;;
    .claude/rules/storybook.md | .claude/rules/tailwind.md) return 0 ;;
    .claude/instructions/add-locale.md | .claude/instructions/remove-i18n.md) return 0 ;;
    .claude/agents/code-audit-frontend/README.md) return 0 ;;
    .claude/agents/code-audit-frontend/cn.md) return 0 ;;
    .claude/agents/code-audit-frontend/conform.md) return 0 ;;
    .claude/agents/code-audit-frontend/form-components.md) return 0 ;;
    .claude/agents/code-audit-frontend/react-i18next.md) return 0 ;;
  esac
  return 1
}

# is_exempt_entry <status> <source> <destination>
is_exempt_entry() {
  [ "$1" = R100 ] || return 1
  if [ "$2" = .dockerignore ]; then
    [ "$3" = frontend/Dockerfile.dockerignore ]
    return
  fi
  is_retired_source "$2" || return 1
  [ "$3" = "frontend/$2" ]
}

# Read the staged set. `-z` keeps a non-ASCII or spaced path intact; a rename
# carries two NUL-terminated paths. A command substitution drops NUL bytes, so
# the stream is translated to SOH (never in a path) before it is captured.
counted_paths=''
added_paths=''
entry_count=0
exempt_count=0
status_word=''
staged_file=$(mktemp "${TMPDIR:-/tmp}/precommit-packages.XXXXXX") || exit 2
trap 'rm -f "$staged_file"' EXIT
if ! git -C "$root" diff --cached --name-status -z -M100% >"$staged_file"; then
  printf 'precommit-packages: git diff --cached failed in %s\n' "$root" >&2
  exit 2
fi
staged_raw=$(tr '\0' '\001' <"$staged_file")

fields=()
while IFS= read -r -d $'\001' field; do
  fields+=("$field")
done <<<"$staged_raw"

index=0
total=${#fields[@]}
while [ "$index" -lt "$total" ]; do
  status_word="${fields[$index]}"
  index=$((index + 1))
  case "$status_word" in
    R* | C*)
      source_path="${fields[$index]}"
      destination_path="${fields[$((index + 1))]}"
      index=$((index + 2))
      entry_count=$((entry_count + 1))
      if is_exempt_entry "$status_word" "$source_path" "$destination_path"; then
        exempt_count=$((exempt_count + 1))
      else
        counted_paths="${counted_paths}${source_path}"$'\n'"${destination_path}"$'\n'
        added_paths="${added_paths}${destination_path}"$'\n'
      fi
      ;;
    *)
      path="${fields[$index]}"
      index=$((index + 1))
      entry_count=$((entry_count + 1))
      counted_paths="${counted_paths}${path}"$'\n'
      if [ "$status_word" = A ]; then
        added_paths="${added_paths}${path}"$'\n'
      fi
      ;;
  esac
done

if [ "$entry_count" -gt 0 ] && [ "$exempt_count" -eq "$entry_count" ]; then
  printf 'exempt\n'
  exit 0
fi

packages_lib="$root/.claude/hooks/lib/gaia-packages.sh"
if [ ! -f "$packages_lib" ]; then
  printf 'gaia-packages: .claude/hooks/lib/gaia-packages.sh is missing. Next step: restore it from git or run /update-gaia.\n' >&2
  exit 1
fi
# shellcheck source=../../.claude/hooks/lib/gaia-packages.sh
. "$packages_lib"
load_status=0
gaia_packages_load "$root" || load_status=$?
if [ "$load_status" -ne 0 ]; then
  printf '%s\n' "$GAIA_PACKAGES_ERROR" >&2
  exit 1
fi

# Generated settings (C8): any staged path that feeds `<package>/.claude/
# settings.json`, or the generated file itself, makes the hook run the drift
# check. Matching the counted set keeps a rename's source and destination both.
while IFS= read -r counted; do
  case "$counted" in
    .claude/settings.json | .gaia/packages.json | */.claude/settings.overlay.json | */.claude/settings.json)
      printf 'settings-drift\n'
      break
      ;;
  esac
done <<<"$counted_paths"

# MIG-013: once no package sits at the repo root, a new file under a retired
# root frontend path is a stale adopter muscle-memory write, and `frontend/` is
# where it belongs. Only added paths count; an edit of an existing root file is
# left to the other gates.
root_package_count=$(gaia_packages_list | awk -F'\t' '$2 == "." {count++} END {print count + 0}')
if [ "$root_package_count" -eq 0 ]; then
  while IFS= read -r added; do
    case "$added" in
      app/* | test/* | public/* | .playwright/* | .storybook/*)
        printf 'retired-add\t%s\tfrontend/%s\n' "$added" "$added"
        ;;
    esac
  done <<<"$added_paths"
fi

# Doctor guard: exactly one react-doctor config per package directory. The
# highest-precedence file wins and the rest are silently ignored, so a stray
# duplicate shadows the canonical config without warning.
doctor_ere=$(gaia_package_globs_ere doctorConfigs)
package_listing=$(gaia_packages_list)
if [ -n "$doctor_ere" ]; then
  while IFS=$'\t' read -r package_name package_dir; do
    [ -n "$package_name" ] || continue
    found=''
    count=0
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if [ "$package_dir" = . ]; then
        relative="$candidate"
      else
        relative="$package_dir/$candidate"
      fi
      if printf '%s\n' "$relative" | grep -Eq -- "$doctor_ere"; then
        count=$((count + 1))
        found="${found}${relative}"$'\n'
      fi
    done <<<"$(find "$root/$package_dir" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null)"
    if [ "$count" -gt 1 ]; then
      printf 'doctor\t%s\n' "$package_dir"
      while IFS= read -r candidate; do
        [ -n "$candidate" ] && printf 'doctor-file\t%s\n' "$candidate"
      done <<<"$found"
    fi
  done <<<"$package_listing"
fi

# Source predicate: a counted path that matches preCommitSource marks its
# owning package as having changes.
source_ere=$(gaia_package_globs_ere preCommitSource)
seen_dirs=''
if [ -n "$source_ere" ] && [ -n "$counted_paths" ]; then
  while IFS= read -r counted; do
    [ -n "$counted" ] || continue
    printf '%s\n' "$counted" | grep -Eq -- "$source_ere" || continue
    owner=$(gaia_package_for_path "$counted")
    [ -n "$owner" ] || continue
    owner_dir=$(gaia_package_dir "$owner") || continue
    case "$seen_dirs" in
      *$'\n'"$owner_dir"$'\n'*) continue ;;
    esac
    seen_dirs="${seen_dirs}"$'\n'"${owner_dir}"$'\n'
    printf 'package\t%s\n' "$owner_dir"
  done <<<"$counted_paths"
fi
exit 0
