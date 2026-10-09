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

# light_route_main_reference <root>: the fully qualified local base reference
# that bounds the walk, from the same resolver every other local caller uses, so
# the walk, the digest and the changed set agree on one base. Non-zero when it
# does not resolve; there is no local-branch fallback.
light_route_main_reference() {
  audit_local_base_reference "$1"
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

# light_route_refusal_trees <version>: reads clearance_scan refused lines on
# stdin and prints the tree of every refusal recorded at <version>. A refusal
# carries no `review` kind, so the version is the only filter.
light_route_refusal_trees() {
  local version="$1" tab line rest tree recorded_version
  tab="$(printf '\t')"
  while IFS= read -r line; do
    tree="${line%%"$tab"*}"
    rest="${line#*"$tab"}"
    recorded_version="${rest%%"$tab"*}"
    [ -n "$tree" ] && [ "$recorded_version" = "$version" ] || continue
    printf '%s\n' "$tree"
  done
}

# light_route_pre_ranges <root> <anchor> <head> <path>: the pre-image changed
# line ranges of one path as a JSON array, from its -U0 hunks: the lines of
# <anchor> the delta rewrote or removed. A pure insertion has no pre-image
# lines; it is recorded as the two lines it sits between, so a finding cited on
# either neighbour counts as touched. This is the coordinate system a refusal's
# cited lines are in, because a refusal cites the tree it reviewed.
light_route_pre_ranges() {
  light_route_diff "$1" -U0 "$2" "$3" -- "$4" 2>/dev/null | awk '
    /^@@ / {
      field = $2; sub(/^-/, "", field)
      count = 1
      if (index(field, ",") > 0) { split(field, parts, ","); start = parts[1]; count = parts[2] } else { start = field }
      if (count + 0 > 0) { out = out (out == "" ? "" : ",") "[" start "," (start + count - 1) "]" }
      else { out = out (out == "" ? "" : ",") "[" start "," (start + 1) "]" }
    }
    END { print "[" out "]" }'
}

# light_route_refusal_checklist <root> <member> <refusal-tree> <branch-slug>:
# the open findings of the member's refusal at <refusal-tree>, as a JSON array
# of {key, path, line, severity, security, title} on stdout; returns 1 when the
# checklist cannot be established. The refusal is linked to its findings the way
# the clearance writer links them: the carry-forward ledger
# (<audit>/<base>.<slug>.rerun.json) records the refusal's tree under
# member_provenance and its remaining[] entries for the member carry the ids
# (`key`); the findings sidecar at the same key
# (<audit>/<base>.<slug>.<member>.findings.json) carries severity and security,
# which the ledger drops. The two lists are rebuilt together every round, so
# they must agree entry for entry on path and line; a disagreement, an empty
# list, an unsafe key or path, or a non-integer line is unreadable, and the
# caller routes an unreadable checklist Full.
light_route_refusal_checklist() {
  local root="$1" member="$2" refusal_tree="$3" slug="$4" audit_directory ledger key sidecar checklist
  [ -n "$slug" ] || return 1
  audit_directory="$root/.gaia/local/audit"
  for ledger in "$audit_directory"/*."$slug".rerun.json; do
    [ -f "$ledger" ] || continue
    jq -e --arg member "$member" --arg tree "$refusal_tree" \
      '(.member_provenance | type) == "object" and .member_provenance[$member].refusal_tree == $tree' "$ledger" >/dev/null 2>&1 || continue
    key="${ledger%.rerun.json}"
    sidecar="$key.$member.findings.json"
    [ -f "$sidecar" ] || continue
    checklist="$(jq -c -n --arg member "$member" --slurpfile ledger "$ledger" --slurpfile sidecar "$sidecar" '
      def safe_text: type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not) and (contains("\\") | not);
      ([$ledger[0].remaining[]? | objects | select(.member == $member)]) as $entries
      | ($sidecar[0].findings) as $findings
      | if ($findings | type) != "array" or ($entries | length) == 0 or ($entries | length) != ($findings | length)
        then error("shape")
        else [range(0; $entries | length) as $i
          | $entries[$i] as $entry | $findings[$i] as $finding
          | if ($entry.entry_id | type) == "string" and ($entry.entry_id | test("^[A-Za-z0-9._-]{1,64}$"))
               and ($finding.path | safe_text) and $finding.path == $entry.path
               and ($finding.line | type) == "number" and $finding.line == ($finding.line | floor)
               and $finding.line >= 1 and $finding.line == $entry.line
            then {key: $entry.entry_id, path: $finding.path, line: $finding.line,
                  severity: ($finding.severity // null),
                  security: ($finding | if has("security") then .security else null end),
                  title: (($finding.title // "") | if type == "string" then gsub("[\u0000-\u001f\u007f]"; " ") | .[0:200] else "" end)}
            else error("entry") end]
        end' 2>/dev/null)" || continue
    [ -n "$checklist" ] || continue
    printf '%s\n' "$checklist"
    return 0
  done
  return 1
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

# light_route_read_delta <root> <from-tree-ish> <head> <scratch-directory>
# <paths-file>: the raw and numstat rows of <from-tree-ish>..<head> restricted
# to the NUL-delimited paths in <paths-file>, aligned by index into
# LIGHT_DELTA_PATH, LIGHT_DELTA_SOURCE_MODE, LIGHT_DELTA_TARGET_MODE,
# LIGHT_DELTA_ADDED and LIGHT_DELTA_DELETED, with LIGHT_DELTA_COUNT rows. Two
# batched diffs; the diff command has no pathspec-file option, so the paths are
# arguments, and an argument list the OS refuses fails the diff (the caller
# routes that Full). An empty <paths-file> yields zero rows without running the
# diff, because an empty pathspec means every path. Returns 1 on a diff failure
# or when the two listings disagree on count or path. NUL-delimited reads keep
# any path byte intact; a path holding a newline is the caller's to refuse. The
# arrays are this function's output, read only by its caller.
# shellcheck disable=SC2034
light_route_read_delta() {
  local root="$1" from="$2" head="$3" scratch="$4" paths_file="$5" tab meta path record rest index=0 pathspecs=()
  tab="$(printf '\t')"
  LIGHT_DELTA_COUNT=0
  LIGHT_DELTA_PATH=()
  LIGHT_DELTA_SOURCE_MODE=()
  LIGHT_DELTA_TARGET_MODE=()
  LIGHT_DELTA_ADDED=()
  LIGHT_DELTA_DELETED=()
  while IFS= read -r -d '' path; do
    pathspecs[${#pathspecs[@]}]="$path"
  done <"$paths_file"
  [ "${#pathspecs[@]}" -gt 0 ] || return 0
  light_route_diff "$root" --raw -z --no-abbrev "$from" "$head" -- ${pathspecs[@]+"${pathspecs[@]}"} >"$scratch/raw" 2>/dev/null || return 1
  light_route_diff "$root" --numstat -z "$from" "$head" -- ${pathspecs[@]+"${pathspecs[@]}"} >"$scratch/numstat" 2>/dev/null || return 1
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
