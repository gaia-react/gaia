#!/usr/bin/env bats
#
# Doc-conformance suite: /gaia-spec runs as one explicit, script-driven
# workflow with no dependency on a spec-kit core install. Step 3 carries the
# allocate, anchor, and stamp duties itself, step 10 runs the lint script
# directly, and neither the reference, the template, nor the allocator header
# names a spec-kit mechanism.
#
# Tokens the removed-automation guard forbids anywhere in the tree are built at
# runtime (concatenation) so this file never carries one contiguously.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"
  TEMPLATE="$REPO_ROOT/.claude/skills/gaia/references/spec/spec-template.md"
  ALLOCATOR="$REPO_ROOT/.gaia/scripts/spec/spec-allocator.sh"
  LINT="$REPO_ROOT/.gaia/scripts/spec/lint.sh"

  slash_command_prefix="/spec""kit-"
  hook_pre_draft="before""_specify"
  hook_post_draft="after""_specify"
  hook_post_clarify="after""_clarify"
  execute_command="EXECUTE""_COMMAND"
}

_anchor_line() {
  grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1
}

# Text between two fixed-string anchors in a file: [start_anchor, end_anchor).
# Both anchors are checked so a moved heading fails legibly instead of
# emptying the range and letting every absence assertion pass.
range_between() {
  local file="$1" start_pattern="$2" end_pattern="$3" start_line end_line
  start_line="$(_anchor_line "$file" "$start_pattern")"
  end_line="$(_anchor_line "$file" "$end_pattern")"
  [ -n "$start_line" ] || { printf 'start anchor not found in %s: %s\n' "$file" "$start_pattern" >&2; return 1; }
  [ -n "$end_line" ] || { printf 'end anchor not found in %s: %s\n' "$file" "$end_pattern" >&2; return 1; }
  sed -n "${start_line},$((end_line - 1))p" "$file"
}

step3_range() {
  range_between "$SPEC_MD" '### 3. Initial draft (allocate, anchor, stamp)' '### 4. Gate 1'
}

@test "a filled template lints clean" {
  filled="$BATS_TEST_TMPDIR/filled.md"
  sed 's/SPEC-NNN/SPEC-001/;s/UAT-NNN/UAT-001/' "$TEMPLATE" > "$filled"

  run bash "$LINT" "$filled"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

# "No specs/" means no bare core feature-tree path. The folder-creation fence
# legitimately carries `.gaia/local/specs/`, which the regex below does not
# match because a slash precedes `specs/`.
@test "step 3 carries no core path" {
  range="$(step3_range)"
  [ -n "$range" ]

  printf '%s\n' "$range" | grep -qF -- "$slash_command_prefix" && return 1
  printf '%s\n' "$range" | grep -qF -- 'feature.json' && return 1
  printf '%s\n' "$range" | grep -qF -- 'git checkout -b' && return 1
  printf '%s\n' "$range" | grep -qF -- 'git switch -c' && return 1
  printf '%s\n' "$range" | grep -qE -- '(^|[^a-z/])specs/' && return 1
  true
}

@test "step 3 carries the absorbed duties" {
  range="$(step3_range)"
  [ -n "$range" ]

  # shellcheck disable=SC2016  # needles are literal fence text, not expansions
  for needle in \
    'spec-allocator.sh next "$PWD"' \
    'SPEC_ID' \
    'main-root-lib.sh' \
    'mkdir -p "${MAIN_ROOT}/.gaia/local/specs/${SPEC_ID}"' \
    'references/spec/spec-template.md' \
    'draft-' \
    'spec_id' 'type' 'status' 'immutable' 'wiki_promote_default' 'chain_trigger' 'created' 'updated'; do
    if ! printf '%s\n' "$range" | grep -qF -- "$needle"; then
      printf 'step 3 is missing: %s\n' "$needle" >&2
      return 1
    fi
  done
  true
}

# no_spec_kit_mechanism <references-dir>: succeeds when spec.md and every
# spec/<name>.md it names carry no spec-kit mechanism. The set is derived from
# spec.md's own routes, so text moved into a sub-reference stays checked. A
# named file that does not exist, or a pass that reads fewer files than
# spec.md names, fails rather than narrowing the check.
no_spec_kit_mechanism() {
  local dir="$1" names name files file count=0 expected
  [ -f "$dir/spec.md" ] || return 1
  names="$(grep -oE -- '(^|[^A-Za-z0-9_-])spec/[A-Za-z0-9_-]+\.md' "$dir/spec.md" | sed -E 's|^.*spec/||' | sort -u)"
  [ -n "$names" ] || return 1
  files="$dir/spec.md"
  while IFS= read -r name; do
    if [ ! -f "$dir/spec/$name" ]; then
      printf 'spec.md names missing spec/%s\n' "$name" >&2
      return 1
    fi
    files="$files
$dir/spec/$name"
  done <<<"$names"
  expected=$(($(printf '%s\n' "$names" | wc -l) + 1))
  while IFS= read -r file; do
    count=$((count + 1))
    grep -n -i -E 'speckit|spec-kit|preset' "$file" && return 1
    grep -n -F 'from another file under another agent' "$file" && return 1
    grep -n -E "${execute_command}|${hook_pre_draft}|${hook_post_draft}|${hook_post_clarify}|How spec-kit fires" "$file" && return 1
  done <<<"$files"
  [ "$count" -eq "$expected" ] || return 1
  [ "$count" -ge 2 ] || return 1
  return 0
}

@test "spec.md and every sub-reference it routes to name no spec-kit mechanism" {
  no_spec_kit_mechanism "$REPO_ROOT/.claude/skills/gaia/references"
}

@test "the spec-kit check goes red on a mechanism planted in a sub-reference" {
  copy="$BATS_TEST_TMPDIR/references"
  mkdir -p "$copy"
  cp "$SPEC_MD" "$copy/spec.md"
  cp -R "$REPO_ROOT/.claude/skills/gaia/references/spec" "$copy/spec"
  no_spec_kit_mechanism "$copy"
  printf '\nRun the speckit hook here.\n' >>"$copy/spec/clarify-loop.md"
  run no_spec_kit_mechanism "$copy"
  [ "$status" -ne 0 ]
}

@test "step 10 runs the lint script directly" {
  range="$(range_between "$SPEC_MD" '### 10. Immutability lint' '### 11.')"
  [ -n "$range" ]
  if ! printf '%s\n' "$range" | grep -qF -- 'bash .gaia/scripts/spec/lint.sh'; then
    printf 'step 10 does not run lib/lint.sh directly\n' >&2
    return 1
  fi
  true
}

@test "the allocator header names no preset" {
  grep -i 'speckit preset' "$ALLOCATOR" && return 1
  true
}

@test "the template heading is Preconditions with no hook language" {
  [ "$(grep -c '^## Preconditions$' "$TEMPLATE")" -eq 1 ]
  grep -i -E 'constitution|before_' "$TEMPLATE" && return 1
  true
}
