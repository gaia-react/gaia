#!/usr/bin/env bats
#
# Pins the prose cut from the Code Audit Team member definitions and the shared
# protocol. Where a paragraph was cut to a one-line rule, a maintainer-only
# block directly after the line names the bats file and test that enforces the
# rest; this suite checks each pointer is real (the enforcer file exists and
# exactly one of its test lines carries the named substring), that no enforcer
# path leaks outside a maintainer-only block into text an adopter reads, that
# the deleted prose stays deleted, and that the prose deliberately kept
# verbatim (nothing enforces it but the text) stays.
#
# Every assertion is about the tree as it stands. Each helper takes the file or
# root it reads so a scratch copy proves a case can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PROTOCOL_RELATIVE='.claude/hooks/lib/audit-member-protocol.md'
  FRONTEND_RELATIVE='.claude/agents/code-audit-frontend.md'
  WORKFLOWS_RELATIVE='.claude/agents/code-audit-github-workflows.md'
  NODE_RELATIVE='.claude/agents/code-audit-maintainer-node.md'
  SHELL_RELATIVE='.claude/agents/code-audit-maintainer-shell.md'
  START_MARKER='<!-- gaia:maintainer-only:start -->'
  END_MARKER='<!-- gaia:maintainer-only:end -->'
}

# cut_rows: one row per cut that landed, `<file>|<anchor>|<enforcer>|<substring>`.
# The anchor is the opening of the one-line rule; the substring is part of a
# test name, never the whole name.
cut_rows() {
  cat <<'ROWS'
.claude/hooks/lib/audit-member-protocol.md|The marker is keyed to your branch-own digest|.gaia/scripts/tests/audit-catchup-merge.bats|a clean catch-up leaves every digest, every marker and the loop state alone
.claude/hooks/lib/audit-member-protocol.md|The merge gate checks refusals before earned markers|.gaia/tests/hooks/pr-merge-audit-check.bats|a live refusal for the SAME digest denies even with a valid earned marker present
.claude/hooks/lib/audit-member-protocol.md|Stage the array as a fresh `printf` redirect|.gaia/tests/lib/doc-audit-findings-staging.bats|no spec pipes the payload into the writer
.claude/agents/code-audit-frontend.md|**Incremental scope.**|.github/audit/tests/resolve-audit-base.bats|reason token: member-refusal
.claude/agents/code-audit-frontend.md|**The branch's own patch, at HEAD, is the whole point.**|.gaia/scripts/tests/audit-blend-scope.bats|a clean catch-up of the base rotates no digest
ROWS
}

# strip_maintainer_blocks <file>: prints the file without its maintainer-only
# marker blocks, the text an adopter's scrubbed copy carries.
strip_maintainer_blocks() {
  awk '
    index($0, "<!-- gaia:maintainer-only:start -->") { inside = 1; next }
    index($0, "<!-- gaia:maintainer-only:end -->") { inside = 0; next }
    !inside { print }
  ' "$1"
}

# check_cut_row <document root> <row>: the anchor occurs once in the document
# on a fence-free line of at most 300 characters outside every maintainer-only
# block; the block directly after it (blank lines allowed between) names the
# enforcer path and the substring; the enforcer file, read from the real tree,
# exists and exactly one of its test lines contains the substring.
check_cut_row() {
  local document_root="$1" row="$2"
  local file anchor enforcer substring document
  IFS='|' read -r file anchor enforcer substring <<<"$row"
  document="$document_root/$file"
  [ -f "$document" ] || { echo "$document is missing" >&2; return 1; }

  local total outside
  total="$(grep -cF -- "$anchor" "$document" || true)"
  outside="$(strip_maintainer_blocks "$document" | grep -cF -- "$anchor" || true)"
  [ "$total" -eq 1 ] && [ "$outside" -eq 1 ] || {
    echo "$file: anchor [$anchor] occurs $total times, $outside outside blocks" >&2
    return 1
  }

  local line_number line_text
  line_number="$(grep -nF -- "$anchor" "$document" | head -n 1 | cut -d: -f1)"
  line_text="$(sed -n "${line_number}p" "$document")"
  [ "${#line_text}" -le 300 ] || { echo "$file: rule line is ${#line_text} characters" >&2; return 1; }
  case "$line_text" in
    *'```'*) echo "$file: rule line carries a code fence" >&2; return 1 ;;
  esac

  local block
  block="$(awk -v start_line="$line_number" -v start_marker="$START_MARKER" -v end_marker="$END_MARKER" '
    NR <= start_line { next }
    state == 0 && $0 == "" { next }
    state == 0 && $0 == start_marker { state = 1; next }
    state == 0 { exit }
    state == 1 && $0 == end_marker { exit }
    state == 1 { print }
  ' "$document")"
  [ -n "$block" ] || { echo "$file: no maintainer-only block directly after [$anchor]" >&2; return 1; }
  grep -qF -- "$enforcer" <<<"$block" || { echo "$file: block does not name $enforcer" >&2; return 1; }
  grep -qF -- "$substring" <<<"$block" || { echo "$file: block does not name [$substring]" >&2; return 1; }

  local enforcer_file="$REPO_ROOT/$enforcer" matching
  [ -f "$enforcer_file" ] || { echo "$enforcer does not exist" >&2; return 1; }
  matching="$(grep -E -- '^@test ' "$enforcer_file" | grep -cF -- "$substring" || true)"
  [ "$matching" -eq 1 ] || { echo "$enforcer: $matching test lines contain [$substring]" >&2; return 1; }
  return 0
}

# assert_no_enforcer_path_outside_blocks <file>
assert_no_enforcer_path_outside_blocks() {
  local hits
  hits="$(strip_maintainer_blocks "$1" | grep -nE -- '\.gaia/tests/|\.gaia/scripts/tests/|\.github/audit/tests/' || true)"
  [ -z "$hits" ] || { echo "$1: $hits" >&2; return 1; }
  return 0
}

# assert_absent <file> <fixed phrase>
assert_absent() {
  grep -qF -- "$2" "$1" && { echo "$1 still carries [$2]" >&2; return 1; }
  return 0
}

# assert_present <file> <fixed phrase>
assert_present() {
  grep -qF -- "$2" "$1" || { echo "$1 lost [$2]" >&2; return 1; }
  return 0
}

# unfence_first_pointer <in> <out>: copies the file with the first enforcer
# pointer's maintainer-only markers removed, leaving the pointer in plain text.
unfence_first_pointer() {
  awk -v start_marker="$START_MARKER" -v end_marker="$END_MARKER" '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (!done && lines[i] == start_marker && index(lines[i + 1], "Enforced by ") == 1 && index(lines[i + 2], end_marker) == 1) {
          done = 1; skip_end = i + 2; continue
        }
        if (i == skip_end) continue
        print lines[i]
      }
    }
  ' "$1" >"$2"
}

# --- the table and its pointers -------------------------------------------------

# bats test_tags=whole-tree
@test "the table has a row for every cut and each row's pointer, anchor and enforcer hold" {
  local row count=0
  while IFS= read -r row; do
    check_cut_row "$REPO_ROOT" "$row" || return 1
    count=$((count + 1))
  done < <(cut_rows)
  [ "$count" -eq 5 ] || { echo "expected 5 rows, read $count" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "every maintainer-only block that names an enforcer path is a table row's pointer" {
  local document block_count row_count
  for document in "$REPO_ROOT/$PROTOCOL_RELATIVE" "$REPO_ROOT/$FRONTEND_RELATIVE"; do
    block_count="$(grep -c '^Enforced by ' "$document" || true)"
    row_count="$(cut_rows | grep -cF -- "${document#"$REPO_ROOT"/}|" || true)"
    [ "$block_count" -eq "$row_count" ] || {
      echo "$document: $block_count pointers, $row_count table rows" >&2
      return 1
    }
  done
}

# bats test_tags=whole-tree
@test "no enforcer path appears in the protocol or the frontend definition outside a maintainer-only block" {
  assert_no_enforcer_path_outside_blocks "$REPO_ROOT/$PROTOCOL_RELATIVE"
  assert_no_enforcer_path_outside_blocks "$REPO_ROOT/$FRONTEND_RELATIVE"
}

# --- deleted prose stays deleted -------------------------------------------------

# bats test_tags=whole-tree
@test "the frontend definition no longer carries its deleted sections or restatements" {
  local phrase
  for phrase in \
    '## Durable knowledge' \
    'Candidate wiki updates' \
    '### Subagent instructions template' \
    'You are an adversarial reviewer' \
    'wrong, or will produce broken work'; do
    assert_absent "$REPO_ROOT/$FRONTEND_RELATIVE" "$phrase" || return 1
  done
}

# bats test_tags=whole-tree
@test "the workflows definition no longer points at the harness triage threshold" {
  assert_absent "$REPO_ROOT/$WORKFLOWS_RELATIVE" 'harness-triage-threshold.md'
}

# bats test_tags=whole-tree
@test "the workflows, node and shell definitions no longer carry the Write-or-Edit refusal clause" {
  local relative
  for relative in "$WORKFLOWS_RELATIVE" "$NODE_RELATIVE" "$SHELL_RELATIVE"; do
    assert_absent "$REPO_ROOT/$relative" 'a `Write` or `Edit` naming a path there is refused' || return 1
  done
}

# --- prose kept verbatim stays ---------------------------------------------------

# bats test_tags=whole-tree
@test "the protocol keeps every DIRTY paragraph" {
  local phrase
  for phrase in \
    '- `DIRTY=` lines name entries in your review increment whose working-tree bytes differ from HEAD.' \
    '**Any `DIRTY=` line WITHHOLDS this pass.**' \
    'On a `DIRTY=` line that survives your remit filter'; do
    assert_present "$REPO_ROOT/$PROTOCOL_RELATIVE" "$phrase" || return 1
  done
}

# bats test_tags=whole-tree
@test "the protocol keeps the literal-values rule, its precedence clause and the digest-capture opening" {
  local phrase
  for phrase in \
    '**From here on, every value travels as a literal typed into the command, never as a shell variable or a command substitution.**' \
    'Where your definition and this file differ' \
    'Capture your own branch-own digest at scope resolution'; do
    assert_present "$REPO_ROOT/$PROTOCOL_RELATIVE" "$phrase" || return 1
  done
}

# bats test_tags=whole-tree
@test "the workflows, node and shell definitions keep the narrower-CHANGED risk paragraph" {
  local relative
  for relative in "$WORKFLOWS_RELATIVE" "$NODE_RELATIVE" "$SHELL_RELATIVE"; do
    assert_present "$REPO_ROOT/$relative" 'A narrower `CHANGED` shifts one risk onto you' || return 1
  done
}

# --- red twins: scratch copies, each helper must fail ------------------------------

# bats test_tags=whole-tree
@test "red twin: a row naming a substring no enforcer test line contains fails" {
  local row
  row="$(cut_rows | head -n 1)"
  row="${row%|*}|a substring that no test line in the enforcer could ever contain"
  run check_cut_row "$REPO_ROOT" "$row"
  [ "$status" -ne 0 ]
}

@test "red twin: a protocol copy with one enforcer pointer outside its block fails the row check" {
  local scratch="$BATS_TEST_TMPDIR/root" row
  mkdir -p "$scratch/.claude/hooks/lib"
  unfence_first_pointer "$REPO_ROOT/$PROTOCOL_RELATIVE" "$scratch/$PROTOCOL_RELATIVE"
  row="$(cut_rows | head -n 1)"
  run check_cut_row "$scratch" "$row"
  [ "$status" -ne 0 ]
}

@test "red twin: a protocol copy with one enforcer pointer outside its block fails the leak check" {
  local scratch="$BATS_TEST_TMPDIR/protocol.md"
  unfence_first_pointer "$REPO_ROOT/$PROTOCOL_RELATIVE" "$scratch"
  grep -qF -- 'Enforced by ' "$scratch" || { echo "twin was not built" >&2; return 1; }
  run assert_no_enforcer_path_outside_blocks "$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: a frontend copy with the deleted durable-knowledge heading restored fails the absence check" {
  local scratch="$BATS_TEST_TMPDIR/frontend.md"
  { cat "$REPO_ROOT/$FRONTEND_RELATIVE"; printf '\n## Durable knowledge\n'; } >"$scratch"
  run assert_absent "$scratch" '## Durable knowledge'
  [ "$status" -ne 0 ]
}

@test "red twin: a protocol copy without the precedence clause fails the presence check" {
  local scratch="$BATS_TEST_TMPDIR/protocol.md"
  sed 's/Where your definition and this file differ/Elsewhere/' "$REPO_ROOT/$PROTOCOL_RELATIVE" >"$scratch"
  run assert_present "$scratch" 'Where your definition and this file differ'
  [ "$status" -ne 0 ]
}
