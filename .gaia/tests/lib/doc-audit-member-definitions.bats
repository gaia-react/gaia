#!/usr/bin/env bats
#
# Doc-conformance suite for the Code Audit Team member definitions and the
# shared member protocol they point at.
#
# What it guards. A member reviews and reports and nothing else: it runs no
# `gh issue` command, carries no out-of-scope disposition pipeline, and keeps
# its handshake, sidecar, ledger accounting and holistic class list in one
# shipped protocol file rather than in a copy of its own (UAT-001, UAT-009).
# The frontend definition stays inside a byte budget so the text is removed,
# not merely moved (UAT-041). Every definition, the protocol, and the PR Merge
# Workflow dispatch template make the definition re-read conditional on the
# scope resolver's `DEFINITION=reread` line (UAT-011). The protocol carries no
# CI arm and no trailer stamping, and ships without leaking a maintainer-only
# name outside its marker blocks.
#
# The member set is derived from the `code-audit-*.md` glob, so a new member
# joins every check by existing; the roster test pins the known members as a
# floor so an empty or short glob fails rather than greening every loop.
#
# Each target reads through an env override that defaults to the real file,
# so a mutant copy proves a case can fail without touching the tree.
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENTS_DIRECTORY="${DOC_MEMBER_DEFINITIONS_AGENTS:-$REPO_ROOT/.claude/agents}"
  PROTOCOL="${DOC_MEMBER_DEFINITIONS_PROTOCOL:-$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md}"
  PR_MERGE_WIKI="${DOC_MEMBER_DEFINITIONS_PR_MERGE:-$REPO_ROOT/wiki/concepts/PR Merge Workflow.md}"
  RELEASE_EXCLUDE="${DOC_MEMBER_DEFINITIONS_RELEASE_EXCLUDE:-$REPO_ROOT/.gaia/release-exclude}"
  FRONTEND="$AGENTS_DIRECTORY/code-audit-frontend.md"
  PROTOCOL_PATH='.claude/hooks/lib/audit-member-protocol.md'

  MEMBERS=()
  local member_file
  for member_file in "$AGENTS_DIRECTORY"/code-audit-*.md; do
    [ -f "$member_file" ] && MEMBERS+=("$member_file")
  done
}

# strip_maintainer_blocks <file>: prints the file without its maintainer-only
# marker blocks, the text an adopter's scrubbed copy carries.
strip_maintainer_blocks() {
  awk '
    index($0, "<!-- gaia:maintainer-only:start -->") { inside = 1; next }
    index($0, "<!-- gaia:maintainer-only:end -->") { inside = 0; next }
    !inside { print }
  ' "$1"
}

# section_text <file> <exact heading line>: prints the section body up to the
# next heading of the same or a higher level.
section_text() {
  awk -v want="$2" '
    $0 == want { inside = 1; level = index($0, " "); next }
    inside && /^#+ / && index($0, " ") <= level { exit }
    inside { print }
  ' "$1"
}

# --- the roster every per-member loop walks ---------------------------------

@test "the member glob resolves to at least the four known members, none empty" {
  [ "${#MEMBERS[@]}" -ge 4 ] || { echo "only ${#MEMBERS[@]} member definitions found" >&2; return 1; }
  local member
  for member in code-audit-frontend code-audit-github-workflows code-audit-maintainer-node code-audit-maintainer-shell; do
    [ -s "$AGENTS_DIRECTORY/${member}.md" ] || { echo "${member}.md is missing or empty" >&2; return 1; }
  done
}

# --- UAT-001: members run no gh issue command and carry no disposition pipeline

@test "UAT-001: no member definition names a gh issue command or the file-tech-debt procedure" {
  local member_file hits
  for member_file in "${MEMBERS[@]}"; do
    hits="$(grep -nE -- 'gh issue|file-tech-debt' "$member_file" || true)"
    [ -z "$hits" ] || { echo "$member_file: $hits" >&2; return 1; }
  done
}

@test "UAT-001: no member definition carries a disposition-pipeline heading" {
  local member_file hits
  for member_file in "${MEMBERS[@]}"; do
    hits="$(grep -niE -- '^#{2,4} .*(scope classification|backend probe|divert|non-security disposition|disposition pipeline|disposition gate|disposition semantics|machinery-path waive)' "$member_file" || true)"
    [ -z "$hits" ] || { echo "$member_file: $hits" >&2; return 1; }
  done
}

# --- UAT-007: the frontend definition carries no self-heal machinery ---------

@test "UAT-007: the frontend definition has no self-heal, closing-round, promotion or audit-run-env section" {
  local hits
  hits="$(grep -niE -- '^#{2,4} .*(self-heal|closing round|in-flight|promotion|audit-run env|trailer)' "$FRONTEND" || true)"
  [ -z "$hits" ] || { echo "$hits" >&2; return 1; }
  grep -qF -- 'AUDIT_SELF_HEALED' "$FRONTEND" && { echo "the self-heal flag survives" >&2; return 1; }
  true
}

# --- UAT-009: one shared protocol, pointed at by every member -----------------

@test "UAT-009: no member definition carries a handshake, marker, sidecar or holistic class heading, and each names the protocol" {
  local member_file hits
  for member_file in "${MEMBERS[@]}"; do
    hits="$(grep -niE -- '^#{2,3} .*(gate handshake|audit marker|findings sidecar|holistic class assignment)' "$member_file" || true)"
    [ -z "$hits" ] || { echo "$member_file: $hits" >&2; return 1; }
    grep -qF -- "$PROTOCOL_PATH" "$member_file" || { echo "$member_file does not name $PROTOCOL_PATH" >&2; return 1; }
  done
}

@test "UAT-009: the protocol carries its title and the six shared headings, each exactly once" {
  [ "$(head -n 1 "$PROTOCOL")" = '# Code Audit Team: member protocol' ] || return 1
  local heading count
  for heading in \
    '## Output format' \
    '## Gate handshake (per-member marker)' \
    '## Findings sidecar (local run record)' \
    '## Re-run carry-forward ledger' \
    '## Holistic class assignment' \
    '## Honest limits'; do
    count="$(grep -cxF -- "$heading" "$PROTOCOL" || true)"
    [ "$count" -eq 1 ] || { echo "'$heading' appears $count times" >&2; return 1; }
  done
}

@test "UAT-009: the protocol's precedence clause names no holistic class-assignment section" {
  local clause
  clause="$(grep -F -- 'govern what they name' "$PROTOCOL" || true)"
  [ -n "$clause" ] || { echo "no precedence clause found" >&2; return 1; }
  grep -qiE -- 'holistic class assignment|class-assignment sections' <<<"$clause" && { echo "the clause names a class-assignment section: $clause" >&2; return 1; }
  true
}

@test "UAT-009: the protocol ships: it is absent from the release-exclude list" {
  [ -s "$RELEASE_EXCLUDE" ] || return 1
  grep -qxF -- "$PROTOCOL_PATH" "$RELEASE_EXCLUDE" && { echo "$PROTOCOL_PATH is still release-excluded" >&2; return 1; }
  true
}

@test "the protocol's maintainer-only markers are balanced and alternate" {
  local unbalanced
  unbalanced="$(awk '
    index($0, "<!-- gaia:maintainer-only:start -->") { if (inside) { print NR; exit } inside = 1; next }
    index($0, "<!-- gaia:maintainer-only:end -->") { if (!inside) { print NR; exit } inside = 0; next }
    END { if (inside) print "EOF" }
  ' "$PROTOCOL")"
  [ -z "$unbalanced" ] || { echo "marker imbalance at $unbalanced" >&2; return 1; }
}

@test "the protocol and the frontend definition name no maintainer-only member or excluded path outside marker blocks" {
  local shipped_file hits
  for shipped_file in "$PROTOCOL" "$FRONTEND"; do
    hits="$(strip_maintainer_blocks "$shipped_file" | grep -nE -- 'code-audit-maintainer-(shell|node)|\.gaia/tests/|\.gaia/cli/src' || true)"
    [ -z "$hits" ] || { echo "$shipped_file: $hits" >&2; return 1; }
  done
}

# --- UAT-041: the byte budget -------------------------------------------------

@test "UAT-041: the frontend definition is at most 70,000 bytes and with the protocol at most 100,000" {
  local frontend_bytes protocol_bytes
  frontend_bytes="$(wc -c <"$FRONTEND" | tr -d ' ')"
  protocol_bytes="$(wc -c <"$PROTOCOL" | tr -d ' ')"
  [ "$frontend_bytes" -gt 0 ] && [ "$protocol_bytes" -gt 0 ] || return 1
  [ "$frontend_bytes" -le 70000 ] || { echo "frontend definition is $frontend_bytes bytes" >&2; return 1; }
  [ $((frontend_bytes + protocol_bytes)) -le 100000 ] || { echo "frontend plus protocol is $((frontend_bytes + protocol_bytes)) bytes" >&2; return 1; }
}

# --- UAT-011: the definition re-read is conditional everywhere ------------------

# conditional_reread_line <file>: prints the lines that make the re-read
# conditional, naming both resolver outcomes and the word "only".
conditional_reread_line() {
  grep -F -- 'DEFINITION=reread' "$1" | grep -F -- 'DEFINITION=unchanged' | grep -wF -- 'only' || true
}

@test "UAT-011: every member definition and the protocol make the re-read conditional on DEFINITION=reread" {
  local audited_file
  for audited_file in "${MEMBERS[@]}" "$PROTOCOL"; do
    [ -n "$(conditional_reread_line "$audited_file")" ] || { echo "$audited_file states no conditional re-read" >&2; return 1; }
  done
}

@test "UAT-011: the PR Merge Workflow dispatch template makes the re-read conditional, with no unconditional line" {
  [ -n "$(conditional_reread_line "$PR_MERGE_WIKI")" ] || { echo "the template states no conditional re-read" >&2; return 1; }
  local unconditional
  unconditional="$(grep -F -- 'read your own agent definition' "$PR_MERGE_WIKI" | grep -vF -- 'DEFINITION=reread' || true)"
  [ -z "$unconditional" ] || { echo "unconditional re-read line: $unconditional" >&2; return 1; }
  grep -qF -- 'MANDATORY SECOND ACTION, still before any review: read your own agent definition' "$PR_MERGE_WIKI" && return 1
  true
}

# --- UAT-017 and UAT-033: no CI arm and no trailer stamping -------------------

@test "UAT-017: the protocol carries no GITHUB_ACTIONS or CI arm" {
  local hits
  hits="$(grep -nE -- 'GITHUB_ACTIONS|(^|[^A-Za-z0-9_])CI([^A-Za-z0-9_]|$)' "$PROTOCOL" || true)"
  [ -z "$hits" ] || { echo "$hits" >&2; return 1; }
}

@test "UAT-033: neither the protocol nor the frontend definition describes trailer stamping" {
  local shipped_file hits
  for shipped_file in "$PROTOCOL" "$FRONTEND"; do
    hits="$(grep -niE -- 'audit-stamp-trailer|GAIA-Audit:|trailer' "$shipped_file" || true)"
    [ -z "$hits" ] || { echo "$shipped_file: $hits" >&2; return 1; }
  done
}

# --- UAT-028: the advisory step uses the deterministic advisory command -------

@test "UAT-028: the frontend's advisory step runs gaia update-deps advisories, with no pnpm audit recipe" {
  local advisory
  advisory="$(section_text "$FRONTEND" '### Dependency-CVE advisory')"
  [ -n "$advisory" ] || { echo "no Dependency-CVE advisory section" >&2; return 1; }
  grep -qF -- 'gaia update-deps advisories' <<<"$advisory" || return 1
  grep -qF -- 'pnpm audit' "$FRONTEND" && { echo "the frontend definition still names pnpm audit" >&2; return 1; }
  grep -qE -- 'jq .*dep-audit-baseline|dep-audit-baseline.*jq' "$FRONTEND" && { echo "a baseline jq recipe survives" >&2; return 1; }
  true
}
