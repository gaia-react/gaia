#!/usr/bin/env bats
#
# Suite for .gaia/scripts/knowledge-inventory.sh, the deterministic half of
# /gaia-audit (.claude/skills/gaia/references/audit.md): the store inventory
# Stage 1 records, the ownership answer both stages act on, and the check that
# lets a 0-action report finalize without a human. Each refusal has a green
# case and a red twin that changes one input, so every rule is shown to decide
# the answer rather than merely agree with it.
#
# Every test builds its own throwaway project and HOME. Set
# KNOWLEDGE_INVENTORY_SCRIPT to run the same assertions against a scratch copy.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/knowledge-inventory.bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="${KNOWLEDGE_INVENTORY_SCRIPT:-$REPO_ROOT/.gaia/scripts/knowledge-inventory.sh}"
  export HOME="$BATS_TEST_TMPDIR/home"
  PROJECT="$BATS_TEST_TMPDIR/project"
  MEMORY="$HOME/.claude/projects/$(printf %s "$PROJECT" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
  USER_AGENT_MEMORY="$HOME/.claude/agent-memory"
  mkdir -p "$PROJECT/.gaia/vendor" "$PROJECT/.claude/rules" "$PROJECT/wiki/concepts" \
    "$PROJECT/.claude/agent-memory/reviewer" "$PROJECT/frontend" "$MEMORY" "$USER_AGENT_MEMORY/helper"
  git -C "$PROJECT" init -q
  jq -n '{version: "2.0.0", files: {".claude/rules/quality-gate.md": "owned", "CLAUDE.md": "shared", "wiki/concepts/Page.md": "wiki-owned"}}' \
    >"$PROJECT/.gaia/manifest.json"
  jq -n '{package: "pkg", version: "1.0.0", target: "frontend/.claude/skills/playwright-cli", files: {}}' \
    >"$PROJECT/.gaia/vendor/playwright-cli.json"
  printf '**/.claude/agent-memory/\n**/.claude/skills/react-doctor/\n' >"$PROJECT/.gitignore"

  printf 'one two three\n' >"$MEMORY/MEMORY.md"
  printf 'a fact\n' >"$MEMORY/fact.md"
  printf 'not markdown\n' >"$MEMORY/notes.txt"
  printf 'helper note\n' >"$USER_AGENT_MEMORY/helper/note.md"
  printf 'reviewer note\n' >"$PROJECT/.claude/agent-memory/reviewer/note.md"
  printf 'gate\n' >"$PROJECT/.claude/rules/quality-gate.md"
  printf 'mine\n' >"$PROJECT/.claude/rules/house.md"
  printf 'index\n' >"$PROJECT/wiki/index.md"
  printf 'page\n' >"$PROJECT/wiki/concepts/Page.md"
  printf 'root\n' >"$PROJECT/CLAUDE.md"
  printf 'nested\n' >"$PROJECT/frontend/CLAUDE.md"
}

EXPECTED_COUNTS="memory=2 user_agent_memory=1 project_agent_memory=1 rules=2 wiki=2 claude_md=2"

inventory() {
  run bash "$SCRIPT" "$1" --root "$PROJECT" "${@:2}"
}

# write_report <store-counts> [scope]: a clean 0-action report whose
# frontmatter records <store-counts> and <scope> (default full).
write_report() {
  REPORT="$BATS_TEST_TMPDIR/KNOWLEDGE-2026-10-08-1200.md"
  cat >"$REPORT" <<EOF
---
generated: 2026-10-08 12:00
status: draft
scope: ${2:-full}
store_counts: $1
project_root: $PROJECT
---

# Knowledge Audit, 2026-10-08 12:00

## Summary

- Actions proposed: 0
- Applied scope: ${2:-full}

## Actions

## Out-of-scope findings

None.
EOF
}

# class_of <path>: the class column of the output line for <path>.
class_of() {
  local line
  while IFS= read -r line; do
    if [ "${line#*$'\t'}" = "$1" ]; then
      printf '%s' "${line%%$'\t'*}"
      return 0
    fi
  done <<<"$output"
  return 1
}

# --- counts ---

@test "counts: one count per store, markdown files only" {
  inventory counts
  [ "$status" -eq 0 ]
  [ "$output" = "$EXPECTED_COUNTS" ]
}

@test "counts red twin: a new memory entry changes the memory count" {
  printf 'new\n' >"$MEMORY/new.md"
  inventory counts
  [ "$status" -eq 0 ]
  [ "$output" = "memory=3 user_agent_memory=1 project_agent_memory=1 rules=2 wiki=2 claude_md=2" ]
}

@test "counts: an absent store counts zero rather than failing" {
  rm -rf "$MEMORY" "$USER_AGENT_MEMORY" "$PROJECT/.claude/agent-memory"
  inventory counts
  [ "$status" -eq 0 ]
  [ "$output" = "memory=0 user_agent_memory=0 project_agent_memory=0 rules=2 wiki=2 claude_md=2" ]
}

@test "counts: a root with a dot and a plus reads the memory dir keyed with every non-alphanumeric as a dash" {
  local odd_root="$BATS_TEST_TMPDIR/odd.root+name"
  local odd_memory
  odd_memory="$HOME/.claude/projects/$(printf %s "$odd_root" | sed 's/[^A-Za-z0-9-]/-/g')/memory"
  mkdir -p "$odd_root" "$odd_memory"
  printf 'x\n' >"$odd_memory/one.md"
  run bash "$SCRIPT" counts --root "$odd_root"
  [ "$status" -eq 0 ]
  [[ "$output" == memory=1\ * ]]
}

@test "counts red twin: a memory dir keyed by slashes only is not read for a dotted root" {
  local odd_root="$BATS_TEST_TMPDIR/odd.root+name"
  local slash_only_memory
  slash_only_memory="$HOME/.claude/projects/$(printf %s "$odd_root" | sed 's|/|-|g')/memory"
  mkdir -p "$odd_root" "$slash_only_memory"
  printf 'x\n' >"$slash_only_memory/one.md"
  run bash "$SCRIPT" counts --root "$odd_root"
  [ "$status" -eq 0 ]
  [[ "$output" == memory=0\ * ]]
}

# --- list ---

@test "list: one row per file with store, path, word count, and mtime" {
  inventory list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 10 ]
  local row
  row="$(grep -F "$MEMORY/MEMORY.md" <<<"$output")"
  [ "$(cut -f1 <<<"$row")" = "memory" ]
  [ "$(cut -f3 <<<"$row")" = "3" ]
  [[ "$(cut -f4 <<<"$row")" =~ ^[0-9]+$ ]]
  grep -qF "notes.txt" <<<"$output" && return 1
  true
}

@test "list and counts agree per store" {
  inventory list
  local store expected
  for store in memory user_agent_memory project_agent_memory rules wiki claude_md; do
    expected="$(tr ' ' '\n' <<<"$EXPECTED_COUNTS" | sed -n "s/^$store=//p")"
    [ "$(cut -f1 <<<"$output" | grep -cx "$store")" -eq "$expected" ]
  done
}

# --- classify ---

@test "classify: project memory classifies project-memory" {
  inventory classify "$MEMORY/fact.md"
  [ "$status" -eq 0 ]
  [ "$(class_of "$MEMORY/fact.md")" = "project-memory" ]
}

@test "classify: project agent memory classifies project-memory although gitignored" {
  inventory classify "$PROJECT/.claude/agent-memory/reviewer/note.md"
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/agent-memory/reviewer/note.md)" = "project-memory" ]
}

@test "classify: user-scope agent memory classifies user-memory" {
  inventory classify "$USER_AGENT_MEMORY/helper/note.md"
  [ "$status" -eq 0 ]
  [ "$(class_of "$USER_AGENT_MEMORY/helper/note.md")" = "user-memory" ]
}

@test "classify red twin: a path climbing out of the memory dir is third-party" {
  inventory classify "$MEMORY/../../other/memory/x.md"
  [ "$status" -eq 0 ]
  [ "$(class_of "$MEMORY/../../other/memory/x.md")" = "third-party" ]
}

@test "classify: in-repo paths take the ownership classifier's classes" {
  inventory classify "$PROJECT/.claude/rules/quality-gate.md" "$PROJECT/.claude/rules/house.md" \
    "$PROJECT/frontend/.claude/skills/playwright-cli/SKILL.md" "$PROJECT/.claude/skills/react-doctor/SKILL.md" \
    "$PROJECT/wiki/concepts/Page.md"
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/rules/quality-gate.md)" = "gaia-shipped" ]
  [ "$(class_of .claude/rules/house.md)" = "adopter" ]
  [ "$(class_of frontend/.claude/skills/playwright-cli/SKILL.md)" = "third-party" ]
  [ "$(class_of .claude/skills/react-doctor/SKILL.md)" = "ignored" ]
  [ "$(class_of wiki/concepts/Page.md)" = "adopter" ]
}

@test "classify: output keeps input order across memory and in-repo paths" {
  inventory classify "$PROJECT/.claude/rules/house.md" "$MEMORY/fact.md" "$PROJECT/.claude/rules/quality-gate.md"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = $'adopter\t.claude/rules/house.md' ]
  [ "${lines[1]}" = "project-memory"$'\t'"$MEMORY/fact.md" ]
  [ "${lines[2]}" = $'gaia-shipped\t.claude/rules/quality-gate.md' ]
}

@test "classify: an unreadable manifest fails closed with nothing on stdout" {
  rm "$PROJECT/.gaia/manifest.json"
  run --separate-stderr bash "$SCRIPT" classify --root "$PROJECT" "$PROJECT/.claude/rules/house.md"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"manifest"* ]]
}

# --- verify ---

@test "verify: a full-scope 0-action report with matching counts is verified" {
  write_report "$EXPECTED_COUNTS"
  inventory verify "$REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == "verified: $EXPECTED_COUNTS" ]]
}

@test "verify red twin: a store whose count changed refuses and names the store" {
  write_report "$EXPECTED_COUNTS"
  printf 'new\n' >"$PROJECT/wiki/new.md"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse: store wiki: report 2, recomputed 3"* ]]
}

@test "verify red twin: a report that never counted a store refuses and names it" {
  write_report "memory=2 user_agent_memory=1 project_agent_memory=1 rules=2 claude_md=2"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse: store wiki: report none, recomputed 2"* ]]
}

@test "verify red twin: a report with no store counts refuses" {
  write_report "$EXPECTED_COUNTS"
  sed '/^store_counts:/d' "$REPORT" >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse: store memory: report none, recomputed 2"* ]]
}

@test "verify red twin: a scope hint refuses even with matching counts" {
  write_report "$EXPECTED_COUNTS"
  inventory verify "$REPORT" --scope-hint "memory only"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse: scope hint given"* ]]
}

@test "verify red twin: a report whose scope is not full refuses" {
  write_report "$EXPECTED_COUNTS" "wiki/"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse: report scope is wiki/, not full"* ]]
}

@test "verify red twin: a report carrying an action block refuses" {
  write_report "$EXPECTED_COUNTS"
  sed 's/^## Actions$/## Actions\
\
- [ ] `delete-001`/' "$REPORT" >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse: report carries 1 action block(s)"* ]]
}

@test "verify red twin: a Summary that does not say 0 actions refuses" {
  write_report "$EXPECTED_COUNTS"
  sed 's/^- Actions proposed: 0$/- Actions proposed: 2/' "$REPORT" >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse: Summary does not read Actions proposed: 0"* ]]
}

@test "verify red twin: a report cut off before its out-of-scope section refuses" {
  write_report "$EXPECTED_COUNTS"
  sed '/^## Out-of-scope findings$/,$d' "$REPORT" >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
  inventory verify "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse: report has no ## Out-of-scope findings section"* ]]
}

@test "verify: every refusal is named, not only the first" {
  write_report "$EXPECTED_COUNTS" "wiki/"
  printf 'new\n' >"$MEMORY/new.md"
  inventory verify "$REPORT" --scope-hint "wiki/"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^refuse: ' <<<"$output")" -eq 3 ]
}

@test "verify: a missing report exits 3" {
  inventory verify "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 3 ]
}

# --- usage ---

@test "usage: an unknown subcommand exits 2" {
  run bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

@test "usage: classify with no path exits 2" {
  inventory classify
  [ "$status" -eq 2 ]
}
