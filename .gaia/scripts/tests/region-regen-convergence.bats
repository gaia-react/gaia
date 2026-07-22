#!/usr/bin/env bats
# Tests for the interaction between .gaia/scripts/write-audit-remits.sh (the
# region writer) and .gaia/scripts/verify-audit-roster.sh (the roster check)
# that neither script's own suite asserts:
#
#   - convergence and parity, measured independently of the check's
#     process-wide exit status (an empirical run with the whole remit region
#     replaced by bogus globs still exits 0, because that exit answers other
#     invariants too and is insensitive to any one region's content)
#   - byte-identical convergence on a second writer run
#   - that regeneration observes a roster already carrying a GAIA-authored
#     addition, not a stale pre-merge one
#
# Every scratch tree is fully self-contained: a copy of both shipped scripts
# plus the roster-parsing library they depend on, so no invocation ever
# touches the real repository's roster or agent definitions. --root and
# --config are passed explicitly on every writer and check call:
# write-audit-remits.sh defaults its root to a git toplevel resolved from
# its OWN directory, and an implicit default here could resolve outside the
# scratch tree entirely (a copy under BATS_TEST_TMPDIR is not a git
# repository) or, on a tree that happens to sit inside a checkout, rewrite
# the REAL repository's `.claude/agents/*.md`. Neither shipped script is
# ever modified; only the fixture copies under BATS_TEST_TMPDIR are.
#
# Assertion style (.claude/rules/bats-assertions.md): non-final checks use
# POSIX `[ ]` or `grep -qF`, never a bare `[[ ]]`, which macOS's bash 3.2
# does not fail on. Absence is asserted as `<positive-condition> && return
# 1`, never as a non-final `!`-negation, which `set -e` exempts on every
# bash version.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WRITER_SRC="$REPO_ROOT/.gaia/scripts/write-audit-remits.sh"
  CHECK_SRC="$REPO_ROOT/.gaia/scripts/verify-audit-roster.sh"
  LIB_SRC="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  REMIT_START='<!-- gaia:audit-remit:start -->'
  REMIT_END='<!-- gaia:audit-remit:end -->'
  # Hard failures, not skips: a `skip` here would silently retire every test
  # in this suite to skipped-and-green if a committed dependency went missing.
  if [ ! -f "$WRITER_SRC" ]; then
    printf 'write-audit-remits.sh missing: %s\n' "$WRITER_SRC" >&2
    return 1
  fi
  if [ ! -f "$CHECK_SRC" ]; then
    printf 'verify-audit-roster.sh missing: %s\n' "$CHECK_SRC" >&2
    return 1
  fi
  if [ ! -f "$LIB_SRC" ]; then
    printf 'audit-scope.sh missing: %s\n' "$LIB_SRC" >&2
    return 1
  fi
}

# A fully self-contained scratch tree at $1: copies of the writer, the
# check, and the roster-parsing library the check sources from its own
# on-disk location (script-relative, .gaia/scripts -> ../../.claude/hooks/lib),
# so a scratch invocation never reaches the real repository's copies.
scaffold_scripts() {
  local sb="$1"
  mkdir -p "$sb/.gaia/scripts" "$sb/.claude/hooks/lib" "$sb/.claude/agents"
  cp "$WRITER_SRC" "$sb/.gaia/scripts/write-audit-remits.sh"
  cp "$CHECK_SRC" "$sb/.gaia/scripts/verify-audit-roster.sh"
  cp "$LIB_SRC" "$sb/.claude/hooks/lib/audit-scope.sh"
}

# One agent stub carrying the `## Remit and self-skip` anchor the writer
# inserts a fresh region after, and no region of its own yet.
write_agent_stub() {
  local sb="$1" name="$2"
  cat > "$sb/.claude/agents/$name.md" <<MD
---
name: $name
---

# $name

## Remit and self-skip

You own things.
MD
}

run_writer() {
  run bash "$1/.gaia/scripts/write-audit-remits.sh" --root "$1" --config "$1/.gaia/audit-ci.yml"
}

run_check() {
  run bash "$1/.gaia/scripts/verify-audit-roster.sh" --root "$1" --config "$1/.gaia/audit-ci.yml"
}

# Replaces a member's region body with a single bogus, roster-ungranted
# glob, dropping every glob bullet the roster actually grants. Leaves the
# marker lines and the canonical sentence below them untouched.
perturb_region() {
  local f="$1"
  awk -v s="$REMIT_START" -v e="$REMIT_END" '
    $0 == s { print; print "- `bogus/perturbed/**`"; infl = 1; next }
    $0 == e { infl = 0; print; next }
    infl && /^- `.*`$/ { next }
    { print }
  ' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

# Whether a remit-parity finding (missing / ungranted / order) names $2 as
# the member, read from $1 (the check's captured output).
remit_parity_names_member() {
  local text="$1" name="$2"
  grep -B1 -E "member:[[:space:]]+${name}\$" <<<"$text" \
    | grep -qE "FAIL remit-glob-(missing|ungranted|order)"
}

# ---------------------------------------------------------------------------
# Convergence and parity, without the process-wide exit status
# ---------------------------------------------------------------------------

@test "writer repairs a perturbed region and the check's parity finding for that member is gone" {
  local sb="$BATS_TEST_TMPDIR/sb"
  scaffold_scripts "$sb"
  cat > "$sb/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-region-default
    globs:
      - "src/**"
      - "lib/*.ts"
    default: true
  - name: code-audit-region-claim
    globs:
      - "docs/**"
      - "guides/*.md"
YAML
  write_agent_stub "$sb" code-audit-region-default
  write_agent_stub "$sb" code-audit-region-claim

  run_writer "$sb"
  [ "$status" -eq 0 ]

  perturb_region "$sb/.claude/agents/code-audit-region-claim.md"

  run_writer "$sb"
  [ "$status" -eq 0 ]

  run_check "$sb"
  # The check's process-wide exit status answers several invariants at once
  # (default-member-count, machinery registration, glob disjointness, remit
  # parity for every OTHER member too) and is insensitive to any one
  # region's content, so a green exit here proves nothing about the
  # perturbed-then-repaired member specifically. Only the absence of ITS
  # finding means anything, so the exit status is never asserted.
  #
  # An `&& return 1` as the test body's OWN final line would make the good
  # case (no match, exit 1) become the test's own failing exit status; the
  # `if` form keeps that exit status internal to the condition.
  if remit_parity_names_member "$output" "code-audit-region-claim"; then
    return 1
  fi
}

@test "the regenerated region's bullets equal the roster's globs for that member, in roster order" {
  local sb="$BATS_TEST_TMPDIR/sb"
  scaffold_scripts "$sb"
  cat > "$sb/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-region-default
    globs:
      - "src/**"
      - "lib/*.ts"
    default: true
  - name: code-audit-region-claim
    globs:
      - "docs/**"
      - "guides/*.md"
      - "examples/*.mdx"
YAML
  write_agent_stub "$sb" code-audit-region-default
  write_agent_stub "$sb" code-audit-region-claim

  run_writer "$sb"
  [ "$status" -eq 0 ]

  # The independent ground truth is the roster literal above, not anything
  # the writer itself produced.
  local region_globs
  region_globs="$(awk -v s="$REMIT_START" -v e="$REMIT_END" '
    $0 == s { infl = 1; next }
    $0 == e { infl = 0; next }
    infl && /^- `.*`$/ { line = $0; sub(/^- `/, "", line); sub(/`$/, "", line); print line }
  ' "$sb/.claude/agents/code-audit-region-claim.md")"
  local expected="docs/**
guides/*.md
examples/*.mdx"
  [ "$region_globs" = "$expected" ]
}

@test "the region differs between two trees whose rosters differ" {
  local sb_a="$BATS_TEST_TMPDIR/sb-a" sb_b="$BATS_TEST_TMPDIR/sb-b"
  scaffold_scripts "$sb_a"
  scaffold_scripts "$sb_b"

  cat > "$sb_a/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-region-only
    globs:
      - "alpha/**"
    default: true
YAML
  cat > "$sb_b/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-region-only
    globs:
      - "beta/**"
    default: true
YAML
  write_agent_stub "$sb_a" code-audit-region-only
  write_agent_stub "$sb_b" code-audit-region-only

  run_writer "$sb_a"
  [ "$status" -eq 0 ]
  run_writer "$sb_b"
  [ "$status" -eq 0 ]

  # Not a self-comparison: this fails if a bug hardcoded a fixed region body
  # regardless of the roster it was handed.
  local content_a content_b
  content_a="$(cat "$sb_a/.claude/agents/code-audit-region-only.md")"
  content_b="$(cat "$sb_b/.claude/agents/code-audit-region-only.md")"
  [ "$content_a" != "$content_b" ]
}

# ---------------------------------------------------------------------------
# Byte-identical convergence on a second run
# ---------------------------------------------------------------------------

@test "a second writer run is byte-identical to the first (idempotent)" {
  local sb="$BATS_TEST_TMPDIR/sb"
  scaffold_scripts "$sb"
  cat > "$sb/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-region-idem
    globs:
      - "app/**"
      - "test/**"
    default: true
YAML
  write_agent_stub "$sb" code-audit-region-idem

  run_writer "$sb"
  [ "$status" -eq 0 ]
  local first
  first="$(cat "$sb/.claude/agents/code-audit-region-idem.md")"

  run_writer "$sb"
  [ "$status" -eq 0 ]
  local second
  second="$(cat "$sb/.claude/agents/code-audit-region-idem.md")"

  # Content only, never inode or mtime: the writer's final `mv "$tmp" "$agent"`
  # is unconditional, so both runs always replace the file and an mtime
  # assertion would fail even on a correct implementation.
  [ "$first" = "$second" ]
}

# ---------------------------------------------------------------------------
# Ordering: regeneration runs after the roster merge, not before
# ---------------------------------------------------------------------------
#
# Every other case in this suite keeps the roster fixed across the writer
# invocation, so an implementation that regenerates BEFORE the field-aware
# roster merge lands its delta would pass all of them. This is the only case
# that can falsify that ordering.

@test "regeneration observes a roster that already carries a GAIA-authored added member" {
  local sb="$BATS_TEST_TMPDIR/sb"
  scaffold_scripts "$sb"
  # The adopter roster before this run's update: one existing member.
  cat > "$sb/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-region-existing
    globs:
      - "app/**"
    default: true
YAML
  write_agent_stub "$sb" code-audit-region-existing

  # Simulate what Step 7c's field-aware merge does to the roster BEFORE
  # Step 7d ever runs: a GAIA-authored added member always lands in
  # `applied[]`, appended to the roster with its own agent stub dropped
  # alongside it. Only after this does the writer run.
  cat >> "$sb/.gaia/audit-ci.yml" <<'YAML'
  - name: code-audit-region-added
    globs:
      - "added/**"
YAML
  write_agent_stub "$sb" code-audit-region-added

  run_writer "$sb"
  [ "$status" -eq 0 ]

  # An implementation that regenerated before the roster merge landed the
  # addition would have run against the roster's PRIOR state, producing a
  # region for the added member missing its globs (or no region at all).
  local added_globs
  added_globs="$(awk -v s="$REMIT_START" -v e="$REMIT_END" '
    $0 == s { infl = 1; next }
    $0 == e { infl = 0; next }
    infl && /^- `.*`$/ { line = $0; sub(/^- `/, "", line); sub(/`$/, "", line); print line }
  ' "$sb/.claude/agents/code-audit-region-added.md")"
  [ "$added_globs" = "added/**" ]
}
