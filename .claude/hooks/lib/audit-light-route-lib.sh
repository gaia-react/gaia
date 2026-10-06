#!/usr/bin/env bash
# audit-light-route-lib.sh: the git and glob helpers behind the light-review
# router (.gaia/scripts/audit-light-route.sh). Sourced, never executed; does no
# work at source time.
#
# A global rule, not merely shared machinery: these functions decide what the
# router counts as the delta, which commit anchors it, and which paths force
# Full, so a change here changes whether a light clearance is believed.
#
# Bash 3.2 compatible (macOS default), BWK awk safe. Never `cd`.

# The built-in hard-Full floor. Roster edits can add to it (light_hard_full)
# but never remove from it. `**/x` already matches a root-level `x`, so the
# root-level forms below are redundancy kept for the reader. The root paths
# this repository retired (`test/`, `.playwright/`, a root Dockerfile) carry
# only their `**/` form, which covers them the same way, because the
# retired-path gate refuses a harness file citing them at the root.
LIGHT_ROUTE_FLOOR_GLOBS="$(cat <<'EOF'
**/tests/**
**/test/**
tests/**
**/__tests__/**
**/*.test.*
**/*.spec.*
*.test.*
*.spec.*
**/*.bats
*.bats
**/.playwright/**
**/*.stories.*
package.json
**/package.json
**/gaia.package.json
pnpm-lock.yaml
**/pnpm-lock.yaml
pnpm-workspace.yaml
**/pnpm-workspace.yaml
package-lock.json
**/package-lock.json
yarn.lock
**/yarn.lock
*.config.*
**/*.config.*
tsconfig*.json
**/tsconfig*.json
.npmrc
**/.npmrc
.nvmrc
.node-version
**/.env*
.env*
**/Dockerfile*
**/.lintstagedrc*
**/.prettierignore
.prettierignore
**/components.json
.github/**
.claude/**
**/.claude/**
CLAUDE.md
**/CLAUDE.md
EOF
)"

# light_route_main_reference <root>: the ref that bounds the walk, with the
# base resolver's precedence: the declared base ref under Actions, then
# origin/main, then main.
light_route_main_reference() {
  local root="$1"
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_BASE_REF:-}" ] \
    && git -C "$root" rev-parse --verify --quiet "origin/${GITHUB_BASE_REF}" >/dev/null 2>&1; then
    printf 'origin/%s' "$GITHUB_BASE_REF"
  elif git -C "$root" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    printf 'origin/main'
  elif git -C "$root" rev-parse --verify --quiet main >/dev/null 2>&1; then
    printf 'main'
  else
    printf 'origin/main'
  fi
}

# light_route_diff <root> <diff-args...>: `git diff` with every option that
# config could use to change what it reports pinned: literal pathspecs (a file
# name is never a pathspec glob), no renames, no external diff or textconv,
# and submodule changes always shown.
light_route_diff() {
  local root="$1"
  shift
  git --literal-pathspecs -C "$root" -c core.quotepath=false diff --no-renames --no-ext-diff \
    --no-textconv --no-color --ignore-submodules=none "$@"
}

# light_route_full_anchor_trees <version>: reads clearance_scan earned lines on
# stdin and prints the tree of every `review: full` line recorded at <version>.
# Fields are split by expansion, not `IFS=$'\t' read`: tab is IFS whitespace,
# so read collapses an empty field (a body with no sha) and shifts `review`.
light_route_full_anchor_trees() {
  local version="$1" tab line rest tree recorded_version review
  tab="$(printf '\t')"
  while IFS= read -r line; do
    tree="${line%%"$tab"*}"
    rest="${line#*"$tab"}"
    recorded_version="${rest%%"$tab"*}"
    rest="${rest#*"$tab"}"
    rest="${rest#*"$tab"}"
    review="${rest%%"$tab"*}"
    [ -n "$tree" ] && [ "$review" = "full" ] && [ "$recorded_version" = "$version" ] || continue
    printf '%s\n' "$tree"
  done
}

# light_route_post_ranges <root> <anchor> <head> <path>: the post-image changed
# line ranges of one path as a JSON array, from its -U0 hunks. A pure deletion
# hunk has no post-image lines and adds no range.
light_route_post_ranges() {
  light_route_diff "$1" -U0 "$2" "$3" -- "$4" 2>/dev/null | awk '
    /^@@ / {
      field = $3; sub(/^\+/, "", field)
      count = 1
      if (index(field, ",") > 0) { split(field, parts, ","); start = parts[1]; count = parts[2] } else { start = field }
      if (count + 0 > 0) { out = out (out == "" ? "" : ",") "[" start "," (start + count - 1) "]" }
    }
    END { print "[" out "]" }'
}

# light_route_read_delta <root> <anchor> <head> <scratch-directory>: the raw
# and numstat rows over anchor..head, aligned by index into LIGHT_DELTA_PATH,
# LIGHT_DELTA_SOURCE_MODE, LIGHT_DELTA_TARGET_MODE, LIGHT_DELTA_ADDED and
# LIGHT_DELTA_DELETED, with LIGHT_DELTA_COUNT rows. Returns 1 on a git failure
# or when the two listings disagree on count or path. NUL-delimited reads keep
# any path byte intact; a path holding a newline is the caller's to refuse.
# The arrays are this function's output, read only by its caller.
# shellcheck disable=SC2034
light_route_read_delta() {
  local root="$1" anchor="$2" head="$3" scratch="$4" tab meta path record rest index=0
  tab="$(printf '\t')"
  LIGHT_DELTA_COUNT=0
  LIGHT_DELTA_PATH=()
  LIGHT_DELTA_SOURCE_MODE=()
  LIGHT_DELTA_TARGET_MODE=()
  LIGHT_DELTA_ADDED=()
  LIGHT_DELTA_DELETED=()
  light_route_diff "$root" --raw -z --no-abbrev "$anchor" "$head" >"$scratch/raw" 2>/dev/null || return 1
  light_route_diff "$root" --numstat -z "$anchor" "$head" >"$scratch/numstat" 2>/dev/null || return 1
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    meta="${meta#:}"
    LIGHT_DELTA_SOURCE_MODE[LIGHT_DELTA_COUNT]="${meta%% *}"
    rest="${meta#* }"
    LIGHT_DELTA_TARGET_MODE[LIGHT_DELTA_COUNT]="${rest%% *}"
    LIGHT_DELTA_PATH[LIGHT_DELTA_COUNT]="$path"
    LIGHT_DELTA_COUNT=$((LIGHT_DELTA_COUNT + 1))
  done <"$scratch/raw"
  while IFS= read -r -d '' record; do
    [ "$index" -lt "$LIGHT_DELTA_COUNT" ] || return 1
    rest="${record#*"$tab"}"
    [ "${rest#*"$tab"}" = "${LIGHT_DELTA_PATH[$index]}" ] || return 1
    LIGHT_DELTA_ADDED[index]="${record%%"$tab"*}"
    LIGHT_DELTA_DELETED[index]="${rest%%"$tab"*}"
    index=$((index + 1))
  done <"$scratch/numstat"
  [ "$index" -eq "$LIGHT_DELTA_COUNT" ]
}

# light_route_hard_full_rule <path> <member-globs>: prints the first floor glob,
# then the first newline-separated member glob, that <path> matches, and
# returns 0; returns 1 when none matches and 2 when the shared matcher errors.
# Every test goes through audit_glob_matches, so the floor reads the roster's
# own glob dialect.
light_route_hard_full_rule() {
  local path="$1" glob status
  command -v audit_glob_matches >/dev/null 2>&1 || return 2
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    status=0
    audit_glob_matches "$glob" "$path" || status=$?
    case "$status" in
      0) printf '%s\n' "$glob"; return 0 ;;
      1) ;;
      *) return 2 ;;
    esac
  done <<EOF
$LIGHT_ROUTE_FLOOR_GLOBS
$2
EOF
  return 1
}
