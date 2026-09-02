#!/usr/bin/env bats
# SPEC-077 UAT-007: doc-grep coverage for the settled re-key record in
# `wiki/decisions/Code Audit Team.md`'s `### Re-spawn breadcrumbs` section.
#
# That section is the only place the decision NOT to re-key the clearance
# digest is written down, and the only place the measurement that settles it
# survives at all: the ledger it summarizes is machine-local, gitignored, and
# reaped on a retention window, so nobody can re-derive those figures later.
# A prose record with no mechanism holding it in place lasts exactly as long
# as the next person editing the page remembers it is load-bearing. This
# suite is that mechanism, the same pattern `doc-machinery-waive-prose.bats`
# and `doc-difficulty-prose.bats` in this directory use: grep for frozen
# literals, ground-truthed against the actual source text, never a
# paraphrase.
#
# HONEST LIMIT, and it is a wide one. Everything here is literal presence in
# one prose surface. Nothing in this file checks that a recorded number is
# TRUE. The numbers on that page are true because they were re-derived
# against the live ledger at implementation time and stamped with the command
# that reproduces them; the only claim this suite makes is that the reproducing
# command, the denominator, and the caveats stay on the page beside them, so a
# later reader can tell a stamped measurement from a remembered one.
#
# The page-wide marker count is checked here as BALANCE plus NON-NESTING, not
# as a frozen cardinality. Group 5 proves the enclosing maintainer-only block
# carries exactly one start and one end, which is the invariant a nested pair
# violates and the one the release build fails on. Pinning the page's total
# marker count to a literal would go red the next time someone legitimately
# wraps a new maintainer-only block elsewhere on the page, which is not a
# defect this suite has any business reporting.
#
# Section extraction takes its terminator as an argument rather than scanning
# for a bare `^## `, so a shallow scan never swallows the sibling section
# whole (see doc-difficulty-prose.bats's header for the concrete hazard).
# `### Re-spawn breadcrumbs` is an H3 whose next boundary is the H2
# `## AND-aggregation at the merge gate`, so the terminator is `^#{2,3} `.
#
# Group 4 derives the report's own count keys by RUNNING the report against
# an empty root rather than restating them, per the set-coverage rule in
# .claude/rules/bats-assertions.md: the script that emits the keys is the
# artifact that owns them, and a list kept here is a list someone has to
# remember to grow.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
# `.gaia/tests/` is out of `wiki-style.md`'s scope entirely and release-
# excluded, so the SPEC/UAT traceability above and in test names below is
# correct and expected here, unlike in the shipped prose this suite guards.

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
# extract_section, plus a guard: fails loudly, rather than passing
# vacuously, when the start anchor matches nothing (a renamed or deleted
# heading). Every absence assertion below needs this most: an empty
# extraction makes a retired-wording grep report green over prose it never
# read, which is the failure those assertions exist to catch.
extract_section_or_fail() {
  local out
  out="$(extract_section "$1" "$2" "$3")"
  [ -n "$out" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# extract_enclosing_marker_block <file> <literal-needle>
# Prints the maintainer-only marker block containing <literal-needle>, from
# its opening start marker through its closing end marker inclusive. A start
# marker encountered while a block is already open is APPENDED rather than
# treated as a new block, so a nested pair shows up in the output as a second
# start line and Group 5's count assertions catch it instead of silently
# re-anchoring on the inner pair.
extract_enclosing_marker_block() {
  awk -v needle="$2" '
    !inblk && /<!-- gaia:maintainer-only:start -->/ { inblk=1; buf = $0 "\n"; next }
    inblk { buf = buf $0 "\n" }
    inblk && /<!-- gaia:maintainer-only:end -->/ {
      if (index(buf, needle)) { printf "%s", buf; found=1; exit }
      inblk=0; buf=""
    }
    END { if (!found) exit 1 }
  ' "$1"
}

# normalize_ws
# Collapses newlines and runs of whitespace to single spaces and trims the
# ends, so a sentence hard-wrapped at one width compares equal to the same
# sentence wrapped at another.
normalize_ws() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# sentences
# Reads normalized prose on stdin and prints one sentence per line, split on
# a terminating `.`/`!`/`?` followed by a space. Used only for the
# within-one-sentence proximity assertion in Group 3.
sentences() {
  normalize_ws | sed -E 's/([.!?]) /\1\n/g'
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DECISION="$ROOT/wiki/decisions/Code Audit Team.md"
  REPORT="$ROOT/.gaia/scripts/audit-respawn-report.sh"

  SECTION_START='^### Re-spawn breadcrumbs'
  SECTION_TERM='^#{2,3} '

  [ -f "$DECISION" ] || {
    echo "missing $DECISION" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Group 1: the decision itself, and that it is a decision rather than a defer
# ---------------------------------------------------------------------------

@test "SPEC-077 UAT-007 Group 1: the section states the digest stays keyed to tree content" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'The clearance digest stays keyed to tree content.' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 1: the section records a decline on measurement, not a rejection on principle" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'declined on measurement, not rejected on principle' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 1: the retired deferral wording is gone from the whole page" {
  # Absence assertion written as a positive match for the bad case plus an
  # explicit `return 1`: a `!`-negated form is exempted by `set -e` on every
  # bash version and would green with the retired wording still present.
  grep -qF -- 'the attribution query reports `peer_merge_respawns`' "$DECISION" && return 1
  grep -qF -- 'is deferred, not rejected' "$DECISION" && return 1
  true
}

# ---------------------------------------------------------------------------
# Group 2: the snapshot is stamped with what reproduces it, and with its
# own limits
# ---------------------------------------------------------------------------

@test "SPEC-077 UAT-007 Group 2: the snapshot block carries the reproducing command literal" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'audit-respawn-report.sh --since' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 2: the snapshot fence is text, not a shell-tagged block someone runs" {
  # The block is data, and a ```bash tag invites a reader to execute a
  # recorded measurement as if it were an instruction.
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- '```text' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 2: the section states the ledger is machine-local and gitignored" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'machine-local and gitignored' <<<"$section"
  grep -qF -- 'The snapshot below is the durable artifact, not the ledger.' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 2: the section states the test-generated contamination rather than correcting for it" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'test-generated observations' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 2: the peer-merge count is recorded beside its exposed-pair denominator" {
  # The whole point of exposed_pairs is that a small headline reads as a
  # measured negative rather than as an instrument that saw nothing. A
  # snapshot carrying the headline without the denominator loses that.
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'exposed_pairs' <<<"$section"
  grep -qF -- 'peer_merge_respawns' <<<"$section"
  grep -qF -- 'measured negative rather than an absence of evidence' <<<"$section"
}

# ---------------------------------------------------------------------------
# Group 3: the reopen condition points at a quantity that can move
# ---------------------------------------------------------------------------

@test "SPEC-077 UAT-007 Group 3: mid_flight_rotations and reopen appear in the same sentence" {
  local section hit
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  hit="$(printf '%s\n' "$section" | sentences | grep -F 'reopen' | grep -F 'mid_flight_rotations' || true)"
  [ -n "$hit" ] || {
    echo "no single sentence in the section carries both 'reopen' and 'mid_flight_rotations'" >&2
    return 1
  }
}

@test "SPEC-077 UAT-007 Group 3: the reopen threshold is left to the maintainer rather than written in" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- "The threshold is the maintainer's call and is deliberately not written here." <<<"$section"
}

@test "SPEC-077 UAT-007 Group 3: the trigger to look is the first window whose mid_flight_undeterminable reads zero" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'the first window whose `mid_flight_undeterminable` reads zero' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 3: the section says why the trigger is reachable at all" {
  # A later reader who "fixes" the scoping of the coverage quantity makes the
  # trigger unfirable, silently. The page has to carry the reason.
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'unable to reach zero' <<<"$section"
  grep -qF -- 'neither decidable nor undeterminable' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 3: orphaned and rotated are stated as two different claims" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'Orphaned and rotated are two different claims' <<<"$section"
  grep -qF -- 'A rotation is ordinary and self-healing; an orphaning is neither.' <<<"$section"
}

# ---------------------------------------------------------------------------
# Group 4: the two record-shape enumerations track the shapes the machinery
# actually writes and reports
# ---------------------------------------------------------------------------

@test "SPEC-077 UAT-007 Group 4: the field enumeration names both record kinds, the discriminator, and scope_digest" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'two record kinds at `schema` 2' <<<"$section"
  grep -qF -- 'discriminated by a `kind` field' <<<"$section"
  grep -qF -- 'A `spawn` record' <<<"$section"
  grep -qF -- 'A `scope` record' <<<"$section"
  grep -qF -- '`scope_digest`' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 4: the field enumeration states the pre-addition reader rule and its per-tree boundary" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'pre-addition' <<<"$section"
  grep -qF -- 'unknown rather than false' <<<"$section"
  grep -qF -- 'per-tree, not temporal' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 4: every count key the report emits is named in the section" {
  # Derived from the artifact that owns the keys -- the report script itself,
  # run against an empty root so it emits its full key set with all counts at
  # zero -- rather than restated here as a list someone must remember to grow.
  #
  # Two keys are excluded by name, each with its warrant: `schema` is the
  # record-format envelope, and `window_days` is the caller's own --since
  # argument echoed back. Both are numbers, neither is a measured quantity,
  # and neither belongs in a prose enumeration of what the query reports.
  # `since` and `ledger` need no exclusion: they are strings and the
  # numeric-value filter drops them.
  local tmp keys section count
  tmp="$(mktemp -d)"
  run bash "$REPORT" --root "$tmp" --json
  rm -rf "$tmp"
  [ "$status" -eq 0 ]

  keys="$(jq -r 'to_entries[] | select(.value | type == "number") | .key' <<<"$output" \
    | grep -vxF 'schema' | grep -vxF 'window_days')"
  [ -n "$keys" ] || {
    echo "derived no count keys from the report; a per-key assertion here would be vacuous" >&2
    return 1
  }

  # A short read is more dangerous than an empty one: a derivation that yields
  # three keys satisfies a non-empty guard while the suite silently stops
  # covering the rest. This floor is the set the settled record's own reading
  # depends on (the pair count, its denominator, the lost-clearance count, the
  # two attribution subsets, the rotation upper bound, the in-window record
  # count, and both mid-flight quantities). It is a floor, not a frozen
  # cardinality: a key added later raises it and never rots it.
  count="$(printf '%s\n' "$keys" | wc -l | tr -d ' ')"
  [ "$count" -ge 9 ]

  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  local k
  for k in $keys; do
    grep -qF -- "\`$k\`" <<<"$section" || {
      echo "report key '$k' is emitted by $REPORT but named nowhere in the section" >&2
      return 1
    }
  done
}

@test "SPEC-077 UAT-007 Group 4: the section states the two mid_flight quantities are keyed on different units" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'keyed on different units' <<<"$section"
  grep -qF -- 'keyed on **scope** records' <<<"$section"
  grep -qF -- 'keyed on **spawn** records' <<<"$section"
}

@test "SPEC-077 UAT-007 Group 4: the section describes the mixed-window line the text report prints" {
  local section
  section="$(extract_section_or_fail "$DECISION" "$SECTION_START" "$SECTION_TERM")"
  grep -qF -- 'mixed-window note' <<<"$section"
  grep -qF -- 'mixes pre-addition records with post-addition ones' <<<"$section"
}

# ---------------------------------------------------------------------------
# Group 5: the section sits inside exactly one maintainer-only pair
# ---------------------------------------------------------------------------

@test "SPEC-077 UAT-007 Group 5: the enclosing maintainer-only block carries exactly one start and one end" {
  # A nested pair fails the release build. The extractor appends rather than
  # re-anchors on an inner start, so a nested pair surfaces here as a second
  # start line.
  local block starts ends
  block="$(extract_enclosing_marker_block "$DECISION" '### Re-spawn breadcrumbs')" || {
    echo "no maintainer-only block encloses the Re-spawn breadcrumbs section in $DECISION" >&2
    return 1
  }
  starts="$(grep -c 'gaia:maintainer-only:start' <<<"$block")"
  ends="$(grep -c 'gaia:maintainer-only:end' <<<"$block")"
  [ "$starts" -eq 1 ]
  [ "$ends" -eq 1 ]
}

@test "SPEC-077 UAT-007 Group 5: the page's maintainer-only markers balance" {
  local starts ends
  starts="$(grep -c 'gaia:maintainer-only:start' "$DECISION")"
  ends="$(grep -c 'gaia:maintainer-only:end' "$DECISION")"
  [ "$starts" -eq "$ends" ]
  [ "$starts" -ge 1 ]
}

@test "SPEC-077 UAT-007 Group 5: no two maintainer-only starts on the page run without an end between them" {
  # The page-wide complement to the block check above: proves non-nesting
  # everywhere, without pinning the page's total marker count to a literal
  # that a legitimate future block would rot.
  local seq
  seq="$(grep -o 'gaia:maintainer-only:\(start\|end\)' "$DECISION" | sed 's/.*://')"
  printf '%s\n' "$seq" | awk '
    /^start$/ { if (open) { exit 1 } open = 1; next }
    /^end$/   { if (!open) { exit 1 } open = 0; next }
    END { if (open) { exit 1 } }
  ' || {
    echo "maintainer-only markers in $DECISION nest or close out of order" >&2
    return 1
  }
}
