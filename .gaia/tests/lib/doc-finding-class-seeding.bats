#!/usr/bin/env bats
# Doc-grep coverage for the six seeded holistic finding classes
# (holistic/hollow-assertion, holistic/uncoupled-restatement,
# holistic/stale-figure, holistic/unarmed-guard,
# holistic/fail-open-discovery, holistic/partial-cause-reporting) and the
# restored workflow bucket. Five member sidecar contracts each carry a
# `## Holistic class assignment` section with one assignment line per class
# in their owning set, plus the three canonical tie-break sentences,
# verbatim. `code-audit-github-workflows.md` carries a second
# `## Workflow class assignment` section for the four `workflow/*` classes.
#
# The same instruction is duplicated across five files by design; this suite
# is the deterministic check keeping the copies in step with the schema
# instead of trusting five hand edits to stay aligned. Every grep target
# below is extracted-section-scoped (never whole-file, except where a test
# says otherwise) and ground-truthed against the real source text before
# being written, the same discipline doc-countability-prose.bats documents.

# extract_named_section <file> <heading>: prints the section body from the
# heading line up to, excluding, the next "## " heading.
extract_named_section() {
  awk -v want="$2" '
    $0 == want {found=1; print; next}
    found && /^## / {exit}
    found {print}
  ' "$1"
}

# extract_array_slugs <finding-class.ts> <ARRAY_PREFIX>: prints one
# quoted-string member per line (quotes stripped) from
# `export const <ARRAY_PREFIX>_FINDING_CLASSES = [ ... ] as const;`. Reads
# the schema's own arrays rather than hardcoding a second copy, so this suite
# reds when a future member is seeded and no prose names it.
extract_array_slugs() {
  awk -v want="export const ${2}_FINDING_CLASSES = [" '
    $0 == want {found=1; next}
    found && /\] as const;/ {exit}
    found {print}
  ' "$1" | grep -oE "'[A-Za-z0-9/_-]+'" | tr -d "'"
}

# extract_array_slugs_or_fail <finding-class.ts> <ARRAY_PREFIX>: the same, and
# fails loudly when the sweep returns nothing. Without this the awk exact-line
# test is a fail-open discovery: an edit that leaves the array intact but
# changes its declaration line, `export const HOLISTIC_FINDING_CLASSES:
# readonly string[] = [`, compiles clean, resolves every import, and makes the
# helper print nothing. Both consumers loop with `for slug in $(...)`, so a
# zero-slug sweep runs the body zero times and the test reports ok, retiring
# the coupling between the schema and the five agent definitions with no
# signal anywhere. Guard per array rather than over the four concatenated: with
# only one prefix renamed the other three still populate a combined list, so a
# combined check passes vacuously over exactly the members the caller is
# sweeping for. Same reasoning, and same shape, as extract_section_or_fail in
# doc-audit-remedy-set.bats.
extract_array_slugs_or_fail() {
  local out
  out="$(extract_array_slugs "$1" "$2")"
  [ -n "$out" ] || {
    echo "no ${2}_FINDING_CLASSES members swept from ${1}; the array's declaration line likely changed shape, and a loop here would pass vacuously" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# assert_assignment_line <section> <slug> <prefix> <file>: fails unless
# <section> contains a line matching the frozen shape (slug, criterion, and
# "Not" clause together, one line, no wrapping). `.` stands in for a literal
# backtick, the same `.?`-style trick doc-countability-prose.bats uses,
# because a literal backtick is fragile across quoting layers.
assert_assignment_line() {
  local section="$1" slug="$2" prefix="$3" file="$4"
  printf '%s\n' "$section" \
    | grep -Eq -- "^- .${prefix}/${slug}.: .+\. Not .+\.\$" || {
        echo "no well-formed assignment line for ${prefix}/${slug} in ${file}" >&2
        return 1
      }
}

# Drops every `gaia:maintainer-only` block, reproducing what the bundle scrub
# leaves on an adopter clone. Group I reads a member through this rather than
# reading the file directly, because a route stated only inside those markers
# is present in the maintainer tree and absent everywhere it is needed.
strip_maintainer_only() {
  # Rule order mirrors marker-strip.ts's own branch order, including the two
  # cases a naive start/end pair gets wrong: a line carrying BOTH markers is a
  # self-contained block and drops alone rather than opening one, and an
  # end-without-start line is kept, not swallowed.
  awk '
    skip == 1 && /gaia:maintainer-only:end/ { skip = 0; next }
    skip == 1 { next }
    /gaia:maintainer-only:start/ && /gaia:maintainer-only:end/ { next }
    /gaia:maintainer-only:start/ { skip = 1; next }
    { print }
  ' "$1"
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  FRONTEND="$ROOT/.claude/agents/code-audit-frontend.md"
  WORKFLOWS="$ROOT/.claude/agents/code-audit-github-workflows.md"
  NODE="$ROOT/.claude/agents/code-audit-maintainer-node.md"
  PROSE="$ROOT/.claude/agents/code-audit-maintainer-prose.md"
  SHELL_MEMBER="$ROOT/.claude/agents/code-audit-maintainer-shell.md"
  MEMBERS=("$FRONTEND" "$WORKFLOWS" "$NODE" "$PROSE" "$SHELL_MEMBER")

  FINDING_CLASS="$ROOT/.gaia/cli/src/schemas/finding-class.ts"

  HEADING="## Holistic class assignment"
  WORKFLOW_HEADING="## Workflow class assignment"

  # The six seeded slugs (bare, no prefix). Every member below except the
  # prose member owns all six; the prose member owns only the two
  # prose-resident ones (FC-3).
  FULL_SLUGS=(hollow-assertion uncoupled-restatement stale-figure unarmed-guard fail-open-discovery partial-cause-reporting)
  PROSE_SLUGS=(uncoupled-restatement stale-figure)
  # The four classes the prose member does not own (FC-3's exclusion), used
  # by group C's exclusivity check.
  PROSE_EXCLUDED_SLUGS=(hollow-assertion unarmed-guard fail-open-discovery partial-cause-reporting)

  WORKFLOW_SLUGS=(script-injection unsafe-pull-request-target unpinned-action broad-permissions)

  # The three canonical tie-break sentences, byte-identical (FC-6). Stored
  # once here so each appears once in the suite, not once per member.
  TB1='A check that cannot fail is a hollow assertion; a sentence a reader would act wrongly on is an uncoupled restatement.'
  TB2='A bare count or cardinality is a stale figure; any other disagreeing claim is an uncoupled restatement.'
  TB3='A discarded exit status is the already-seeded swallowed error; an element that never entered the scanned set is a fail-open discovery.'

  # The banned history vocabulary (FC-2): no definition line may turn on
  # when a disagreement began, only on the disagreement itself.
  BANNED_HISTORY_RE="was true|no longer|used to|falsified|stopped being"
}

# --- Group A: the section exists in every member -------------------------

@test "group A: code-audit-frontend.md carries a non-empty Holistic class assignment section" {
  local section
  section="$(extract_named_section "$FRONTEND" "$HEADING")"
  [ -n "$section" ] || { echo "no '$HEADING' section found in $FRONTEND" >&2; return 1; }
}

@test "group A: code-audit-github-workflows.md carries a non-empty Holistic class assignment section" {
  local section
  section="$(extract_named_section "$WORKFLOWS" "$HEADING")"
  [ -n "$section" ] || { echo "no '$HEADING' section found in $WORKFLOWS" >&2; return 1; }
}

@test "group A: code-audit-maintainer-node.md carries a non-empty Holistic class assignment section" {
  local section
  section="$(extract_named_section "$NODE" "$HEADING")"
  [ -n "$section" ] || { echo "no '$HEADING' section found in $NODE" >&2; return 1; }
}

@test "group A: code-audit-maintainer-prose.md carries a non-empty Holistic class assignment section" {
  local section
  section="$(extract_named_section "$PROSE" "$HEADING")"
  [ -n "$section" ] || { echo "no '$HEADING' section found in $PROSE" >&2; return 1; }
}

@test "group A: code-audit-maintainer-shell.md carries a non-empty Holistic class assignment section" {
  local section
  section="$(extract_named_section "$SHELL_MEMBER" "$HEADING")"
  [ -n "$section" ] || { echo "no '$HEADING' section found in $SHELL_MEMBER" >&2; return 1; }
}

# --- Group B: the assignment line, slug + criterion + Not-clause together
# (TST-007). A bare grep over the whole file would pass on a slug dropped
# anywhere in the file; extract the section first, always. -----------------

@test "group B: code-audit-frontend.md's assignment lines carry slug, criterion, and Not-clause together for all six classes" {
  local section slug
  section="$(extract_named_section "$FRONTEND" "$HEADING")"
  for slug in "${FULL_SLUGS[@]}"; do
    assert_assignment_line "$section" "$slug" holistic "$FRONTEND" || return 1
  done
}

@test "group B: code-audit-github-workflows.md's assignment lines carry slug, criterion, and Not-clause together for all six classes" {
  local section slug
  section="$(extract_named_section "$WORKFLOWS" "$HEADING")"
  for slug in "${FULL_SLUGS[@]}"; do
    assert_assignment_line "$section" "$slug" holistic "$WORKFLOWS" || return 1
  done
}

@test "group B: code-audit-maintainer-node.md's assignment lines carry slug, criterion, and Not-clause together for all six classes" {
  local section slug
  section="$(extract_named_section "$NODE" "$HEADING")"
  for slug in "${FULL_SLUGS[@]}"; do
    assert_assignment_line "$section" "$slug" holistic "$NODE" || return 1
  done
}

@test "group B: code-audit-maintainer-shell.md's assignment lines carry slug, criterion, and Not-clause together for all six classes" {
  local section slug
  section="$(extract_named_section "$SHELL_MEMBER" "$HEADING")"
  for slug in "${FULL_SLUGS[@]}"; do
    assert_assignment_line "$section" "$slug" holistic "$SHELL_MEMBER" || return 1
  done
}

@test "group B: code-audit-maintainer-prose.md's assignment lines carry slug, criterion, and Not-clause together for its two owned classes" {
  local section slug
  section="$(extract_named_section "$PROSE" "$HEADING")"
  for slug in "${PROSE_SLUGS[@]}"; do
    assert_assignment_line "$section" "$slug" holistic "$PROSE" || return 1
  done
}

# --- Group C: exclusivity, section-scoped ----------------------------------
#
# Scoped to the extracted section, never the whole file: code-audit-frontend.md
# carries a full-vocabulary mirror listing all sixteen holistic slugs (see
# "Finding classification"), which restates the schema rather than assigning
# from it, and is explicitly exempt (FC-3). A whole-file check here would
# break that mirror. In practice the prose member is the only member outside
# any class's owning set (FC-3's table), for the four classes it does not own.

@test "group C: code-audit-maintainer-prose.md's Holistic class assignment section assigns none of the four classes outside its owning set" {
  local section slug
  section="$(extract_named_section "$PROSE" "$HEADING")"
  for slug in "${PROSE_EXCLUDED_SLUGS[@]}"; do
    printf '%s\n' "$section" | grep -Eq -- "^- .holistic/${slug}.:" && {
      echo "code-audit-maintainer-prose.md's Holistic class assignment section unexpectedly assigns holistic/${slug}" >&2
      return 1
    }
  done
  true
}

# --- Group D: tie-breaks, verbatim (grep -Fq, so a paraphrase fails) ------

@test "group D: code-audit-frontend.md's section carries all three tie-break sentences verbatim" {
  local section
  section="$(extract_named_section "$FRONTEND" "$HEADING")"
  grep -Fq -- "$TB1" <<<"$section" || { echo "TB-1 missing from $FRONTEND" >&2; return 1; }
  grep -Fq -- "$TB2" <<<"$section" || { echo "TB-2 missing from $FRONTEND" >&2; return 1; }
  grep -Fq -- "$TB3" <<<"$section" || { echo "TB-3 missing from $FRONTEND" >&2; return 1; }
}

@test "group D: code-audit-github-workflows.md's section carries all three tie-break sentences verbatim" {
  local section
  section="$(extract_named_section "$WORKFLOWS" "$HEADING")"
  grep -Fq -- "$TB1" <<<"$section" || { echo "TB-1 missing from $WORKFLOWS" >&2; return 1; }
  grep -Fq -- "$TB2" <<<"$section" || { echo "TB-2 missing from $WORKFLOWS" >&2; return 1; }
  grep -Fq -- "$TB3" <<<"$section" || { echo "TB-3 missing from $WORKFLOWS" >&2; return 1; }
}

@test "group D: code-audit-maintainer-node.md's section carries all three tie-break sentences verbatim" {
  local section
  section="$(extract_named_section "$NODE" "$HEADING")"
  grep -Fq -- "$TB1" <<<"$section" || { echo "TB-1 missing from $NODE" >&2; return 1; }
  grep -Fq -- "$TB2" <<<"$section" || { echo "TB-2 missing from $NODE" >&2; return 1; }
  grep -Fq -- "$TB3" <<<"$section" || { echo "TB-3 missing from $NODE" >&2; return 1; }
}

@test "group D: code-audit-maintainer-shell.md's section carries all three tie-break sentences verbatim" {
  local section
  section="$(extract_named_section "$SHELL_MEMBER" "$HEADING")"
  grep -Fq -- "$TB1" <<<"$section" || { echo "TB-1 missing from $SHELL_MEMBER" >&2; return 1; }
  grep -Fq -- "$TB2" <<<"$section" || { echo "TB-2 missing from $SHELL_MEMBER" >&2; return 1; }
  grep -Fq -- "$TB3" <<<"$section" || { echo "TB-3 missing from $SHELL_MEMBER" >&2; return 1; }
}

@test "group D: code-audit-maintainer-prose.md's section carries TB-1 and TB-2, and TB-3 appears nowhere in the whole file" {
  local section
  section="$(extract_named_section "$PROSE" "$HEADING")"
  grep -Fq -- "$TB1" <<<"$section" || { echo "TB-1 missing from $PROSE" >&2; return 1; }
  grep -Fq -- "$TB2" <<<"$section" || { echo "TB-2 missing from $PROSE" >&2; return 1; }
  # TB-3 pairs fail-open-discovery with swallowed-error, neither of which the
  # prose member assigns (FC-6's site table), so it is checked absent from
  # the whole file rather than merely the section.
  grep -Fq -- "$TB3" "$PROSE" && {
    echo "TB-3 unexpectedly present in $PROSE, which assigns neither side" >&2
    return 1
  }
  true
}

# --- Group E: no history vocabulary (the falsification ban), section-scoped
#
# Section-scoped rather than whole-file: a member's surrounding prose may
# legitimately use a phrase like "no longer" about something else entirely;
# the ban is on definition lines only.

@test "group E: code-audit-frontend.md's section carries none of the banned history-vocabulary phrases" {
  local section
  section="$(extract_named_section "$FRONTEND" "$HEADING")"
  printf '%s\n' "$section" | grep -Eiq -- "$BANNED_HISTORY_RE" && {
    echo "banned history vocabulary present in $FRONTEND's Holistic class assignment section" >&2
    return 1
  }
  true
}

@test "group E: code-audit-github-workflows.md's section carries none of the banned history-vocabulary phrases" {
  local section
  section="$(extract_named_section "$WORKFLOWS" "$HEADING")"
  printf '%s\n' "$section" | grep -Eiq -- "$BANNED_HISTORY_RE" && {
    echo "banned history vocabulary present in $WORKFLOWS's Holistic class assignment section" >&2
    return 1
  }
  true
}

@test "group E: code-audit-maintainer-node.md's section carries none of the banned history-vocabulary phrases" {
  local section
  section="$(extract_named_section "$NODE" "$HEADING")"
  printf '%s\n' "$section" | grep -Eiq -- "$BANNED_HISTORY_RE" && {
    echo "banned history vocabulary present in $NODE's Holistic class assignment section" >&2
    return 1
  }
  true
}

@test "group E: code-audit-maintainer-shell.md's section carries none of the banned history-vocabulary phrases" {
  local section
  section="$(extract_named_section "$SHELL_MEMBER" "$HEADING")"
  printf '%s\n' "$section" | grep -Eiq -- "$BANNED_HISTORY_RE" && {
    echo "banned history vocabulary present in $SHELL_MEMBER's Holistic class assignment section" >&2
    return 1
  }
  true
}

@test "group E: code-audit-maintainer-prose.md's section carries none of the banned history-vocabulary phrases" {
  local section
  section="$(extract_named_section "$PROSE" "$HEADING")"
  printf '%s\n' "$section" | grep -Eiq -- "$BANNED_HISTORY_RE" && {
    echo "banned history vocabulary present in $PROSE's Holistic class assignment section" >&2
    return 1
  }
  true
}

# --- Group F: the workflow bucket is reachable -----------------------------

@test "group F: code-audit-github-workflows.md carries a non-empty Workflow class assignment section" {
  local section
  section="$(extract_named_section "$WORKFLOWS" "$WORKFLOW_HEADING")"
  [ -n "$section" ] || { echo "no '$WORKFLOW_HEADING' section found in $WORKFLOWS" >&2; return 1; }
}

@test "group F: code-audit-github-workflows.md's Workflow class assignment section carries a well-formed line for all four workflow/ classes" {
  local section slug
  section="$(extract_named_section "$WORKFLOWS" "$WORKFLOW_HEADING")"
  for slug in "${WORKFLOW_SLUGS[@]}"; do
    assert_assignment_line "$section" "$slug" workflow "$WORKFLOWS" || return 1
  done
}

# --- Group G: every closed-vocabulary member is reachable from prose ------
#
# The completeness sweep (RT-008: scoped to the maintainer tree, this suite's
# own habitat -- on an adopter clone the six new holistic members are
# accepted by the shipped validator, but whether any shipped prose names them
# depends entirely on the two adopter-visible members, code-audit-frontend.md
# and code-audit-github-workflows.md, so this is not a claim about an
# adopter's clone). Reads all four closed-vocabulary arrays out of
# finding-class.ts rather than hardcoding a second copy, so this test reds
# when a future member is seeded and no prose names it; a hardcoded list
# would be a stale figure by construction. Oracle-prefixed classes
# (react-doctor/, axe/, knip/, cve/) are excluded because their identifier
# space is open and owned by the tool, so there is no member list to be
# reachable from -- and they never appear in these four arrays regardless.
# `holistic/unclassified` (the fallback constant) is excluded the same way:
# it is not a member of HOLISTIC_FINDING_CLASSES, it lives outside the
# closed vocabulary on purpose, so it never appears in the array this test
# reads.

@test "group G (maintainer-tree scope): every HOLISTIC_FINDING_CLASSES, RULE_FINDING_CLASSES, WORKFLOW_FINDING_CLASSES, and PROSE_FINDING_CLASSES member is named by at least one of the five members' prose" {
  local slug found f holistic rule workflow prose
  # Each array is swept and guarded on its own line, because a command
  # substitution inside a `for` list discards its own exit status: a
  # zero-slug sweep there would contribute no words and the loop would run on
  # over the other three, which is the vacuous pass the wrapper exists to stop.
  holistic="$(extract_array_slugs_or_fail "$FINDING_CLASS" HOLISTIC)" || return 1
  rule="$(extract_array_slugs_or_fail "$FINDING_CLASS" RULE)" || return 1
  workflow="$(extract_array_slugs_or_fail "$FINDING_CLASS" WORKFLOW)" || return 1
  prose="$(extract_array_slugs_or_fail "$FINDING_CLASS" PROSE)" || return 1
  for slug in $holistic $rule $workflow $prose; do
    found=0
    for f in "${MEMBERS[@]}"; do
      grep -Fq -- "$slug" "$f" && { found=1; break; }
    done
    [ "$found" -eq 1 ] || {
      echo "no member's prose names $slug" >&2
      return 1
    }
  done
}

# --- Group I: an assigning member can still reach the classes it omits -----
#
# Group G is satisfied when ANY ONE of the five members names a slug, and
# code-audit-frontend.md's mirror satisfies it alone. So nothing above pins
# that a member which ASSIGNS holistic classes can reach the ones its own
# assignment section leaves out. code-audit-github-workflows.md is the case
# that matters: its assignment section separates six root causes, its sidecar
# example assigns `holistic/secret-exposure`, which is not one of the six, and
# the schema pointer covering the rest is release-excluded reading anyway. The
# route is asserted on the SCRUBBED text because a pointer stated only inside
# `gaia:maintainer-only` markers is present in this tree and absent on the
# adopter clone that needs it.

@test "group I: code-audit-github-workflows.md keeps an adopter-visible route to the full holistic vocabulary" {
  local scrubbed
  scrubbed="$(strip_maintainer_only "$WORKFLOWS")"
  [ -n "$scrubbed" ] || {
    echo "scrubbing $WORKFLOWS left nothing to read" >&2
    return 1
  }
  printf '%s\n' "$scrubbed" | grep -Fq -- 'code-audit-frontend.md' || {
    echo "no adopter-visible route from $WORKFLOWS to the enumerating member" >&2
    return 1
  }
  printf '%s\n' "$scrubbed" | grep -Fq -- 'Per-bucket' || {
    echo "$WORKFLOWS names the enumerating member but not the section that enumerates" >&2
    return 1
  }
  # Asserted on the TARGET, not on the pointer: greping the pointing file
  # proves only that the sentence names a heading, so renaming the heading in
  # code-audit-frontend.md would leave an adopter-visible pointer citing a
  # section that does not exist with every check in the tree still green.
  grep -Fq -- '### Per-bucket `finding_class` convention' "$FRONTEND" || {
    echo "the section $WORKFLOWS points at is missing from $FRONTEND" >&2
    return 1
  }
}

# --- Group H: the schema and the frontend mirror agree ---------------------
#
# The mirror is the only adopter-visible statement of the vocabulary, since
# finding-class.ts is release-excluded. Extracted by its line prefix rather
# than the whole "Finding classification" section, because that section also
# carries the Rule bullet, whose rule/* slugs would otherwise satisfy a loose
# section-wide match against a holistic slug string.

@test "group H: code-audit-frontend.md's Holistic mirror bullet covers every HOLISTIC_FINDING_CLASSES member" {
  local slug mirror_line holistic
  mirror_line="$(grep -F -- 'Holistic (your own cross-cutting findings):' "$FRONTEND")"
  [ -n "$mirror_line" ] || { echo "Holistic mirror bullet not found in $FRONTEND" >&2; return 1; }
  holistic="$(extract_array_slugs_or_fail "$FINDING_CLASS" HOLISTIC)" || return 1
  for slug in $holistic; do
    grep -Fq -- "$slug" <<<"$mirror_line" || {
      echo "Holistic mirror bullet in $FRONTEND is missing $slug" >&2
      return 1
    }
  done
}
