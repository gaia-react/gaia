#!/usr/bin/env bats
# Doc-grep coverage for the catch-up merge step in
# `wiki/concepts/PR Merge Workflow.md`'s
# `#### Before the first dispatch: verify your own work` section.
#
# `.gaia/tests/lib/doc-merge-workflow-fences.bats` proves the fence PARSES
# and every path/flag it cites resolves; it reads no prose at all. This
# suite is the complement: it pins that the prose sitting beside the fence
# still says what the plan requires, by literal grep. Honest limit, stated
# once here rather than at each test: this pins literal presence in one
# prose surface, never that the `git merge` command succeeds when run, and
# never the sentence's meaning. That ceiling is deliberate, not a shortcut,
# the fences suite already owns "does it run" for what can run at all.
#
# Section extraction. The start heading is H4 (`#### Before the first
# dispatch: ...`); a bare `^## ` terminator would run straight past its own
# heading depth and swallow every H3/H4 sibling section after it (`### 2.
# Fix all issues`, the marker-handshake section, ...) whole, and a
# `rotates a member's digest under it` mention anywhere in there would
# satisfy the presence check below while proving nothing about placement.
# `extract_section` takes the terminator as an argument for this reason;
# callers pass the same-or-shallower pattern for the heading depth they
# started at, `^#{1,4} ` from this H4 start, mirroring
# `doc-difficulty-prose.bats`'s `^#{2,3} ` for an H3 start.
#
# macOS's /usr/bin/awk strips a backslash out of a `-v` assignment's value
# before the regex engine ever sees it, so an anchor built with `\(...\)`
# silently loses its literal-paren escaping (see
# `doc-machinery-waive-prose.bats`'s header). None of the anchors below
# carry a backslash, so the hazard does not fire here; noted so the next
# edit to this file knows why it stays that way.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded and out of `wiki-style.md`'s scope, so this header's own
# prose is not itself subject to the present-tense/no-identifier rule that
# governs the page under test.

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
# extract_section, plus a guard against a vacuous pass: if the start anchor
# stops matching (heading renamed, reworded, deleted), extract_section
# prints nothing, a presence check over empty input passes having examined
# nothing, and this suite would green through a page that no longer says
# what it claims to.
extract_section_or_fail() {
  local out
  out="$(extract_section "$1" "$2" "$3")"
  [ -n "$out" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
    return 1
  }
  printf '%s\n' "$out"
}

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/wiki/concepts/PR Merge Workflow.md"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  SECTION_START='^#### Before the first dispatch: verify your own work'
  SECTION_TERM='^#{1,4} '
}

@test "the section helper stops the dispatch section at the next heading, not past it" {
  local out
  out="$(extract_section_or_fail "$PAGE" "$SECTION_START" "$SECTION_TERM")" || return 1
  printf '%s\n' "$out" | grep -qF -- '#### Parallel dispatch' && return 1
  printf '%s\n' "$out" | grep -qF -- '### 2. Fix all issues' && return 1
  true
}

@test "the consequence literal survives inside the pre-dispatch section" {
  local section
  section="$(extract_section_or_fail "$PAGE" "$SECTION_START" "$SECTION_TERM")" || return 1
  printf '%s\n' "$section" | grep -qF -- "rotates a member's digest under it" || return 1
}

@test "the catch-up fence's two command lines both survive inside the pre-dispatch section" {
  local section
  section="$(extract_section_or_fail "$PAGE" "$SECTION_START" "$SECTION_TERM")" || return 1
  printf '%s\n' "$section" | grep -qF -- "git fetch origin main" || return 1
  printf '%s\n' "$section" | grep -qF -- "git merge --no-edit origin/main" || return 1
}

@test "the catch-up merge fence appears before the resolve-audit-spawn.sh fence in the page" {
  # Whole-line exact match, not a substring grep: `resolve-audit-spawn.sh` is
  # also named in backtick-quoted prose earlier in the page (the "Who audits"
  # section), and that inline mention is not the fence this test orders
  # against. The fence body is its own bare line, `bash
  # .gaia/scripts/resolve-audit-spawn.sh` with nothing else on it, which a
  # prose sentence embedding the same command never is.
  local catchup_line spawn_line
  catchup_line="$(grep -nxF -- "git merge --no-edit origin/main" "$PAGE" | head -1 | cut -d: -f1)"
  spawn_line="$(grep -nxF -- "bash .gaia/scripts/resolve-audit-spawn.sh" "$PAGE" | head -1 | cut -d: -f1)"
  [ -n "$catchup_line" ] || {
    echo "no line in the page carries the catch-up merge fence's command" >&2
    return 1
  }
  [ -n "$spawn_line" ] || {
    echo "no line in the page carries the resolve-audit-spawn.sh fence's command" >&2
    return 1
  }
  [ "$catchup_line" -lt "$spawn_line" ] || {
    echo "the catch-up merge fence (line ${catchup_line}) does not precede the resolve-audit-spawn.sh fence (line ${spawn_line})" >&2
    return 1
  }
}

@test "the page's maintainer-only marker pairs stay balanced" {
  local starts ends
  starts="$(grep -cF -- 'gaia:maintainer-only:start' "$PAGE")"
  ends="$(grep -cF -- 'gaia:maintainer-only:end' "$PAGE")"
  # Non-zero as well as equal: a page with the markers stripped entirely
  # would pass a bare equality check (0 == 0) without having examined
  # anything, the same vacuous-pass shape extract_section_or_fail guards
  # against above.
  [ "$starts" -gt 0 ] || {
    echo "the page carries no gaia:maintainer-only:start markers at all" >&2
    return 1
  }
  [ "$starts" -eq "$ends" ] || {
    echo "marker imbalance: ${starts} start markers, ${ends} end markers" >&2
    return 1
  }
}
