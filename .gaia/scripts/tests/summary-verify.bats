#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/summary-verify.sh: the deterministic verify-gate
# every consolidation producer (the orchestrator's consolidation step and the
# pre-flight sweep's cold consolidation) calls before removing SPEC.md /
# AUDIT.md at merge. Exercises the pinned SUMMARY.md shape against every
# malformed/absent/empty variant, the optional Divergence section, and the
# wiki_promote_default vocabulary.
#
# Fixtures are inline heredocs written to $BATS_TEST_TMPDIR; this suite never
# touches real .gaia/local.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../summary-verify.sh"
  [ -x "$SCRIPT" ] || skip "summary-verify.sh not executable"
  FIXTURE="$BATS_TEST_TMPDIR/SUMMARY.md"
}

# --- 1. well-formed passes ---------------------------------------------------

@test "well-formed SUMMARY.md (frontmatter + H1 + body) exits 0" {
  cat > "$FIXTURE" <<'EOF'
---
wiki_promote_default: ask
wiki_promote_targets: [decisions]
---
# Unify spec and plan knowledge lifecycles

The orchestrator writes PROGRESS.md during execution; SUMMARY.md is produced
once at merge by layered override-resolution.
EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
}

# --- 2. optional Divergence section still passes -----------------------------

@test "a SUMMARY.md with a Divergence section still exits 0" {
  cat > "$FIXTURE" <<'EOF'
---
wiki_promote_default: yes
wiki_promote_targets: [modules]
---
# Retention symmetry for spec-less plans

Spec-less plans are reduced to SUMMARY.md and cost.json instead of deleted.

## Divergence
The age-backstop reap was deferred to a follow-up task.
EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
}

# --- 3. absent file -----------------------------------------------------------

@test "absent file exits 1" {
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 1 ]
}

# --- 4. empty file -------------------------------------------------------------

@test "empty file exits 1" {
  : > "$FIXTURE"
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 1 ]
}

# --- 5. missing frontmatter block ----------------------------------------------

@test "missing frontmatter block exits 1" {
  cat > "$FIXTURE" <<'EOF'
# A title with no frontmatter at all

Some body text.
EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF -- "frontmatter" <<<"$output"
}

# --- 6. frontmatter missing wiki_promote_default -------------------------------

@test "frontmatter missing wiki_promote_default exits 1" {
  cat > "$FIXTURE" <<'EOF'
---
wiki_promote_targets: [decisions]
---
# A title

Some body text.
EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF -- "wiki_promote_default" <<<"$output"
}

# --- 7. frontmatter missing wiki_promote_targets -------------------------------

@test "frontmatter missing wiki_promote_targets exits 1" {
  cat > "$FIXTURE" <<'EOF'
---
wiki_promote_default: ask
---
# A title

Some body text.
EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF -- "wiki_promote_targets" <<<"$output"
}

# --- 8. missing H1 ---------------------------------------------------------------

@test "missing H1 exits 1" {
  cat > "$FIXTURE" <<'EOF'
---
wiki_promote_default: ask
wiki_promote_targets: [decisions]
---
Some body text with no H1 title at all.
EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF -- "H1" <<<"$output"
}

# --- 9. H1 present but empty body -------------------------------------------------

@test "H1 present but empty body exits 1" {
  cat > "$FIXTURE" <<'EOF'
---
wiki_promote_default: ask
wiki_promote_targets: [decisions]
---
# A title with nothing after it

EOF
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF -- "empty body" <<<"$output"
}

# --- 10. wiki_promote_default vocabulary ------------------------------------------

_write_with_default() {
  printf -- '---\nwiki_promote_default: %s\nwiki_promote_targets: [decisions]\n---\n# A title\n\nSome body text.\n' "$1" > "$FIXTURE"
}

@test "wiki_promote_default accepts yes, ask, no, quoted values and the true/false aliases" {
  for value in yes ask no '"yes"' "'ask'" true false "'false'" '"no"'; do
    _write_with_default "$value"
    run bash "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 0 ] || { echo "rejected: $value: $output"; return 1; }
  done
}

@test "wiki_promote_default outside the vocabulary exits 1 naming the value" {
  for value in maybe True 1 YES '"yes' "yes'"; do
    _write_with_default "$value"
    run bash "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 1 ] || { echo "accepted: $value"; return 1; }
    grep -qF -- "wiki_promote_default must be yes, ask or no (got '$value')" <<<"$output" || { echo "message: $output"; return 1; }
  done
}

@test "an empty wiki_promote_default value exits 1" {
  _write_with_default ""
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 1 ]
  grep -qF -- "wiki_promote_default must be yes, ask or no (got '')" <<<"$output"
}

@test "only the first wiki_promote_default line is judged" {
  printf -- '---\nwiki_promote_default: ask\nwiki_promote_default: maybe\nwiki_promote_targets: []\n---\n# A title\n\nBody.\n' > "$FIXTURE"
  run bash "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
}
