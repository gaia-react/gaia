#!/usr/bin/env bats
#
# Doc-conformance suite for the shape of `/gaia-spec`'s playbook: the entry
# file .claude/skills/gaia/references/spec.md plus the sub-references under
# .claude/skills/gaia/references/spec/ that it reads at their branch points.
#
# The invariants:
#   b. a sub-reference read is a step a model can skip, so every spec/<name>.md
#      that spec.md names exists and is listed in the command's sub-reference
#      index (.claude/commands/gaia-spec.md), each sub-reference moved out of
#      spec.md has a `Read` line there, and the self-review checklist carries
#      its marked bullet (read by the sub-agent, never the main thread);
#   c. each moved section lives in exactly one file of the playbook set.
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

# bats test_tags=whole-tree
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

# bats test_tags=whole-tree
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

# --- d. every closed-set menu fits AskUserQuestion ---------------------------

# AskUserQuestion takes at most four options and supplies its own free-text
# Other, so a menu listing Other or the save-partial escape crowds out a real
# choice, and one of five or more entries fails the call.

# menu_report <file>: one `menu <line> <entries>` line per menu, and one
# `explicit <line>` line per listed Other or save-partial entry: a label, or a
# numbered item whose text opens with the option name and its `,` or `:`
# delimiter, so a prose rule that merely names the escape is not one. A menu is a run
# of `- \`{ label:` lines, or the numbered lines under an `Options:` line, where
# a line indented five or more spaces continues the entry above it.
menu_report() {
  awk '
    function flush() {
      if (run > 0) printf "menu %d %d\n", start, run
      run = 0
    }
    /\{ label: "(Other|Save partial)/ { printf "explicit %d\n", FNR }
    /^[[:space:]]*([0-9]+|N(-[0-9]+)?)\.[[:space:]]+(\*\*)?`?(Other|Save partial and resume later)`?(\*\*)?[,:]/ { printf "explicit %d\n", FNR }
    /^[[:space:]]*- `\{ label:/ { if (run == 0) start = FNR; run++; next }
    in_options && /^[[:space:]]+([0-9]+|N(-[0-9]+)?)\.[[:space:]]/ { if (run == 0) start = FNR; run++; next }
    in_options && /^[[:space:]][[:space:]][[:space:]][[:space:]][[:space:]]+[^[:space:]]/ { next }
    /^[[:space:]]*Options:[[:space:]]*$/ { flush(); in_options = 1; next }
    { flush(); in_options = 0 }
    END { flush() }
  ' "$1"
}

menus_fit() {
  local root="$1" files file report menus=0 bad=0
  files="$(playbook_files "$root")" || return 1
  while IFS= read -r file; do
    report="$(menu_report "$file")"
    [ -n "$report" ] || continue
    while read -r kind line entries; do
      if [ "$kind" = menu ]; then
        menus=$((menus + 1))
        if [ "$entries" -gt 4 ]; then
          printf '%s:%s: menu of %s entries\n' "${file#"$root"/}" "$line" "$entries" >&2
          bad=1
        fi
      else
        printf '%s:%s: lists an option the tool supplies or the menu omits\n' "${file#"$root"/}" "$line" >&2
        bad=1
      fi
    done <<<"$report"
  done <<<"$files"
  [ "$menus" -gt 0 ] || return 1
  [ "$bad" -eq 0 ]
}

# bats test_tags=whole-tree
@test "d. no closed-set menu lists Other, the save escape, or more than four entries" {
  menus_fit "$PLAYBOOK_ROOT"
}

@test "d. the menu check goes red on an explicit Other label" {
  copy="$(scratch_copy)"
  printf '\n- options:\n  - `{ label: "Other", description: "x" }`\n' >>"$copy/$REFERENCES/spec/clarify-loop.md"
  run menus_fit "$copy"
  [ "$status" -ne 0 ]
}

@test "d. the menu check goes red on a numbered save-partial entry" {
  copy="$(scratch_copy)"
  printf '\n5. **`Save partial and resume later`**: escape.\n' >>"$copy/$REFERENCES/spec/clarify-loop.md"
  run menus_fit "$copy"
  [ "$status" -ne 0 ]
}

@test "d. the menu check goes red on a five-entry label menu" {
  copy="$(scratch_copy)"
  printf '\n- options:\n  - `{ label: "a" }`\n  - `{ label: "b" }`\n  - `{ label: "c" }`\n  - `{ label: "d" }`\n  - `{ label: "e" }`\n' >>"$copy/$REFERENCES/spec/clarify-loop.md"
  run menus_fit "$copy"
  [ "$status" -ne 0 ]
}

@test "d. the menu check goes red on a five-entry numbered template" {
  copy="$(scratch_copy)"
  printf '\n```\nOptions:\n  1. a\n  2. b\n     wrapped\n  3. c\n  4. d\n  5. e\n```\n' >>"$copy/$REFERENCES/spec/clarify-prompts.md"
  run menus_fit "$copy"
  [ "$status" -ne 0 ]
}

@test "d. the menu check goes red when no menu is found" {
  copy="$(scratch_copy)"
  for file in "$copy/$REFERENCES/spec.md" "$copy/$REFERENCES"/spec/*.md; do
    grep -vE -- '\{ label:|^[[:space:]]*Options:' "$file" >"$file.new"
    mv "$file.new" "$file"
  done
  run menus_fit "$copy"
  [ "$status" -ne 0 ]
}
