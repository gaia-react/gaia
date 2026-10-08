#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-debt's named-issue strictness and
# operator-named batches (.claude/skills/gaia/references/debt.md and
# .claude/commands/gaia-debt.md).
#
# What it guards. A /gaia-debt argument names what the operator wants drained,
# and the playbook is followed literally by a model, so every place the prose
# lets a named number turn into a different issue is a drain nobody asked for:
# a claim, a branch, and a pull request against the wrong ticket. Before this
# behavior existed, `/gaia-debt 12 34` fixed #12 and silently dropped 34, a
# typo such as `12x` drained the top of the backlog, and an ineligible number
# printed its reason and then fell through to the top-of-backlog flow.
#
# The invariants, each pinned to the section that owns it:
#   - argument parsing calls the executable parser through a quoted heredoc
#     and maps every one of its outputs; the old first-token fall-through is
#     gone;
#   - a named number is validated against a fixed, first-match reason table
#     (one test per row, so a dropped row reds alone), and an ineligible one
#     stops the run;
#   - a named set runs security pre-filter, spec pre-filter, branch-name
#     dry-run, then the scorer, in that order, prints only fixed strings about
#     a rejected member, and states no weight, budget, or exit-code number of
#     its own (the scorer owns them);
#   - a named selection that loses a member at the claim-time re-read releases
#     the claims set so far and stops, never re-presents the backlog;
#   - every new run-ending path writes a cost record;
#   - the budget constants are assigned in exactly one file, the scorer.
#
# Section-scoped, not whole-file: a phrase surviving elsewhere cannot green a
# section that dropped it. extract_section ends a section at the next heading
# of the same or a shallower level with no fence tracking, so a `# ` line
# inside a fenced block in debt.md truncates the haystack early. The error
# direction is over-strict: a truncated haystack fails, it never passes.
#
# Mutation. Each target is read through an overridable variable, so a mutated
# scratch copy can be pointed at without touching the real file:
#   DOC_DEBT_NAMED_SET_DEBT_MD     the playbook's core (debt.md)
#   DOC_DEBT_NAMED_SET_NAMED_MD    the named-number sub-reference (debt/named.md),
#                                  which owns validation, the direct-number
#                                  path, and the named-set flow
#   DOC_DEBT_NAMED_SET_COMMAND_MD  the command file
#   DOC_DEBT_NAMED_SET_REPO_ROOT   the tree the budget-constant owner check scans
# Every fixture is generated at runtime under $BATS_TEST_TMPDIR, and a line
# assigning a budget constant is built with printf from parts, so this suite
# never matches the owner check's own pattern.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DEBT_MD="${DOC_DEBT_NAMED_SET_DEBT_MD:-$REPO_ROOT/.claude/skills/gaia/references/debt.md}"
  NAMED_MD="${DOC_DEBT_NAMED_SET_NAMED_MD:-$REPO_ROOT/.claude/skills/gaia/references/debt/named.md}"
  COMMAND_MD="${DOC_DEBT_NAMED_SET_COMMAND_MD:-$REPO_ROOT/.claude/commands/gaia-debt.md}"
  SCAN_ROOT="${DOC_DEBT_NAMED_SET_REPO_ROOT:-$REPO_ROOT}"
  NAMED_SET_HEADING='## Fix a named set (two or more numbers)'
}

# extract_section <heading-line-prefix> [file]
# Prints the first section whose heading line starts with the literal prefix
# (heading included), up to but excluding the next heading of the same or a
# shallower level. Prints nothing when no heading matches.
extract_section() {
  awk -v want="$1" '
    !found && index($0, want) == 1 {
      found = 1
      match($0, /^#+/)
      level = RLENGTH
      print
      next
    }
    found && /^#+ / {
      match($0, /^#+/)
      if (RLENGTH <= level) exit
    }
    found { print }
  ' "${2:-$DEBT_MD}"
}

# extract_between <start-prefix> <stop-prefix>  (haystack on stdin)
# Prints from the first line whose leading-whitespace-stripped text starts
# with start-prefix up to but excluding the next line whose stripped text
# starts with stop-prefix. Prints nothing when start-prefix is absent.
extract_between() {
  awk -v start="$1" -v stop="$2" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    on && index(line, stop) == 1 { exit }
    !on && index(line, start) == 1 { on = 1 }
    on { print }
  '
}

# line_of <fixed-string>  (haystack on stdin): first matching line number.
line_of() {
  grep -n -F -- "$1" | head -1 | cut -d: -f1
}

named_set_section() {
  extract_section "$NAMED_SET_HEADING" "$NAMED_MD"
}

# --- 1. argument parsing ----------------------------------------------------

@test "argument parsing calls the parser through a quoted heredoc" {
  section="$(extract_section '## Argument parsing')"
  [ -n "$section" ]
  grep -qF -- "bash .gaia/scripts/debt-parse-args.sh <<'GAIA_DEBT_ARGUMENTS'" <<<"$section"
  grep -qx -- 'GAIA_DEBT_ARGUMENTS' <<<"$section"
}

@test "argument parsing maps every parser output" {
  section="$(extract_section '## Argument parsing')"
  [ -n "$section" ]
  grep -qF -- '- `top`' <<<"$section"
  grep -qF -- '- `numbers <N>`' <<<"$section"
  grep -qF -- '- `numbers <N1> <N2> ...`' <<<"$section"
  grep -qF -- '- `unrecognized <token>`' <<<"$section"
}

@test "argument parsing maps no removed list or why output" {
  section="$(extract_section '## Argument parsing')"
  [ -n "$section" ]
  grep -qF -- '- `list`' <<<"$section" && return 1
  grep -qF -- '- `why <N>`' <<<"$section" && return 1
  grep -qF -- 'bare `fix`' <<<"$section" && return 1
  grep -qF -- '/gaia-debt [<issue-number> ...] [[use] worktree|branch]' <<<"$section"
}

# playbook_set <core-file>: the core plus every sub-reference beside it under
# debt/, one path per line, core first.
playbook_set() {
  local core="$1" file
  printf '%s\n' "$core"
  for file in "$(dirname "$core")"/debt/*.md; do
    [ -f "$file" ] && printf '%s\n' "$file"
  done
  return 0
}

# no_list_or_why_section <core-file>: fails when any file in the playbook set
# carries a list or why subcommand heading, or when the set holds no
# sub-reference (a short glob would otherwise pass over the core alone).
no_list_or_why_section() {
  local files file count=0 expected
  files="$(playbook_set "$1")"
  # An independent count of the sub-references, so a glob that reads fewer
  # files than exist fails instead of passing over a subset.
  expected="$(find "$(dirname "$1")/debt" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  while IFS= read -r file; do
    [ -s "$file" ] || return 1
    count=$((count + 1))
    grep -qE -- '^## (list|why) subcommand' "$file" && return 1
  done <<<"$files"
  [ "$expected" -ge 1 ] || return 1
  [ "$count" -eq $((expected + 1)) ] || return 1
  return 0
}

@test "the debt reference carries no list or why subcommand section" {
  no_list_or_why_section "$DEBT_MD"
}

@test "the list-or-why check reads every sub-reference, not only the core" {
  copy="$BATS_TEST_TMPDIR/references"
  mkdir -p "$copy/debt"
  cp "$DEBT_MD" "$copy/debt.md"
  cp "$(dirname "$DEBT_MD")"/debt/*.md "$copy/debt/"
  no_list_or_why_section "$copy/debt.md"
  printf '\n## why subcommand\n' >>"$copy/debt/named.md"
  run no_list_or_why_section "$copy/debt.md"
  [ "$status" -ne 0 ]
}

@test "argument parsing no longer falls an unparsed first token through to the top of the backlog" {
  # Before: `12x` or `lsit` defaulted to the top-of-backlog flow, and `12 34`
  # fixed #12 and dropped 34, because only the first token was read.
  section="$(extract_section '## Argument parsing')"
  [ -n "$section" ]
  grep -qF -- 'default to `fix` with no target' <<<"$section" && return 1
  grep -qiF -- 'first whitespace-separated word' <<<"$section" && return 1
  true
}

@test "argument parsing relays the refusal verbatim and ends before the backend probe" {
  section="$(extract_section '## Argument parsing')"
  [ -n "$section" ]
  grep -qiF -- 'before `## Backend probe`' <<<"$section"
  grep -qiF -- 'verbatim' <<<"$section"
  grep -qiF -- 'claim nothing' <<<"$section"
}

# --- 2. the validation reason table -----------------------------------------

validate_has_row() {
  section="$(extract_section '## Validate named numbers' "$NAMED_MD")"
  [ -n "$section" ]
  grep -qF -- "$1" <<<"$section"
}

@test "validation row: not an issue in this repository" {
  validate_has_row '`#<N> is not an issue in this repository`'
}

@test "validation row: could not be read" {
  validate_has_row '`#<N> could not be read: <gh error, one line>`'
}

@test "validation row: already closed" {
  validate_has_row '`#<N> is already closed`'
}

@test "validation row: no tech-debt label" {
  validate_has_row '`#<N> doesn'"'"'t carry the tech-debt label`'
}

@test "validation row: already being fixed" {
  validate_has_row '`#<N> is already being fixed by another session`'
}

@test "validation row: parked pending a SPEC handoff" {
  validate_has_row '`#<N> is parked pending a SPEC handoff`'
}

@test "validation row: parked with a SPEC underway" {
  validate_has_row '`#<N> is parked with a SPEC underway or holding it open`'
}

@test "validation row: graded severity:investigate" {
  validate_has_row '`#<N> is graded severity:investigate: answer its question and re-grade it before fixing it`'
}

@test "validation states first-match precedence and reads url to tell a pull request apart" {
  section="$(extract_section '## Validate named numbers' "$NAMED_MD")"
  [ -n "$section" ]
  grep -qiF -- 'first matching row wins' <<<"$section"
  grep -qF -- 'gh issue view <n> --json state,labels,url' <<<"$section"
  grep -qF -- '`url` contains `/pull/`' <<<"$section"
  grep -qF -- 'Could not resolve to an issue or pull request' <<<"$section"
}

@test "validation stops the run on any ineligible number, with no fall-through" {
  section="$(extract_section '## Validate named numbers' "$NAMED_MD")"
  [ -n "$section" ]
  grep -qiF -- 'any ineligible number ends the run with nothing claimed' <<<"$section"
  grep -qiF -- 'no fall-through' <<<"$section"
}

@test "validation of every named number precedes the security pre-filter" {
  section="$(extract_section '## Validate named numbers' "$NAMED_MD")$(named_set_section)"
  [ -n "$section" ]
  grep -qiF -- 'validation of every named number precedes the security pre-filter' <<<"$section"
}

# --- 3. the direct-number path ----------------------------------------------

@test "the direct-number ineligible arm stops instead of falling through" {
  section="$(extract_section '## Fix a specific issue (direct-number path)' "$NAMED_MD")"
  [ -n "$section" ]
  ineligible="$(extract_between '**Ineligible**' '**Eligible**' <<<"$section")"
  [ -n "$ineligible" ]
  grep -qiF -- 'stop' <<<"$ineligible"
  grep -qF -- 'then fall through to' <<<"$ineligible" && return 1
  true
}

@test "the direct-number cluster offer keeps its operator-chosen next-available option" {
  section="$(extract_section '## Fix a specific issue (direct-number path)' "$NAMED_MD")"
  [ -n "$section" ]
  grep -qE -- '^[[:space:]]*3\. `Next available highest-priority item\(s\) instead`' <<<"$section"
}

@test "the direct-number path stops when the named issue is lost at claim time" {
  section="$(extract_section '## Fix a specific issue (direct-number path)' "$NAMED_MD")"
  [ -n "$section" ]
  grep -qF -- 'losing `#<N>` at the claim-time re-read' <<<"$section"
  grep -qiF -- 'stops the run' <<<"$section"
}

@test "the direct-number singleton claims only the named issue" {
  section="$(extract_section '## Fix a specific issue (direct-number path)' "$NAMED_MD")"
  [ -n "$section" ]
  grep -qF -- 'claims only `#<N>`' <<<"$section"
}

# --- 4. the named-set flow --------------------------------------------------

@test "the named set runs security, spec, branch-name, then the scorer, in that order" {
  section="$(named_set_section)"
  [ -n "$section" ]
  security=$(line_of '**Security pre-filter.**' <<<"$section")
  spec=$(line_of '**Spec pre-filter.**' <<<"$section")
  branch=$(line_of 'bash .gaia/scripts/branch-name-lib.sh name debt' <<<"$section")
  score=$(line_of 'bash .gaia/scripts/debt-batch-budget.sh' <<<"$section")
  [ -n "$security" ] && [ -n "$spec" ] && [ -n "$branch" ] && [ -n "$score" ]
  [ "$security" -lt "$spec" ]
  [ "$spec" -lt "$branch" ]
  [ "$branch" -lt "$score" ]
}

@test "the named set carries the fixed security rejection line" {
  section="$(named_set_section)"
  [ -n "$section" ]
  grep -qF -- "\`#<P> can't join a batch on a non-private repo; drain it alone.\`" <<<"$section"
}

@test "the named set scopes the no-disclosure rule to printed messages" {
  section="$(named_set_section)"
  [ -n "$section" ]
  grep -qiF -- 'covers the run'"'"'s printed messages' <<<"$section"
  grep -qiF -- 'no printed message names a security-class member'"'"'s title, body, or path' <<<"$section"
  grep -qiF -- 'staleness probe'"'"'s annotation is never printed for a named set'"'"'s security-class member' <<<"$section"
}

@test "the over-budget prompt lists the subsets before Force and Other never forces" {
  section="$(named_set_section)"
  [ -n "$section" ]
  subsets=$(line_of "each of the scorer's \`subsets\`" <<<"$section")
  force=$(line_of '`Force #<A> #<B> ...` last' <<<"$section")
  [ -n "$subsets" ] && [ -n "$force" ]
  [ "$subsets" -lt "$force" ]
  grep -qiF -- 'use Other to cancel' <<<"$section"
  grep -qiF -- 'declined or dismissed prompt' <<<"$section"
  grep -qiF -- 'never forces and never drains' <<<"$section"
}

@test "the spec hand-off prompt has exactly two options" {
  section="$(named_set_section)"
  [ -n "$section" ]
  arm="$(extract_between '2. **Spec pre-filter.**' '3. **Branch-name dry-run.**' <<<"$section")"
  [ -n "$arm" ]
  grep -qiF -- 'exactly two options' <<<"$arm"
  grep -qF -- '- `Hand off #<S> [#<S2> ...] to /gaia-spec`' <<<"$arm"
  grep -qF -- '- `Cancel`' <<<"$arm"
  options=$(grep -cE -- '^[[:space:]]*- `(Hand off|Cancel)' <<<"$arm")
  [ "$options" -eq 2 ]
}

# --- 5. no weight, budget, or exit-code literal in the named-set section ----

@test "the named-set section states no weight, budget, or exit-code number" {
  section="$(named_set_section)"
  [ -n "$section" ]
  stripped="$(sed -E 's/^[[:space:]]*[0-9]+\. //' <<<"$section")"
  grep -nE -- '(^|[^#0-9A-Za-z_./-])(2|3|7|12)([^0-9]|$)' <<<"$stripped" && return 1
  true
}

# --- 6. the budget constants live in the scorer alone -----------------------

# budget_constant_owners <root>: every tracked or untracked (not ignored) file
# under <root> that assigns a DEBT_BUDGET_ constant at column 0, one
# repo-relative path per line, sorted.
budget_constant_owners() {
  {
    git -C "$1" grep -l -E '^DEBT_BUDGET_[A-Z_]+=' -- 2>/dev/null || true
    while IFS= read -r -d '' path; do
      [ -f "$1/$path" ] || continue
      if grep -qE '^DEBT_BUDGET_[A-Z_]+=' "$1/$path"; then
        printf '%s\n' "$path"
      fi
    done < <(git -C "$1" ls-files -z --others --exclude-standard 2>/dev/null)
  } | sort -u
}

@test "the budget constants are assigned in exactly one file, the scorer" {
  # Read the scorer directly as well, so an empty owner list (an unstaged
  # scorer, a git failure) cannot pass for "exactly one".
  grep -qE '^DEBT_BUDGET_LIMIT=' "$SCAN_ROOT/.gaia/scripts/debt-batch-budget.sh"
  owners="$(budget_constant_owners "$SCAN_ROOT")"
  [ "$owners" = ".gaia/scripts/debt-batch-budget.sh" ]
}

@test "the budget-constant owner check catches a second assigning file" {
  # Red twin: a scratch repo whose stand-in file assigns a constant, once
  # untracked and once tracked, must yield two owners.
  scratch="$BATS_TEST_TMPDIR/owners"
  mkdir -p "$scratch/.gaia/scripts"
  git -C "$scratch" init -q
  cp "$REPO_ROOT/.gaia/scripts/debt-batch-budget.sh" "$scratch/.gaia/scripts/"
  git -C "$scratch" add .gaia/scripts/debt-batch-budget.sh
  printf '%s%s\n' 'DEBT_BUDGET' '_LIMIT=99' >"$scratch/stand-in.sh"
  owners="$(budget_constant_owners "$scratch")"
  [ "$(printf '%s\n' "$owners" | wc -l | tr -d ' ')" -eq 2 ]
  git -C "$scratch" add stand-in.sh
  owners="$(budget_constant_owners "$scratch")"
  [ "$(printf '%s\n' "$owners" | wc -l | tr -d ' ')" -eq 2 ]
}

# --- 7. the named-selection claim rule --------------------------------------

@test "a named selection re-reads and claims each member in backlog order, interleaved" {
  section="$(extract_section '## Claim the fix unit')"
  [ -n "$section" ]
  grep -qiF -- 're-read and claim each member in backlog order, interleaved' <<<"$section"
  grep -qF -- 're-read `#A`'"'"'s labels, claim `#A`, re-read `#B`, claim `#B`' <<<"$section"
}

@test "a named selection's claim-time loss releases the claims so far and stops" {
  section="$(extract_section '## Claim the fix unit')"
  [ -n "$section" ]
  grep -qiF -- 'release every claim this run already set' <<<"$section"
  grep -qF -- '`#<N> was <claimed by another session | parked on a SPEC> before this run could claim it; released this run'"'"'s claims and stopped. Re-run /gaia-debt with the numbers you still want.`' <<<"$section"
  grep -qiF -- 'without re-presenting the backlog' <<<"$section"
}

# --- 8. cost records for every new run-ending path --------------------------

cost_record_has() {
  section="$(extract_section '## Cost record (run end)')"
  [ -n "$section" ]
  grep -qiF -- "$1" <<<"$section"
}

@test "cost record: the unrecognized-argument stop" {
  cost_record_has 'unrecognized-argument stop'
}

@test "cost record: the validation stop" {
  cost_record_has 'validation stop'
}

@test "cost record: the named-set security rejection" {
  cost_record_has 'security pre-filter rejecting'
}

@test "cost record: the spec hand-off cancel" {
  cost_record_has 'spec hand-off prompt cancelled'
}

@test "cost record: the branch-name-limit stop" {
  cost_record_has 'branch-name dry-run stop'
}

@test "cost record: the over-budget cancel" {
  cost_record_has 'over-budget prompt cancelled'
}

@test "cost record: the scorer's usage or unreadable-input stop" {
  cost_record_has 'scorer stopping on usage or malformed input'
}

@test "cost record: a named selection's claim-time loss" {
  cost_record_has 'named selection losing a member at the claim-time re-read'
}

# --- 9. difficulty has exactly one consumer ---------------------------------

@test "the guardrails name the named-batch budget as difficulty's one consumer" {
  section="$(extract_section '## Guardrails')"
  [ -n "$section" ]
  grep -qF -- 'Difficulty grading never gates anything' <<<"$section" && return 1
  grep -qiF -- "the named-batch budget is difficulty's one consumer" <<<"$section"
}

@test "the guardrails forbid a named number draining a different issue" {
  section="$(extract_section '## Guardrails')"
  [ -n "$section" ]
  grep -qiF -- 'a named number never drains a different issue without the operator choosing it' <<<"$section"
}

# --- 10. the command surface ------------------------------------------------

@test "the command's argument hint is the multi-number form with the isolation suffix" {
  [ -s "$COMMAND_MD" ]
  hint="$(grep -E '^argument-hint:' "$COMMAND_MD")"
  [ "$hint" = 'argument-hint: [<issue-number>...] [[use] worktree|branch]' ]
}

@test "the command's description and dispatch line name the multi-number form" {
  [ -s "$COMMAND_MD" ]
  description="$(grep -E '^description:' "$COMMAND_MD")"
  grep -qiF -- 'several issue numbers' <<<"$description"
  dispatch="$(grep -E '^Read `\.claude/skills/gaia/references/debt\.md`' "$COMMAND_MD")"
  [ -n "$dispatch" ]
  grep -qiF -- 'zero or more issue numbers' <<<"$dispatch"
  grep -qiF -- 'several name your own batch' <<<"$dispatch"
  grep -qiF -- 'argument parser' <<<"$dispatch"
  grep -qiF -- 'unrecognized argument stops' <<<"$dispatch"
}

# --- 11. the ordering query stays the first --jq line -----------------------

@test "the first --jq line is the ordering query inside the backlog-read fence" {
  [ -s "$DEBT_MD" ]
  first=$(grep -n -F -- "--jq '" "$DEBT_MD" | head -1 | cut -d: -f1)
  [ -n "$first" ]
  heading=$(grep -n -F -- '## Read and order the backlog' "$DEBT_MD" | head -1 | cut -d: -f1)
  [ -n "$heading" ]
  [ "$first" -gt "$heading" ]
  # The fence around the anchor: the last ``` line above it opens the block,
  # the first ``` line below it closes it.
  open=$(awk -v stop="$first" 'NR < stop && /^```/ { last = NR } END { print last }' "$DEBT_MD")
  close=$(awk -v start="$first" 'NR > start && /^```/ { print NR; exit }' "$DEBT_MD")
  [ -n "$open" ] && [ -n "$close" ]
  [ "$open" -gt "$heading" ]
  block="$(sed -n "${open},${close}p" "$DEBT_MD")"
  grep -qF -- 'sort_by' <<<"$block"
}

# --- 12. overlap credit from the dedup-key path alone -----------------------

@test "the score step grants overlap credit from the dedup-key path alone" {
  section="$(named_set_section)"
  [ -n "$section" ]
  score="$(extract_between '4. **Score.**' '5. **' <<<"$section")"
  [ -n "$score" ]
  grep -qiF -- 'overlap credit comes from the dedup-key path alone' <<<"$score"
  grep -qiF -- 'a keyless member earns no shared-directory waiver even when its body cites a path' <<<"$score"
}

# --- 13 and 17. the spec hand-off -------------------------------------------

spec_arm() {
  extract_between '2. **Spec pre-filter.**' '3. **Branch-name dry-run.**' <<<"$(named_set_section)"
}

@test "a hand-off with two or more downgraded members drains only the first" {
  arm="$(spec_arm)"
  [ -n "$arm" ]
  grep -qiF -- 'the first downgraded member in backlog order drains alone exactly as `/gaia-debt <S>` would' <<<"$arm"
  grep -qiF -- "every other downgraded member's claim is released" <<<"$arm"
  grep -qF -- '`Released #<S2> [#<S3> ...]: the spec screen found no SPEC needed, and a hand-off drains one downgraded issue per run. Re-run /gaia-debt <S2> [<S3> ...] to drain them.`' <<<"$arm"
  grep -qiF -- 'downgraded members never drain together' <<<"$arm"
  grep -qiF -- 'one block per confirmed member' <<<"$arm"
}

@test "the hand-off runs the spec members alone and no other named member is claimed" {
  arm="$(spec_arm)"
  [ -n "$arm" ]
  grep -qiF -- 'the security, staleness, and spec screens' <<<"$arm"
  grep -qiF -- 'no other named member gains `in-progress`' <<<"$arm"
}

# --- 14, 15, 16, 18. selection, branch, PR, and the over-budget arm ---------

@test "the named selection's branch comes from pre-flight isolation and its PR closes exactly its members" {
  section="$(named_set_section)"
  [ -n "$section" ]
  grep -qF -- 'minted by `## Pre-flight isolation (branch vs worktree)` unchanged' <<<"$section"
  grep -qF -- 'the single-issue `--slug` form for a one-member selection, the batch form for two or more' <<<"$section"
  grep -qF -- 'one `Closes #N` per selected member and no other' <<<"$section"
}

@test "Force selects every named member" {
  section="$(named_set_section)"
  [ -n "$section" ]
  grep -qF -- 'Force selects every named member' <<<"$section"
}

@test "a one-member subset drains alone with no cluster prompt" {
  section="$(named_set_section)"
  [ -n "$section" ]
  grep -qiF -- 'a one-member subset drains that issue alone, with no cluster prompt' <<<"$section"
}

@test "the over-budget arm prints the cost lines and the total before the prompt" {
  section="$(named_set_section)"
  [ -n "$section" ]
  cost=$(line_of '`#<N>: cost <cost> (' <<<"$section")
  total=$(line_of '`Total <total> against a budget of <budget>: over budget.`' <<<"$section")
  prompt=$(line_of "each of the scorer's \`subsets\`" <<<"$section")
  [ -n "$cost" ] && [ -n "$total" ] && [ -n "$prompt" ]
  [ "$cost" -lt "$prompt" ]
  [ "$total" -lt "$prompt" ]
}

# --- 21. the security pre-filter's two passes -------------------------------

@test "the security pre-filter names the benign-member and confirmed-private passes" {
  section="$(named_set_section)"
  [ -n "$section" ]
  security="$(extract_between '1. **Security pre-filter.**' '2. **Spec pre-filter.**' <<<"$section")"
  [ -n "$security" ]
  grep -qiF -- 'a **benign member** passes' <<<"$security"
  grep -qiF -- 'on a **confirmed-PRIVATE** repo nothing is filtered: a security-class member passes and batches normally' <<<"$security"
}
