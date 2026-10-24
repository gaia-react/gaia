#!/usr/bin/env bats
#
# Doc-conformance suite for the split of `/gaia-plan`'s playbook:
# .claude/skills/gaia/references/plan.md is the entry file, and every
# sub-reference under .claude/skills/gaia/references/plan/ is read only when a
# line routes a run to it (the planner sub-agent reads plan/planner.md; the
# main thread reads plan/decomposition-audit.md at step 4.6).
#
# The invariants:
#   b. every plan/*.md is named in plan.md by its repo path and listed in the
#      /gaia-plan command, so a sub-reference no line routes to cannot exist;
#   c. every plan/<name>.md either file names exists;
#   e. the decomposition audit points at the shared lens contract instead of
#      carrying its own reply-shaped findings schema;
#   g. plan.md step 4's dispatch makes the planner's first action a Read of
#      plan/planner.md, the only thing that hands the planner its contract.
#
# Every check is a function taking a root laid out like the repository, so each
# red twin runs the same function against a mutated scratch copy.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES_RELATIVE='.claude/skills/gaia/references'
  COMMAND_RELATIVE='.claude/commands/gaia-plan.md'
}

# scratch_copy: copies plan.md, plan/ and the command into a scratch root laid
# out like the repository, and prints the root.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root"
  rm -rf "$copy"
  mkdir -p "$copy/$REFERENCES_RELATIVE" "$copy/.claude/commands"
  cp "$REPO_ROOT/$REFERENCES_RELATIVE/plan.md" "$copy/$REFERENCES_RELATIVE/plan.md"
  cp -R "$REPO_ROOT/$REFERENCES_RELATIVE/plan" "$copy/$REFERENCES_RELATIVE/plan"
  cp "$REPO_ROOT/$COMMAND_RELATIVE" "$copy/$COMMAND_RELATIVE"
  printf '%s\n' "$copy"
}

# --- b. every sub-reference is routed and listed ----------------------------

# every_sub_reference_listed <root>: the set comes from the directory, and an
# independent count catches a glob that read fewer files than exist; an empty
# set fails rather than passing vacuously.
every_sub_reference_listed() {
  local root="$1" plan_md command file name path count=0 expected
  plan_md="$root/$REFERENCES_RELATIVE/plan.md"
  command="$root/$COMMAND_RELATIVE"
  expected="$(find "$root/$REFERENCES_RELATIVE/plan" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$expected" -ge 1 ] || { printf 'no plan/*.md files found\n' >&2; return 1; }
  for file in "$root/$REFERENCES_RELATIVE"/plan/*.md; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    path="$REFERENCES_RELATIVE/plan/$name"
    count=$((count + 1))
    grep -qF -- "\`$path\`" "$plan_md" || { printf 'plan.md does not name %s\n' "$path" >&2; return 1; }
    grep -qE -- "^- \`$path\`" "$command" || { printf 'gaia-plan.md does not list %s\n' "$path" >&2; return 1; }
  done
  [ "$count" -eq "$expected" ] || { printf 'read %s of %s files\n' "$count" "$expected" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "every plan/*.md is named in plan.md and listed in the command" {
  every_sub_reference_listed "$REPO_ROOT"
}

@test "red twin: deleting one listing line from the command fails the routing check" {
  copy="$(scratch_copy)"
  grep -vF -- "- \`$REFERENCES_RELATIVE/plan/decomposition-audit.md\`" "$copy/$COMMAND_RELATIVE" >"$copy/command.new"
  mv "$copy/command.new" "$copy/$COMMAND_RELATIVE"
  run every_sub_reference_listed "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: an unrouted plan/*.md fails the routing check" {
  copy="$(scratch_copy)"
  printf '# Stray\n' >"$copy/$REFERENCES_RELATIVE/plan/stray.md"
  run every_sub_reference_listed "$copy"
  [ "$status" -ne 0 ]
}

# --- c. no route to a missing file ------------------------------------------

no_orphan_route() {
  local root="$1" names name
  names="$(cat "$root/$REFERENCES_RELATIVE/plan.md" "$root/$COMMAND_RELATIVE" |
    grep -oE -- 'references/plan/[A-Za-z0-9_-]+\.md' | sed 's|^references/plan/||' | sort -u)"
  [ -n "$names" ] || { printf 'neither file names a plan/*.md\n' >&2; return 1; }
  while IFS= read -r name; do
    [ -f "$root/$REFERENCES_RELATIVE/plan/$name" ] || { printf 'route to missing plan/%s\n' "$name" >&2; return 1; }
  done <<<"$names"
}

# bats test_tags=whole-tree
@test "every plan/<name>.md that plan.md or the command names exists" {
  no_orphan_route "$REPO_ROOT"
}

@test "red twin: a route to a missing file fails the orphan check" {
  copy="$(scratch_copy)"
  printf '\nRead `%s/plan/missing.md` now.\n' "$REFERENCES_RELATIVE" >>"$copy/$REFERENCES_RELATIVE/plan.md"
  run no_orphan_route "$copy"
  [ "$status" -ne 0 ]
}

# --- e. the audit uses the lens contract ------------------------------------

audit_uses_lens_contract() {
  local file="$1/$REFERENCES_RELATIVE/plan/decomposition-audit.md"
  grep -qF -- 'spec/lens-dispatch.md' "$file" || { printf 'decomposition-audit.md does not name spec/lens-dispatch.md\n' >&2; return 1; }
  grep -qiF -- 'each agent returns exactly this object' "$file" && { printf 'decomposition-audit.md carries a reply-shaped schema\n' >&2; return 1; }
  return 0
}

# bats test_tags=whole-tree
@test "the decomposition audit names the lens contract and carries no reply-shaped schema" {
  audit_uses_lens_contract "$REPO_ROOT"
}

@test "red twin: a re-inserted reply schema, or a dropped contract pointer, fails" {
  copy="$(scratch_copy)"
  file="$copy/$REFERENCES_RELATIVE/plan/decomposition-audit.md"
  printf '\nFindings schema (each agent returns exactly this object):\n' >>"$file"
  run audit_uses_lens_contract "$copy"
  [ "$status" -ne 0 ]
  copy="$(scratch_copy)"
  file="$copy/$REFERENCES_RELATIVE/plan/decomposition-audit.md"
  sed 's|spec/lens-dispatch\.md|the lens contract|g' "$file" >"$file.new"
  mv "$file.new" "$file"
  run audit_uses_lens_contract "$copy"
  [ "$status" -ne 0 ]
}

# --- g. the dispatch hands the planner its file -----------------------------

# step4_first_read <root>: the first non-empty line of the first fence in
# plan.md's step 4 is a Read of plan/planner.md.
step4_first_read() {
  local first
  first="$(awk '
    /^### 4\. / { inside = 1; next }
    inside && /^### / { exit }
    inside && /^```/ { if (in_fence) exit; in_fence = 1; next }
    in_fence && NF { print; exit }' "$1/$REFERENCES_RELATIVE/plan.md")"
  [ -n "$first" ] || { printf 'plan.md step 4 has no fenced dispatch\n' >&2; return 1; }
  grep -qE -- "Read .*/$REFERENCES_RELATIVE/plan/planner\.md" <<<"$first" || { printf 'the dispatch opens with: %s\n' "$first" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "plan.md step 4's dispatch makes plan/planner.md the planner's first Read" {
  step4_first_read "$REPO_ROOT"
}

@test "red twin: a dispatch that no longer reads planner.md first fails" {
  copy="$(scratch_copy)"
  file="$copy/$REFERENCES_RELATIVE/plan.md"
  sed "s|Read <checkout root>/$REFERENCES_RELATIVE/plan/planner.md|Read the plan instructions|" "$file" >"$file.new"
  mv "$file.new" "$file"
  run step4_first_read "$copy"
  [ "$status" -ne 0 ]
}
