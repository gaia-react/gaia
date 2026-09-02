#!/usr/bin/env bash
# shellcheck shell=bash
#
# Adoption check for SPEC-077's scope-digest staleness gate. The shared
# clearance writer's `--scope-digest` refusal only closes the loop when the
# omission is caught before a member spends a full review round, not after
# it calls the writer and gets refused. Nothing stops a sixth agent
# definition, or an edit to one of the five that ship today, from dropping
# `--scope-digest` again once it lands everywhere. This check makes three
# things machine-detectable:
#
#   1. Every earned clearance-write call site, across the five agent
#      definitions and every workflow copy, passes `--scope-digest`.
#   2. The frozen scope-resolution obligation literal is present, exactly
#      once, byte-identical, in all five agent definitions.
#   3. The capture command sits inside each definition's own
#      scope-resolution region, not merely mentioned somewhere later in the
#      file -- code-audit-frontend.md names `audit-scope-digest.sh` in
#      several places outside that region, so a whole-file grep would still
#      pass on a definition whose capture had been deleted from the fence
#      and survived only as a stray mention elsewhere.
#
# Scan surface for assertion 1 (and the fourth entry, why it's here):
#   .claude/agents/code-audit-*.md
#   .github/workflows/
#   .gaia/cli/src/automation/templates/workflows/
#   .gaia/cli/templates/workflows/
# The fourth is the bundled artifact byte-derived from the third;
# `.gaia/scripts/tests/audit-guard-structural.bats` already asserts the two
# hash equal, so this check's coverage of it is a cheap belt, not an
# independent judgement about a generated file.
#
# Assertion 1's join, and why two different joins: the agent definitions
# spell an earned call site as a fenced bash block whose lines end in a
# trailing backslash; the workflow copies spell the same call as an inline
# backtick-delimited code span word-wrapped across several physical lines of
# a YAML `prompt: |` block, no backslash in sight. A single pass handles
# both without knowing which file it is looking at: a line opening a triple-
# backtick fence toggles fenced mode, where lines are joined on a trailing
# backslash exactly as a shell continuation would join them; outside a
# fence, a single backtick opens or closes an inline span, and a span still
# open at end-of-line absorbs the line break as one space and keeps
# accumulating on the next line. A line-at-a-time grep cannot see either
# shape reliably, since neither the script name nor `--provenance earned`
# nor `--scope-digest` line up on one physical line often enough to be
# found together without the join.
#
# Honest limit: this is a token-and-shape check over prose, not a proof that
# a member run actually captures or reads anything. It proves a definition
# *says* it captures where scope is resolved and passes the flag on every
# earned write it spells out; a member could still say one thing and do
# another at runtime, which nothing here observes.
#
# Dual-mode, mirroring check-verb-arming-adoption.sh: source it for
# gaia_check_scope_digest_adoption, or run it directly as a script.
#
# gaia_check_scope_digest_adoption <repo_root>
#   Prints one line per finding plus a verdict line per assertion. Returns 0
#   when all three hold, 1 when any does not, 2 on the check's own failure
#   (an unresolvable root, or a repo_root with no `.claude/agents/`
#   directory at all -- nothing to scan, not a vacuous pass). <repo_root> is
#   a required parameter -- this check never derives it itself, so a bats
#   fixture can drive it against a throwaway repo.

# The five Code Audit Team members this check reasons about, in roster order.
GAIA_SDA_MEMBERS=(
  code-audit-frontend
  code-audit-github-workflows
  code-audit-maintainer-node
  code-audit-maintainer-prose
  code-audit-maintainer-shell
)

# Assertion 3's per-member scope-resolution region start anchor. Four of the
# five resolve KEY_BASE/BASE_SHA (and capture there) directly under their own
# "## Remit and self-skip" section. code-audit-frontend.md is the one
# exception: its "Remit and self-skip" only decides whether it reviews at
# all, and the fence that actually derives KEY_BASE/BASE_SHA/D_SCOPE lives
# under "### How to run" inside "## Rules-Based Audit" instead (that file's
# own "Re-run carry-forward ledger" section names this location: "the
# scope-resolution block under 'Rules-Based Audit' -> 'How to run'"). A
# uniform "## Remit and self-skip" anchor for all five would make this
# assertion vacuous for the one member it most needs to catch drift in.
GAIA_SDA_START_ANCHOR=(
  '^### How to run'
  '^## Remit and self-skip'
  '^## Remit and self-skip'
  '^## Remit and self-skip'
  '^## Remit and self-skip'
)

# Terminator: the next heading at level 2 or 3, whichever bounds the fence
# for that member. Matches the extraction idiom already in
# .gaia/tests/lib/doc-machinery-waive-prose.bats.
GAIA_SDA_REGION_TERMINATOR='^#{2,3} '

# The three directories carrying a workflow copy of the earned call site,
# beside the five agent definitions. Every regular file under each is
# scanned; nothing here depends on the copy's exact filename.
GAIA_SDA_WORKFLOW_DIRS=(
  .github/workflows
  .gaia/cli/src/automation/templates/workflows
  .gaia/cli/templates/workflows
)

# The stable anchor phrase assertion 2 uses to locate the obligation literal
# without transcribing a paraphrase of it into this script: the literal is
# read out of the first member's own file and every other member is compared
# against THAT text, so this check cannot drift from the thing it checks.
GAIA_SDA_OBLIGATION_ANCHOR='Capture your own content digest at scope resolution with'

# _gaia_sda_extract_joined <file>: prints one "logical line" per accumulated
# statement, joining continuations per the header comment above. A fenced
# code block's lines join on a trailing backslash; prose outside a fence
# joins across an inline backtick span that stays open past a line break.
_gaia_sda_extract_joined() {
  awk '
    BEGIN { in_fence = 0; in_span = 0; cont = ""; span = "" }
    {
      raw = $0
      stripped = raw
      sub(/^[[:space:]]*/, "", stripped)
      if (stripped ~ /^```/) {
        if (cont != "") { print cont; cont = "" }
        in_fence = !in_fence
        next
      }
      if (in_fence) {
        line = raw
        if (cont != "") { line = cont " " line }
        if (line ~ /\\[[:space:]]*$/) {
          sub(/\\[[:space:]]*$/, "", line)
          cont = line
          next
        }
        print line
        cont = ""
      } else {
        n = length(raw)
        for (i = 1; i <= n; i++) {
          c = substr(raw, i, 1)
          if (c == "`") {
            if (in_span) { print span; span = ""; in_span = 0 }
            else { in_span = 1; span = "" }
          } else if (in_span) {
            span = span c
          }
        }
        if (in_span) { span = span " " }
      }
    }
    END {
      if (cont != "") print cont
      # A span still open at end of file means an unmatched backtick absorbed
      # everything after it. Emit what was absorbed so a call site inside it is
      # still examined, then fail: reporting coverage over a set this parser
      # silently truncated is the fail-open shape this check exists to prevent,
      # and a single stray backtick in a 900-line prompt block is enough to
      # invert the span state for the whole remainder of the file.
      if (in_span) { if (span != "") print span; exit 3 }
    }
  ' "$1"
}

# _gaia_sda_bad_call_sites <file> <label>: prints one line per joined
# statement that names audit-write-clearance.sh with --provenance earned but
# no --scope-digest. Returns 0 iff none found in <file>.
_gaia_sda_bad_call_sites() {
  local file="$1" label="$2" hits joined
  local rc=0
  # Capture the extraction and its status separately, so a truncated scan set is
  # a finding rather than a silent all-pass. The status must be taken off the
  # assignment's own failure arm: with errexit armed a command substitution
  # hands its status to the assignment, so a following `$?` read would be dead.
  joined="$(_gaia_sda_extract_joined "$file")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: unmatched backtick leaves an inline span open at end of file; the scanned set is truncated, so coverage here cannot be trusted\n' "$label"
    return 1
  fi
  hits="$(printf '%s\n' "$joined" \
    | grep -F 'audit-write-clearance.sh' \
    | grep -F -- '--provenance earned' \
    | grep -vF -- '--scope-digest')"
  [ -z "$hits" ] && return 0
  printf '%s: earned call site missing --scope-digest\n' "$label"
  return 1
}

# _gaia_sda_assert1 <repo_root>: assertion 1 over the five definitions plus
# every file under the three workflow directories.
_gaia_sda_assert1() {
  local repo_root="$1" failed=0 member rel file wdir wfile rel2
  for member in "${GAIA_SDA_MEMBERS[@]}"; do
    rel=".claude/agents/${member}.md"
    file="$repo_root/$rel"
    if [ ! -f "$file" ]; then
      printf '%s: MISSING (agent definition not found)\n' "$rel"
      failed=1
      continue
    fi
    _gaia_sda_bad_call_sites "$file" "$rel" || failed=1
  done

  for wdir in "${GAIA_SDA_WORKFLOW_DIRS[@]}"; do
    [ -d "$repo_root/$wdir" ] || continue
    while IFS= read -r -d '' wfile; do
      rel2="${wfile#"$repo_root"/}"
      _gaia_sda_bad_call_sites "$wfile" "$rel2" || failed=1
    done < <(find "$repo_root/$wdir" -type f -print0 2>/dev/null)
  done

  [ "$failed" -eq 0 ] && printf 'earned call-site --scope-digest coverage: all pass\n'
  return "$failed"
}

# _gaia_sda_assert2 <repo_root>: the obligation literal, read from the first
# member and compared for byte identity (and exactly-once presence) against
# the other four.
_gaia_sda_assert2() {
  local repo_root="$1" failed=0 i member file count
  local -a text
  for i in "${!GAIA_SDA_MEMBERS[@]}"; do
    member="${GAIA_SDA_MEMBERS[$i]}"
    file="$repo_root/.claude/agents/${member}.md"
    text[i]=""
    if [ ! -f "$file" ]; then
      printf '.claude/agents/%s.md: MISSING\n' "$member"
      failed=1
      continue
    fi
    count="$(grep -cF -- "$GAIA_SDA_OBLIGATION_ANCHOR" "$file")"
    if [ "$count" -ne 1 ]; then
      printf '.claude/agents/%s.md: obligation literal present %s times, expected exactly 1\n' "$member" "$count"
      failed=1
      continue
    fi
    text[i]="$(grep -F -- "$GAIA_SDA_OBLIGATION_ANCHOR" "$file")"
  done

  local first="${text[0]}"
  if [ -z "$first" ]; then
    printf 'obligation literal: source-of-truth definition (%s) carries no literal to compare against\n' "${GAIA_SDA_MEMBERS[0]}"
    return 1
  fi
  for i in "${!GAIA_SDA_MEMBERS[@]}"; do
    [ -n "${text[$i]}" ] || continue
    if [ "${text[$i]}" != "$first" ]; then
      printf '.claude/agents/%s.md: obligation literal diverges from %s\n' "${GAIA_SDA_MEMBERS[$i]}" "${GAIA_SDA_MEMBERS[0]}"
      failed=1
    fi
  done

  [ "$failed" -eq 0 ] && printf 'obligation literal: byte-identical in all five definitions\n'
  return "$failed"
}

# _gaia_sda_extract_section <file> <start_ERE> <term_ERE>: prints from the
# first line matching <start_ERE> (inclusive) up to, excluding, the next
# line matching <term_ERE>.
_gaia_sda_extract_section() {
  awk -v start="$2" -v term="$3" '
    $0 ~ start { found=1; print; next }
    found && $0 ~ term { exit }
    found { print }
  ' "$1"
}

# _gaia_sda_assert3 <repo_root>: the capture command sits inside each
# member's own scope-resolution region (GAIA_SDA_START_ANCHOR), not merely
# somewhere later in the file.
_gaia_sda_assert3() {
  local repo_root="$1" failed=0 i member file section
  for i in "${!GAIA_SDA_MEMBERS[@]}"; do
    member="${GAIA_SDA_MEMBERS[$i]}"
    file="$repo_root/.claude/agents/${member}.md"
    if [ ! -f "$file" ]; then
      printf '.claude/agents/%s.md: MISSING\n' "$member"
      failed=1
      continue
    fi
    section="$(_gaia_sda_extract_section "$file" "${GAIA_SDA_START_ANCHOR[$i]}" "$GAIA_SDA_REGION_TERMINATOR")"
    if [ -z "$section" ]; then
      printf '.claude/agents/%s.md: scope-resolution region anchor "%s" matched nothing\n' "$member" "${GAIA_SDA_START_ANCHOR[$i]}"
      failed=1
      continue
    fi
    # 'sh" --capture --root', not a bare 'sh --capture': the obligation
    # literal itself (required by assertion 2, and it lives in this same
    # region) mentions `.gaia/scripts/audit-scope-digest.sh --capture` in
    # prose, backtick-closed with no --root after it. A bare substring match
    # would pass on that mention alone even with the real command deleted,
    # which is the exact vacuous-pass failure mode this assertion exists to
    # catch. The real invocation's quoted-path form
    # (`"$AUDIT_ROOT/.../audit-scope-digest.sh" --capture --root ...`)
    # always closes the quote immediately before --capture and is always
    # followed by --root; the prose mention never is.
    if printf '%s\n' "$section" | grep -qF -- 'audit-scope-digest.sh" --capture --root'; then
      printf '.claude/agents/%s.md: capture found in its scope-resolution region\n' "$member"
    else
      printf '.claude/agents/%s.md: capture NOT found in its scope-resolution region (may exist only outside it)\n' "$member"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] && printf 'scope-resolution capture placement: all five in region\n'
  return "$failed"
}

# gaia_check_scope_digest_adoption <repo_root>
gaia_check_scope_digest_adoption() {
  local repo_root="${1:?gaia_check_scope_digest_adoption requires a repo_root argument}"
  if [ ! -d "$repo_root/.claude/agents" ]; then
    printf 'check-scope-digest-adoption: %s/.claude/agents not found; nothing to scan\n' "$repo_root" >&2
    return 2
  fi

  local assert1_failed=0 assert2_failed=0 assert3_failed=0

  printf -- '-- earned call-site --scope-digest coverage --\n'
  _gaia_sda_assert1 "$repo_root" || assert1_failed=1

  printf -- '-- obligation literal --\n'
  _gaia_sda_assert2 "$repo_root" || assert2_failed=1

  printf -- '-- scope-resolution capture placement --\n'
  _gaia_sda_assert3 "$repo_root" || assert3_failed=1

  [ "$assert1_failed" -eq 0 ] && [ "$assert2_failed" -eq 0 ] && [ "$assert3_failed" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-scope-digest-adoption: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_scope_digest_adoption "$repo_root"
  exit $?
fi
