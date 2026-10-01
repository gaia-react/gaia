#!/usr/bin/env bats
# Structural tests for the adversarial-audit dispatch wiring: the no-op
# detection/retry/inline-fallback wiring that survives in
# code-audit-frontend.md's own internal specialist/refuter fan-out, and the
# shared clearance-writer invocation across every Code Audit Team member.
#
# The detection predicate itself is deterministic and unit-tested by the
# sibling suite `audit-noop-detect.bats`. The orchestration wiring still
# tested here (code-audit-frontend.md's specialist and refuter dispatch
# sites) is agent-executed instruction prose, not code, so it cannot be
# exercised end-to-end; these assertions are structural: each site's prose is
# grepped for the shared predicate, the exactly-one retry, and the inline
# fallback (stronger than guard-line presence alone).
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  CRA_MD="$REPO_ROOT/.claude/agents/code-audit-frontend.md"

  # SPEC-042 clearance-writer surfaces (UAT-020 structural half + PLAN-001).
  SHELL_MD="$REPO_ROOT/.claude/agents/code-audit-maintainer-shell.md"
  NODE_MD="$REPO_ROOT/.claude/agents/code-audit-maintainer-node.md"
  WORKFLOWS_MD="$REPO_ROOT/.claude/agents/code-audit-github-workflows.md"
  # The maintainer members' shared handshake; both maintainer definitions point here.
  PROTOCOL_MD="$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md"
}

# section_between FILE START END: prints the lines from the first line
# matching START (inclusive) up to (not including) the next line matching
# END. END empty -> captures to EOF. START/END are ERE patterns matched with
# awk's `~`; a literal `.` in a heading number (e.g. "4.6a") matches itself,
# so no escaping is needed for the heading numbers used below.
section_between() {
  local file="$1" start="$2" end="$3"
  if [ -n "$end" ]; then
    awk -v start="$start" -v end="$end" '
      $0 ~ start { capture=1 }
      capture && $0 ~ end && $0 !~ start { exit }
      capture { print }
    ' "$file" 2>/dev/null
  else
    awk -v start="$start" '
      $0 ~ start { capture=1 }
      capture { print }
    ' "$file" 2>/dev/null
  fi
}

# assert_section_nonempty NAME CONTENT: fails loudly (not a silent skip) when
# a section extraction came back empty, the delimiting heading was not
# found. Per the plan: a missing `##### 7b-i/ii/iii` sub-heading (or any
# other site heading) is a real Phase-2 gap and must surface as a failure,
# never silently degrade to a whole-file grep.
assert_section_nonempty() {
  local name="$1" content="$2"
  if [ -z "$content" ]; then
    echo "section '$name' is empty -- delimiting heading not found (Phase-2 gap)" >&2
    return 1
  fi
}

# assert_predicate_retry_fallback CONTENT: the three literal FC-7 anchors.
assert_predicate_retry_fallback() {
  local content="$1"
  grep -qF -- "audit-noop-detect.sh" <<<"$content"
  grep -qF -- "exactly one" <<<"$content"
  grep -qF -- "inline fallback" <<<"$content"
}

# 2. Predicate + one-retry + inline-fallback at code-audit-frontend.md's own
#    internal specialist/refuter fan-out sites.

@test "wiring: code-audit-frontend.md specialist dispatch site" {
  content="$(section_between "$CRA_MD" '^### How to run' '^### Knip findings')"
  assert_section_nonempty "code-audit-frontend.md How to run" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: code-audit-frontend.md adversarial-refuter dispatch site" {
  content="$(section_between "$CRA_MD" '^## Finding Proof Gate' '^## Scope classification')"
  assert_section_nonempty "code-audit-frontend.md Finding Proof Gate" "$content"
  assert_predicate_retry_fallback "$content"
}

# 6. Shared clearance writer: every handshake surface (the frontend member's
#    and github-workflows definitions, and the maintainer members' shared
#    protocol file) invokes the ONE shared writer, both maintainer definitions
#    point at that protocol file,
#    and NONE still carries the inline marker `printf`
#    or the `[ ! -f "$marker" ]` idempotence guard. This negative assertion is
#    load-bearing: a missed producer keeps writing a legacy-bodied marker that
#    every existence-only consumer honors, so the gate passes and the only
#    symptom is a member that silently never carries forward.

@test "clearance writer: the handshake surfaces invoke the shared writer, none keeps the inline printf or the [ ! -f marker ] guard" {
  local md
  # The frontend and github-workflows members carry their own handshake; the
  # maintainer members carry theirs in the shared protocol file.
  for md in "$CRA_MD" "$WORKFLOWS_MD" "$PROTOCOL_MD"; do
    # Positive: invokes the one shared writer.
    grep -qF -- ".gaia/scripts/audit-write-clearance.sh" "$md" || return 1
  done
  for md in "$CRA_MD" "$PROTOCOL_MD" "$SHELL_MD" "$NODE_MD" "$WORKFLOWS_MD"; do
    # Negative: no inline marker printf (the bad case is a present match).
    grep -qF -- 'printf '\''{"sha"' "$md" && return 1
    # Negative: no idempotence guard (the bad case is a present match).
    grep -qF -- '[ ! -f "$marker" ]' "$md" && return 1
  done
  # Each maintainer member reaches the writer only through the protocol file,
  # so a definition that drops the pointer has no marker command at all.
  for md in "$SHELL_MD" "$NODE_MD"; do
    grep -qF -- ".claude/hooks/lib/audit-member-protocol.md" "$md" || return 1
  done
  return 0
}
