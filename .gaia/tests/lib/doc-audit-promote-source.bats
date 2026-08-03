#!/usr/bin/env bats
# doc-grep coverage for the `promote` action's source-side contract in
# `.claude/skills/gaia/references/audit.md`, stated only as prose and read by
# a Sonnet Stage 1 that writes the action blocks and a Sonnet Stage 2 that
# applies them.
#
# The defect this pins: lifting a section out of an over-budget file onto a
# wiki page took a `promote` plus a `shrink` on that one file. `## Ordering`
# runs every shrink before every promote, so the shrink moved the file out
# from under the promote's recorded `source_expect_sha256`; the promote then
# read its own pair as drift and skipped, leaving a wikilink pointing at a
# page that was never written. The promote now performs the source-side edit
# itself (`source_action: replace`), so the pair is never built.
#
# Two halves, and both are load-bearing:
#
#   - The POSITIVE half is the new schema and the apply-loop arms that read
#     it. A half-applied rename is the sharpest hazard here: a schema still
#     offering `delete_source_after` while the loop switches on
#     `source_action` leaves Stage 2 with no arm for what Stage 1 wrote, so
#     Group 1's whole-file absence check is not tidiness.
#   - The NEGATIVE half is what this fix deliberately did NOT touch:
#     `## Ordering` keeps one flat type order and the dependency gate stays
#     `delete-entry`-only. Those are the invariants the chosen design bought,
#     and the plausible "improvement" is to reintroduce the pair behind an
#     ordering carve-out plus a gated shrink, which re-opens the defect from
#     the other side. Group 5 is what makes that edit fail loudly.
#
# Step 3's remedy-1 prose, the surface that tells Stage 1 to use this, is
# pinned by `doc-audit-remedy-set.bats` in this directory. The two suites
# meet at `source_action: replace` and neither restates the other.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test, and a
# `!`-negated command never fails a non-final line on any bash. Every absence
# check below is written as `<positive-condition-for-the-bad-case> &&
# return 1`, and a test whose last statement is such a check ends with an
# explicit `true`.
#
# `.gaia/tests/` is release-excluded and outside `wiki-style.md`'s scope, so
# the failure-mode narration above is correct here in a way it would not be
# in the shipped prose this suite guards.

# extract_section <file> <start_ERE> <terminator_ERE>
# Prints from the first line matching <start_ERE> (inclusive) up to,
# excluding, the next line matching <terminator_ERE>.
extract_section() {
  awk -v start="$2" -v term="$3" '
    $0 ~ start { found=1; print; next }
    found && $0 ~ term { exit }
    found { print }
  ' "$1"
}

# extract_section_or_fail <file> <start_ERE> <terminator_ERE>
# extract_section, plus guards on both ends.
#
# Never call this on the left of a pipe. A pipeline's exit status is its LAST
# command's, so `extract_section_or_fail ... | normalize_ws` discards this
# function's `return 1` and hands back an empty string with status 0, which
# greens every `&& return 1` absence check in the suite on a section that no
# longer exists. Capture first, normalize second; every call site below does.
#
# An unmatched START anchor yields an empty section, which greens every
# absence check. An unmatched TERMINATOR is the quieter hazard: awk runs to
# EOF and the "section" swallows the rest of the file, so a literal that is
# not unique file-wide (`source_action`, `source_path`) could satisfy a scoped
# assertion from text outside the section while the section itself had lost
# the sentence. Both are refused.
#
# The section must not be the file's last: a final section has no terminator
# by construction, and this helper cannot tell that case from a deleted
# heading, so it refuses both. Every section scoped below has content after
# it. This guard is local to this suite; the same helper name in the sibling
# doc-grep suites guards a different set of ends. Do not assume a shared
# contract across the copies.
extract_section_or_fail() {
  local out start_line
  out="$(extract_section "$1" "$2" "$3")"
  [ -n "$out" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
    return 1
  }
  # Locate the start line with the SAME engine `extract_section` used. awk's
  # `-v` consumes one backslash level at assignment time, so an escaped ERE
  # means different things to awk and to `grep -E`; re-finding the line with
  # grep would let the two disagree, and an unresolved `start_line` would
  # silently become a file-wide check that proves nothing.
  start_line="$(awk -v start="$2" '$0 ~ start { print NR; exit }' "$1")"
  [ -n "$start_line" ] || {
    echo "start anchor '${2}' resolved to no line number in ${1}" >&2
    return 1
  }
  # The terminator must match STRICTLY AFTER the start line: a file-wide
  # match proves nothing, since `^### ` matches every earlier H3 while this
  # section still runs to EOF.
  awk -v s="$start_line" -v term="$3" 'NR > s && $0 ~ term { found = 1; exit } END { exit !found }' "$1" || {
    echo "terminator '${3}' matches nothing after line ${start_line} of ${1}; either the section ran to EOF and swallowed the rest of the file, or it is the file's last section, which this helper does not support" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# normalize_ws
# Collapses newlines and runs of whitespace to single spaces and trims the
# ends, so a sentence rewrapped at another width, or a YAML key indented
# inside a fenced block, still compares equal.
normalize_ws() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# scoped <start_ERE> <terminator_ERE>
# extract_section_or_fail + normalize_ws, in the two-step order that keeps
# the guard's exit status (see its header).
scoped() {
  local out
  out="$(extract_section_or_fail "$AUDIT" "$1" "$2")" || return 1
  printf '%s\n' "$out" | normalize_ws
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AUDIT="$ROOT/.claude/skills/gaia/references/audit.md"

  # `-s`, not `-f`: an empty file would satisfy `-f` and then green every
  # whole-file absence check below on nothing.
  [ -s "$AUDIT" ] || {
    echo "missing or empty $AUDIT" >&2
    return 1
  }
}

# --- Group 1: the schema offers the three source modes, and only those -----

@test "the promote schema offers source_action with its three modes" {
  local promote
  promote="$(scoped '^### Promote' '^### ')"
  grep -qF -- 'source_action: {delete | replace | keep}' <<<"$promote"
}

@test "the promote schema carries the replace pair" {
  local promote
  promote="$(scoped '^### Promote' '^### ')"
  grep -qF -- 'source_before: |' <<<"$promote"
  grep -qF -- 'source_after: |' <<<"$promote"
}

@test "the replace pair is marked as belonging to one mode only" {
  # Without the qualifier a Stage 1 emits the pair on every promote,
  # including the `delete` case where it contradicts the mode.
  local promote
  promote="$(scoped '^### Promote' '^### ')"
  grep -qF -- 'omit unless source_action=replace' <<<"$promote"
}

@test "delete_source_after survives nowhere in the file" {
  # The whole-file scope is the point. A schema still offering the old key
  # while the apply loop switches on `source_action` leaves Stage 2 with no
  # arm for what Stage 1 wrote, and a half-applied rename reads as a
  # deliberate two-field design to whoever edits next.
  grep -qF -- 'delete_source_after' "$AUDIT" && return 1
  true
}

@test "the schema states that a same-file extraction is this one action" {
  local promote
  promote="$(scoped '^### Promote' '^### ')"
  grep -qF -- 'never a promote plus a `shrink` on `source_path`' <<<"$promote"
}

@test "the source_action claim is scoped to the promote that carries it" {
  # Unscoped, "the only thing that touches source_path" contradicts
  # `## Ordering`'s own rationale that "promotes run before the deletes that
  # remove their sources", which presupposes a `delete` reaching that same
  # path. Both cannot be right and nothing would tell a reader which
  # governs. The scoping qualifier is what keeps the sentence true.
  local promote
  promote="$(scoped '^### Promote' '^### ')"
  grep -qF -- 'Within a promote, `source_action` is the only field' <<<"$promote"
}

# --- Group 2: the promote's drift check is reachable -----------------------
# The apply loop's two generic drift bullets name `expect_sha256` and
# `before:`/`expect:`. A promote carries `source_expect_sha256` and
# `target_expect`, so neither bullet reaches it and, before this arm existed,
# nothing in the playbook said what Stage 2 checks. That gap is what let the
# same-file pair's outcome depend on an executor's interpretation.

@test "the apply loop checks the promote's source sha against its source path" {
  local loop
  loop="$(scoped '^### Per-action loop' '^### ')"
  grep -qF -- 'compute sha256 of `source_path` against `source_expect_sha256`' <<<"$loop"
}

@test "the apply loop says why the generic drift bullets do not reach a promote" {
  # A bare instruction to check these two fields invites an editor to fold it
  # back into the first bullet, which silently drops the target-side check.
  local loop
  loop="$(scoped '^### Per-action loop' '^### ')"
  grep -qF -- 'so neither bullet above reaches it' <<<"$loop"
}

@test "the Actions preamble makes no blanket claim about an expect field" {
  # The preamble used to require `expect` on every block, which is false for
  # three of the four schemas and became a stated contradiction the moment
  # the promote bullet above said a promote carries no such field. In a file
  # whose executor is told not to reason about intent, a Stage 1 satisfying
  # the blanket rule literally emits a promote with a stray `expect:` key and
  # the generic snippet bullet then fires on a correct promote. Scoped to the
  # preamble paragraph, which ends at the first action-type heading.
  local preamble
  preamble="$(scoped '^## Actions' '^### ')"
  grep -qF -- 'Every block MUST include `expect`' <<<"$preamble" && return 1
  true
}

@test "the apply loop checks the target snippet except when creating the page" {
  local loop
  loop="$(scoped '^### Per-action loop' '^### ')"
  grep -qF -- 'unless `target_action: create_new`, confirm `target_expect` appears verbatim in `target_page`' <<<"$loop"
}

# --- Group 3: the apply arm acts on the mode, last, and fails closed -------

@test "the apply arm names an operation for each of the three modes" {
  local loop
  loop="$(scoped '^### Per-action loop' '^### ')"
  grep -qF -- '`delete` removes `source_path`' <<<"$loop"
  grep -qF -- '`replace` edits it with `old_string: source_before` / `new_string: source_after`' <<<"$loop"
  grep -qF -- '`keep` leaves it alone' <<<"$loop"
}

@test "the apply arm puts the source edit last and says why" {
  # The ordering is the atomicity. Without the reason recorded, a later
  # editor reads it as incidental sequencing and is free to hoist the source
  # edit above the wiki write, which loses the content on a failed write.
  local loop
  loop="$(scoped '^### Per-action loop' '^### ')"
  grep -qF -- 'The source goes last so a wiki write that fails leaves it intact' <<<"$loop"
}

@test "the loop fails closed on a source_action it does not recognize" {
  # A report stays applicable for up to 72h, so a report written against the
  # superseded schema can reach a Stage 2 running this one. Guessing is the
  # one outcome that mutates a source file on an unread instruction.
  local loop
  loop="$(scoped '^### Per-action loop' '^### ')"
  grep -qF -- 'unknown source_action' <<<"$loop"
  grep -qF -- 'never guess which was meant' <<<"$loop"
}

@test "the mode check runs before any write, not in the apply step" {
  # Schema validity is knowable before the first write. Checked in the apply
  # step instead, an unrecognized mode fails only after the wiki page, the
  # log prepend and the index append have all landed, so a malformed action
  # half-applies. The reason is pinned, not just the placement, because the
  # placement alone reads as arbitrary to whoever tidies this next.
  local loop
  loop="$(scoped '^### Per-action loop' '^### ')"
  grep -qF -- 'It is a schema-validity check on a value knowable before any write' <<<"$loop"
}

# --- Group 4: post-apply verification covers the source side --------------

@test "verification checks the source per mode" {
  local verify
  verify="$(scoped '^### Post-apply verification' '^### ')"
  grep -qF -- 'verify the source per `source_action`' <<<"$verify"
  grep -qF -- '`delete` → confirm `source_path` is gone' <<<"$verify"
  grep -qF -- '`replace` → confirm `source_after` appears in `source_path`' <<<"$verify"
}

@test "the replace arm asserts no absence, and says why" {
  # Asserting `source_before` is absent would downgrade a correct apply
  # whenever that block legitimately survives elsewhere in the file. The
  # reason is pinned because the absence check is the obvious-looking
  # addition, and it fails in the direction that reports a good promote as
  # unverified.
  local verify
  verify="$(scoped '^### Post-apply verification' '^### ')"
  grep -qF -- 'asserting its absence would downgrade a correct apply' <<<"$verify"
}

@test "the replace arm proves the edit landed, not just that the link is present" {
  # The fail-open on the other side of that trade: `source_after` is
  # typically a wikilink, and a file being thinned may already link the page,
  # so a bare presence check passes whether or not the Edit ran. The sha
  # comparison is what carries it, and it does so without asserting any
  # absence.
  local verify
  verify="$(scoped '^### Post-apply verification' '^### ')"
  grep -qF -- "the file's sha256 now differs from \`source_expect_sha256\`" <<<"$verify"
}

# --- Group 5: what this design bought, and must keep ----------------------
# Absorbing the source edit into the promote was chosen over an ordering
# carve-out plus a gated shrink precisely so these two stay simple. Both are
# what a well-meaning "let the pair work properly" edit would change first.

@test "Ordering keeps one flat type order" {
  local ordering
  ordering="$(scoped '^## Ordering' '^## ')"
  grep -qF -- 'apply actions in this order: `shrink` → `promote` → `delete` → `delete-entry`' <<<"$ordering"
}

@test "Ordering carves out no same-path exception" {
  # The rejected alternative: run a promote and its paired shrink together,
  # ahead of the general shrink phase. It puts one action type in two phases
  # and makes Stage 2 detect the pairing.
  #
  # Three needles, and the width is the whole point. The document backticks
  # every action type and its word for this concept is *file*, not *path*, so
  # a `same path` needle alone misses the phrasing the codebase would
  # actually reach for; and `paired shrink` cannot match ``paired `shrink` ``
  # at all, because a backtick sits between the two words. `paired` bare is
  # what survives every backticked variant. All three are absent from the
  # section today, so each is a live needle rather than a tautology.
  local ordering
  ordering="$(scoped '^## Ordering' '^## ')"
  grep -qF -- 'same path' <<<"$ordering" && return 1
  grep -qF -- 'same file' <<<"$ordering" && return 1
  grep -qF -- 'paired' <<<"$ordering" && return 1
  true
}

@test "the dependency gate stays delete-entry only" {
  # Widening `depends_on` to `replace` is the other half of the rejected
  # alternative. The parenthetical is the whole guard: it states the scope
  # positively and says every other action skips the step.
  local loop
  loop="$(scoped '^### Per-action loop' '^### ')"
  grep -qF -- 'Dependency gate (`delete-entry` carrying `depends_on` only; every other action skips this step)' <<<"$loop"
}

@test "the shrink schema takes on no dependency field" {
  local shrink
  shrink="$(scoped '^### Shrink / Convert' '^## ')"
  grep -qF -- 'depends_on' <<<"$shrink" && return 1
  true
}
