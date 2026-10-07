#!/usr/bin/env bats
#
# Permanent guard that the retired /gaia-wiki stage arguments and the deleted
# `gaia wiki sync land` subcommand stay gone.
#
#   UAT-007: no tracked file outside the allowlist invokes a /gaia-wiki stage
#            (the stage name, a menu of stage names, a stage placeholder, or an
#            "any sub-command" note after the command), and every allowlist
#            entry still matches a hit. Both committed CLI bundles are tracked,
#            so a stale bundle string is caught too.
#   UAT-015: no tracked file outside the history ledgers and this guard's own
#            two files names the removed sync-land subcommand.
#
# The matchers are functions over an explicit root, so the real tree and the
# scratch trees that prove them able to fail run the same code. The banned
# forms below are written as literals on purpose: an allowlist entry for this
# file must match a hit, so the suite carries the forms it forbids.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  ALLOWLIST="$REPO_ROOT/.gaia/tests/fixtures/wiki-stage-args-retired.allowlist"
  STAGE_PATTERN='/gaia-wiki`?[[:space:]]+`?(sync|consolidate|lint)([^[:alnum:]_]|$)|/gaia-wiki`?[[:space:]]*\[(sync|consolidate|lint)|/gaia-wiki`?[[:space:]]*<stage>|/gaia-wiki`?[[:space:]]*\(any sub-command\)'
  LAND_PATTERN='sync[ -]land'
}

# Allowlist lines with comments and blanks dropped.
allowlist_entries() {
  grep -vE '^[[:space:]]*(#|$)' "$1" || true
}

# True when path $1 matches any entry (a literal path or a glob) read from $2.
path_is_allowlisted() {
  local path="$1" entry
  while IFS= read -r entry; do
    # shellcheck disable=SC2254
    case "$path" in
      $entry) return 0 ;;
    esac
  done < <(allowlist_entries "$2")
  return 1
}

# Tracked files under root $1 matching the stage pattern. The log and hot pages
# are scan exclusions: they are rewritten each sync and can be hit-free, so the
# still-matches check must never apply to them.
stage_hit_files() {
  git -C "$1" grep -l -E "$STAGE_PATTERN" -- . ':!wiki/log.md' ':!wiki/hot.md' || true
}

# Print each stage hit under root $1 as path:line:text, for files matching no
# entry in allowlist $2.
unallowlisted_hits() {
  local root="$1" allowlist="$2" hit
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if ! path_is_allowlisted "$hit" "$allowlist"; then
      git -C "$root" grep -n -E "$STAGE_PATTERN" -- "$hit" | sed "s|^|$hit |" || true
    fi
  done < <(stage_hit_files "$root")
}

# Print each allowlist entry under root $1 that matches no hit.
unused_entries() {
  local root="$1" allowlist="$2" entry hit used hits
  hits="$(stage_hit_files "$root")"
  while IFS= read -r entry; do
    used=0
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      # shellcheck disable=SC2254
      case "$hit" in
        $entry) used=1 ;;
      esac
    done <<<"$hits"
    [ "$used" -eq 1 ] || printf '%s\n' "$entry"
  done < <(allowlist_entries "$allowlist")
}

# The stage guard: exit 0 only when there is no offending hit and no unused entry.
guard_stage_args() {
  local root="$1" allowlist="$2" offenders unused
  offenders="$(unallowlisted_hits "$root" "$allowlist")"
  unused="$(unused_entries "$root" "$allowlist")"
  if [ -n "$offenders" ]; then
    printf 'not allowlisted:\n%s\n' "$offenders" >&2
  fi
  if [ -n "$unused" ]; then
    printf 'unused allowlist entries:\n%s\n' "$unused" >&2
  fi
  [ -z "$offenders" ] && [ -z "$unused" ]
}

# The sync-land scan: prints path:line for every hit outside the ledgers, the
# frozen routing fixture, and this guard's two files; exit 0 only when none.
guard_sync_land() {
  local root="$1" hits
  hits="$(git -C "$root" grep -n -E "$LAND_PATTERN" -- . \
    ':!CHANGELOG.md' ':!wiki/log.md' ':!wiki/hot.md' ':!wiki/meta/**' \
    ':!.gaia/tests/hooks/fixtures/audit-routing-before.tsv' \
    ':!.gaia/tests/lib/wiki-stage-args-retired.bats' \
    ':!.gaia/tests/fixtures/wiki-stage-args-retired.allowlist' || true)"
  if [ -n "$hits" ]; then
    printf 'sync land mentions:\n%s\n' "$hits" >&2
    return 1
  fi
  return 0
}

# A scratch repo with one tracked skill file holding exactly line $1, and an
# empty allowlist.
make_scratch_tree() {
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$SCRATCH/.claude/skills/x"
  git -C "$SCRATCH" init -q
  printf '%s\n' "$1" >"$SCRATCH/.claude/skills/x/SKILL.md"
  git -C "$SCRATCH" add .claude/skills/x/SKILL.md
  SCRATCH_ALLOWLIST="$BATS_TEST_TMPDIR/scratch.allowlist"
  : >"$SCRATCH_ALLOWLIST"
}

@test "UAT-007: no tracked file outside the allowlist invokes a retired stage, and no entry is unused" {
  run guard_stage_args "$REPO_ROOT" "$ALLOWLIST"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-015: no tracked file outside the ledgers names the removed sync-land subcommand" {
  run guard_sync_land "$REPO_ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-007 can fail: a stage name after the command is flagged with file and line" {
  make_scratch_tree '/gaia-wiki sync'
  run guard_stage_args "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *".claude/skills/x/SKILL.md"* ]]
  [[ "$output" == *":1:"* ]]
}

@test "UAT-007 can fail: a backticked command followed by a stage name is flagged with file and line" {
  make_scratch_tree '`/gaia-wiki` consolidate'
  run guard_stage_args "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *".claude/skills/x/SKILL.md"* ]]
  [[ "$output" == *":1:"* ]]
}

@test "UAT-007 can fail: a bracketed menu of stage names is flagged with file and line" {
  make_scratch_tree '/gaia-wiki [sync|consolidate|lint]'
  run guard_stage_args "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *".claude/skills/x/SKILL.md"* ]]
  [[ "$output" == *":1:"* ]]
}

@test "UAT-007 can fail: a stage placeholder is flagged with file and line" {
  make_scratch_tree '/gaia-wiki <stage>'
  run guard_stage_args "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *".claude/skills/x/SKILL.md"* ]]
  [[ "$output" == *":1:"* ]]
}

@test "UAT-007 can fail: an any-sub-command note is flagged with file and line" {
  make_scratch_tree '`/gaia-wiki` (any sub-command)'
  run guard_stage_args "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *".claude/skills/x/SKILL.md"* ]]
  [[ "$output" == *":1:"* ]]
}

@test "UAT-007: prose that names the command and the stages without invoking a stage passes" {
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$SCRATCH/.claude/skills/x"
  git -C "$SCRATCH" init -q
  {
    printf '%s\n' '`/gaia-wiki` lints the wiki'
    printf '%s\n' 'run bare `/gaia-wiki`'
    printf '%s\n' '/gaia-wiki full-chain landing (sync + consolidate + lint)'
    printf '%s\n' 'the sync stage of `/gaia-wiki`'
    printf '%s\n' "\`/gaia-wiki\`'s lint stage"
  } >"$SCRATCH/.claude/skills/x/SKILL.md"
  git -C "$SCRATCH" add .claude/skills/x/SKILL.md
  SCRATCH_ALLOWLIST="$BATS_TEST_TMPDIR/scratch.allowlist"
  : >"$SCRATCH_ALLOWLIST"
  run guard_stage_args "$SCRATCH" "$SCRATCH_ALLOWLIST"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-007 can fail: an allowlist entry that matches no hit is flagged" {
  make_scratch_tree '/gaia-wiki sync'
  printf '.claude/skills/x/SKILL.md\nnever-matches.md\n' >"$SCRATCH_ALLOWLIST"
  run guard_stage_args "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never-matches.md"* ]]
}

@test "UAT-007: the matcher passes a scratch tree whose only hit is allowlisted" {
  make_scratch_tree '/gaia-wiki sync'
  printf '.claude/skills/x/SKILL.md\n' >"$SCRATCH_ALLOWLIST"
  run guard_stage_args "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -eq 0 ]
}

@test "UAT-015 can fail: a tracked file naming the removed subcommand is flagged with file and line" {
  make_scratch_tree 'run gaia wiki sync land afterwards'
  run guard_sync_land "$SCRATCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *".claude/skills/x/SKILL.md:1:"* ]]
}

@test "UAT-007: the scanned set is non-empty and includes both committed CLI bundles" {
  local tracked
  tracked="$(git -C "$REPO_ROOT" ls-files -z -- .gaia/cli/gaia .gaia/cli/gaia-maintainer | tr '\0' '\n')"
  [[ "$tracked" == *".gaia/cli/gaia"$'\n'* ]]
  [[ "$tracked" == *".gaia/cli/gaia-maintainer" ]]
  [ "$(printf '%s\n' "$tracked" | wc -l | tr -d ' ')" -eq 2 ]
}
