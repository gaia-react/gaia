#!/usr/bin/env bats
#
# Doc-conformance suite for the shape of `/gaia-spec`'s playbook: the entry
# file .claude/skills/gaia/references/spec.md plus the sub-references under
# .claude/skills/gaia/references/spec/ that it reads at their branch points.
#
# The invariants:
#   a. spec.md stays under the 500-line playbook cap;
#   b. a sub-reference read is a step a model can skip, so every spec/<name>.md
#      that spec.md names exists and is listed in the command's sub-reference
#      index (.claude/commands/gaia-spec.md), each sub-reference moved out of
#      spec.md has a `Read` line there, and the self-review checklist carries
#      its marked bullet (read by the sub-agent, never the main thread);
#   c. each moved section lives in exactly one file of the playbook set;
#   d. the adversarial-auditor preamble lives only in the lens-dispatch
#      contract, never in the spec audit;
#   e. every spec/*.md over 100 lines carries a `Contents:` line outside any
#      code fence.
#
# DOC_SPEC_PLAYBOOK_ROOT points the suite at a scratch copy of the repo's
# playbook files; each invariant has a red twin that breaks such a copy and
# proves the check fails on it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAYBOOK_ROOT="${DOC_SPEC_PLAYBOOK_ROOT:-$REPO_ROOT}"
}

REFERENCES='.claude/skills/gaia/references'
COMMAND='.claude/commands/gaia-spec.md'

# The sub-references the split moved out of spec.md; each needs a Read line.
MOVED_SUB_REFERENCES=(resume.md clarify-loop.md self-review-dispatch.md audit.md)

# scratch_copy: copies spec.md, spec/ and the command file into the test's
# tmpdir under the same relative layout and prints the copy's root.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root"
  rm -rf "$copy"
  mkdir -p "$copy/$REFERENCES" "$copy/.claude/commands"
  cp "$PLAYBOOK_ROOT/$REFERENCES/spec.md" "$copy/$REFERENCES/spec.md"
  cp -R "$PLAYBOOK_ROOT/$REFERENCES/spec" "$copy/$REFERENCES/spec"
  cp "$PLAYBOOK_ROOT/$COMMAND" "$copy/$COMMAND"
  printf '%s\n' "$copy"
}

# playbook_files <root>: spec.md first, then every spec/*.md, one per line.
playbook_files() {
  local root="$1" file
  [ -f "$root/$REFERENCES/spec.md" ] || return 1
  printf '%s\n' "$root/$REFERENCES/spec.md"
  for file in "$root/$REFERENCES"/spec/*.md; do
    [ -f "$file" ] && printf '%s\n' "$file"
  done
  return 0
}

# --- a. spec.md stays under the cap ------------------------------------------

entry_under_cap() {
  local lines
  [ -f "$1/$REFERENCES/spec.md" ] || return 1
  lines="$(wc -l <"$1/$REFERENCES/spec.md" | tr -d ' ')"
  [ "$lines" -ge 1 ] || return 1
  [ "$lines" -lt 500 ] || {
    printf 'spec.md is %s lines, the cap is 499\n' "$lines" >&2
    return 1
  }
  return 0
}

@test "a. spec.md is under 500 lines" {
  entry_under_cap "$PLAYBOOK_ROOT"
}

@test "a. the line cap goes red on a padded copy" {
  copy="$(scratch_copy)"
  for _ in $(seq 1 500); do printf 'padding\n'; done >>"$copy/$REFERENCES/spec.md"
  run entry_under_cap "$copy"
  [ "$status" -ne 0 ]
}

# --- b. routing and the command index ----------------------------------------

# named_sub_references <root>: every spec/<name>.md spec.md names, one per line.
named_sub_references() {
  grep -oE -- '(^|[^A-Za-z0-9_-])spec/[A-Za-z0-9_-]+\.md' "$1/$REFERENCES/spec.md" | sed -E 's|^.*spec/||' | sort -u
}

sub_references_routed_and_listed() {
  local root="$1" names name count=0 expected listed=0
  names="$(named_sub_references "$root")"
  [ -n "$names" ] || return 1
  expected="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
  while IFS= read -r name; do
    count=$((count + 1))
    if [ ! -f "$root/$REFERENCES/spec/$name" ]; then
      printf 'spec.md names missing spec/%s\n' "$name" >&2
      return 1
    fi
    if ! grep -qF -- "\`$REFERENCES/spec/$name\`" "$root/$COMMAND"; then
      printf 'spec/%s is not listed in %s\n' "$name" "$COMMAND" >&2
      return 1
    fi
  done <<<"$names"
  [ "$count" -eq "$expected" ] || return 1
  for name in "${MOVED_SUB_REFERENCES[@]}"; do
    listed=$((listed + 1))
    if ! grep -qF -- "Read \`$REFERENCES/spec/$name\`" "$root/$REFERENCES/spec.md"; then
      printf 'spec/%s has no Read line in spec.md\n' "$name" >&2
      return 1
    fi
  done
  [ "$listed" -ge 1 ] || return 1
  if ! grep -F -- "\`$REFERENCES/spec/self-review.md\`" "$root/$COMMAND" | grep -qF -- 'read by the self-review sub-agent, never this thread'; then
    printf 'spec/self-review.md has no marked bullet in %s\n' "$COMMAND" >&2
    return 1
  fi
  return 0
}

@test "b. every sub-reference spec.md names exists, is indexed, and each moved one is routed" {
  sub_references_routed_and_listed "$PLAYBOOK_ROOT"
}

@test "b. the routing check goes red when one index listing is deleted" {
  copy="$(scratch_copy)"
  grep -vF -- "\`$REFERENCES/spec/resume.md\`" "$copy/$COMMAND" >"$copy/$COMMAND.new"
  mv "$copy/$COMMAND.new" "$copy/$COMMAND"
  run sub_references_routed_and_listed "$copy"
  [ "$status" -ne 0 ]
}

@test "b. the routing check goes red when one Read line is deleted" {
  copy="$(scratch_copy)"
  grep -vF -- "Read \`$REFERENCES/spec/self-review-dispatch.md\`" "$copy/$REFERENCES/spec.md" >"$copy/$REFERENCES/spec.md.new"
  mv "$copy/$REFERENCES/spec.md.new" "$copy/$REFERENCES/spec.md"
  run sub_references_routed_and_listed "$copy"
  [ "$status" -ne 0 ]
}

@test "b. the routing check goes red when spec.md names a missing sub-reference" {
  copy="$(scratch_copy)"
  rm "$copy/$REFERENCES/spec/audit.md"
  run sub_references_routed_and_listed "$copy"
  [ "$status" -ne 0 ]
}

@test "b. the routing check goes red when the self-review bullet loses its mark" {
  copy="$(scratch_copy)"
  sed 's/read by the self-review sub-agent, never this thread/the self-review checklist/' "$copy/$COMMAND" >"$copy/$COMMAND.new"
  mv "$copy/$COMMAND.new" "$copy/$COMMAND"
  run sub_references_routed_and_listed "$copy"
  [ "$status" -ne 0 ]
}

@test "b. the routing check goes red on an empty route set" {
  copy="$(scratch_copy)"
  grep -vE -- 'spec/[A-Za-z0-9_-]+\.md' "$copy/$REFERENCES/spec.md" >"$copy/$REFERENCES/spec.md.new"
  mv "$copy/$REFERENCES/spec.md.new" "$copy/$REFERENCES/spec.md"
  run sub_references_routed_and_listed "$copy"
  [ "$status" -ne 0 ]
}

# --- c. each moved section has one owner -------------------------------------

# owner<TAB>needle<TAB>kind: kind `heading` matches a line starting with the
# needle, kind `literal` matches the needle anywhere.
OWNED=(
  "audit.md	## 7a.	heading"
  "audit.md	### 7b-i.	heading"
  "audit.md	## 7c.	heading"
  "clarify-loop.md	## 5d.	heading"
  "self-review-dispatch.md	## 6b.	heading"
  "clarify-loop.md	## The question ceiling	heading"
  "resume.md	LOCK_STATUS=	literal"
)

holds_needle() {
  if [ "$3" = heading ]; then
    awk -v want="$2" 'index($0, want) == 1 { found = 1 } END { exit !found }' "$1"
  else
    grep -qF -- "$2" "$1"
  fi
}

sections_owned() {
  local root="$1" entry owner rest needle kind files file holders checked=0
  files="$(playbook_files "$root")" || return 1
  [ "$(printf '%s\n' "$files" | wc -l | tr -d ' ')" -ge 2 ] || return 1
  for entry in "${OWNED[@]}"; do
    owner="${entry%%	*}"
    rest="${entry#*	}"
    needle="${rest%%	*}"
    kind="${rest#*	}"
    holders=""
    while IFS= read -r file; do
      if holds_needle "$file" "$needle" "$kind"; then
        holders="$holders${file#"$root/$REFERENCES"/} "
      fi
    done <<<"$files"
    if [ "$holders" != "spec/$owner " ]; then
      printf '%s is held by [%s], expected [spec/%s]\n' "$needle" "$holders" "$owner" >&2
      return 1
    fi
    checked=$((checked + 1))
  done
  [ "$checked" -eq "${#OWNED[@]}" ] || return 1
  return 0
}

@test "c. each moved section lives in exactly one sub-reference" {
  sections_owned "$PLAYBOOK_ROOT"
}

@test "c. the ownership check goes red when a moved heading is duplicated into spec.md" {
  copy="$(scratch_copy)"
  printf '\n## 5d. Per-topic exhaustion checkpoint\n\nstale copy\n' >>"$copy/$REFERENCES/spec.md"
  run sections_owned "$copy"
  [ "$status" -ne 0 ]
}

@test "c. the ownership check goes red when the lock literal returns to spec.md" {
  copy="$(scratch_copy)"
  printf '\nLOCK_STATUS="$(true)"\n' >>"$copy/$REFERENCES/spec.md"
  run sections_owned "$copy"
  [ "$status" -ne 0 ]
}

# --- d. the auditor preamble lives only in the contract ----------------------

PREAMBLE='You are an ADVERSARIAL auditor'

preamble_only_in_contract() {
  local root="$1" files file holders=""
  files="$(playbook_files "$root")" || return 1
  while IFS= read -r file; do
    if grep -qF -- "$PREAMBLE" "$file"; then
      holders="$holders${file#"$root/$REFERENCES"/} "
    fi
  done <<<"$files"
  if [ "$holders" != "spec/lens-dispatch.md " ]; then
    printf 'the auditor preamble is held by [%s], expected [spec/lens-dispatch.md]\n' "$holders" >&2
    return 1
  fi
  return 0
}

@test "d. the adversarial-auditor preamble appears only in spec/lens-dispatch.md" {
  preamble_only_in_contract "$PLAYBOOK_ROOT"
}

@test "d. the preamble check goes red when the spec audit carries its own copy" {
  copy="$(scratch_copy)"
  printf '\n> %s of a GAIA SPEC draft.\n' "$PREAMBLE" >>"$copy/$REFERENCES/spec/audit.md"
  run preamble_only_in_contract "$copy"
  [ "$status" -ne 0 ]
}

# --- e. long sub-references carry a Contents line -----------------------------

# has_contents_line <file>: a line starting `Contents:` outside any code fence.
has_contents_line() {
  awk '
    /^```/ { inside_fence = !inside_fence; next }
    !inside_fence && /^Contents:/ { found = 1 }
    END { exit !found }
  ' "$1"
}

long_files_have_contents() {
  local root="$1" file lines count=0 long=0
  for file in "$root/$REFERENCES"/spec/*.md; do
    [ -f "$file" ] || continue
    count=$((count + 1))
    lines="$(wc -l <"$file" | tr -d ' ')"
    [ "$lines" -gt 100 ] || continue
    long=$((long + 1))
    if ! has_contents_line "$file"; then
      printf '%s is %s lines and has no Contents: line\n' "${file#"$root"/}" "$lines" >&2
      return 1
    fi
  done
  [ "$count" -ge 1 ] || return 1
  [ "$long" -ge 1 ] || return 1
  return 0
}

@test "e. every spec/*.md over 100 lines carries a Contents line" {
  long_files_have_contents "$PLAYBOOK_ROOT"
}

@test "e. the Contents check goes red when one long file loses its line" {
  copy="$(scratch_copy)"
  grep -v '^Contents:' "$copy/$REFERENCES/spec/audit.md" >"$copy/$REFERENCES/spec/audit.md.new"
  mv "$copy/$REFERENCES/spec/audit.md.new" "$copy/$REFERENCES/spec/audit.md"
  run long_files_have_contents "$copy"
  [ "$status" -ne 0 ]
}

@test "e. a Contents line inside a code fence does not count" {
  copy="$(scratch_copy)"
  grep -v '^Contents:' "$copy/$REFERENCES/spec/audit.md" >"$copy/$REFERENCES/spec/audit.md.new"
  printf '\n```text\nContents: fenced, not real\n```\n' >>"$copy/$REFERENCES/spec/audit.md.new"
  mv "$copy/$REFERENCES/spec/audit.md.new" "$copy/$REFERENCES/spec/audit.md"
  run long_files_have_contents "$copy"
  [ "$status" -ne 0 ]
}
