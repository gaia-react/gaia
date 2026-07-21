#!/usr/bin/env bats
# Tests for .gaia/scripts/write-audit-remits.sh, the roster-derived remit
# region generator.
#
# Every case runs against fixtures scaffolded into $BATS_TEST_TMPDIR. No test
# mutates the repo's real roster or its real agent definitions.
#
# Assertion style (.claude/rules/bats-assertions.md): non-final checks use
# POSIX `[ ]` or `grep -qF`, never a bare `[[ ]]`, which macOS's bash 3.2 does
# not fail on. Absence is asserted as `<positive-condition> && return 1`,
# never as a non-final `!`-negation, which `set -e` exempts on every bash
# version.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WRITER="$REPO_ROOT/.gaia/scripts/write-audit-remits.sh"
  CHECK="$REPO_ROOT/.gaia/scripts/verify-audit-roster.sh"
  # A hard failure, not a skip: a `skip` here would silently retire every
  # test in this suite to skipped-and-green if the committed writer ever
  # went missing, which is the opposite of what a missing file should do.
  if [ ! -f "$WRITER" ]; then
    printf 'write-audit-remits.sh missing: %s\n' "$WRITER" >&2
    return 1
  fi
}

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

# Scaffolds a fixture root: the roster arrives on stdin, the machinery lists
# are derived from the member names it declares (so the check's unrelated
# invariants stay clean), and one stub agent file per member is written in the
# shape `shape` selects: "heading" (default, the primary C6 anchor),
# "frontmatter" (no heading, the fallback C6 anchor), or "noanchor" (neither).
fixture_root() {
  local r="$1" shape="${2:-heading}" names n
  rm -rf "$r"
  mkdir -p "$r/.gaia/scripts" "$r/.claude/agents" "$r/.claude/hooks/lib"
  cat > "$r/.gaia/audit-ci.yml"
  names="$(awk '/^[[:space:]]*-[[:space:]]+name[[:space:]]*:/ {
    sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, ""); print }' "$r/.gaia/audit-ci.yml")"
  {
    printf 'AUDIT_MACHINERY_PATHS="$(cat <<%s\n' "'EOF'"
    for n in $names; do printf '.claude/agents/%s.md\n' "$n"; done
    printf 'EOF\n)"\n'
  } > "$r/.claude/hooks/lib/audit-machinery.sh"
  {
    printf 'GATE_MACHINERY_FILES="$(cat <<%s\n' "'EOF'"
    for n in $names; do printf '.claude/agents/%s.md\n' "$n"; done
    printf 'EOF\n)"\n'
  } > "$r/.gaia/scripts/audit-machinery-complete.sh"
  for n in $names; do
    case "$shape" in
      frontmatter)
        cat > "$r/.claude/agents/$n.md" <<MD
---
name: $n
---

# $n
MD
        ;;
      noanchor)
        cat > "$r/.claude/agents/$n.md" <<MD
just some text
no frontmatter no heading
MD
        ;;
      *)
        cat > "$r/.claude/agents/$n.md" <<MD
---
name: $n
---

# $n

## Remit and self-skip

You own things.
MD
        ;;
    esac
  done
}

run_writer() {
  run bash "$WRITER" --root "$1" --config "$1/.gaia/audit-ci.yml"
}

# <root> <member> -- that member's roster globs, in roster order, read back
# through the check's own --emit-roster mode. Never a hard-coded list.
member_globs() {
  bash "$CHECK" --emit-roster --root "$1" --config "$1/.gaia/audit-ci.yml" |
    awk -F'\t' -v m="$2" '$1 == "RAW" && $2 == m { print $3 }'
}

# <file> -- the glob bullets inside that file's remit region, in file order.
region_globs() {
  awk '
    /^<!-- gaia:audit-remit:start -->$/ { infl = 1; next }
    /^<!-- gaia:audit-remit:end -->$/ { infl = 0; next }
    infl && /^- `.*`$/ { line = $0; sub(/^- `/, "", line); sub(/`$/, "", line); print line }
  ' "$1"
}

# <file> -- the region's non-bullet, non-empty, non-marker lines (the
# sentence).
region_sentence_lines() {
  awk '
    /^<!-- gaia:audit-remit:start -->$/ { infl = 1; next }
    /^<!-- gaia:audit-remit:end -->$/ { infl = 0; next }
    infl && $0 != "" && $0 !~ /^- `.*`$/ { print }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Usage surface
# ---------------------------------------------------------------------------

@test "usage: --help exits 0 and prints the usage" {
  run bash "$WRITER" --help
  [ "$status" -eq 0 ]
  assert_contains "Usage: write-audit-remits.sh"
}

# ---------------------------------------------------------------------------
# UAT-006: the writer repairs a drifted region.
# ---------------------------------------------------------------------------

@test "UAT-006: repair restores a deleted glob, matching the fixture roster in order" {
  local r="$BATS_TEST_TMPDIR/uat006-order"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
      - "a/b/*.ts"
      - "a/b/c.ts"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  sed '/^- `a\/b\/\*\.ts`$/d' "$r/.claude/agents/code-audit-a.md" > "$r/tmp-corrupt"
  mv "$r/tmp-corrupt" "$r/.claude/agents/code-audit-a.md"

  run_writer "$r"
  [ "$status" -eq 0 ]

  local expected actual
  expected="$(member_globs "$r" "code-audit-a")"
  actual="$(region_globs "$r/.claude/agents/code-audit-a.md")"
  [ "$actual" = "$expected" ]
}

@test "UAT-006: repair announces the added glob with a + prefix" {
  local r="$BATS_TEST_TMPDIR/uat006-plus"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
      - "a/b/*.ts"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  sed '/^- `a\/b\/\*\.ts`$/d' "$r/.claude/agents/code-audit-a.md" > "$r/tmp-corrupt"
  mv "$r/tmp-corrupt" "$r/.claude/agents/code-audit-a.md"

  run_writer "$r"
  [ "$status" -eq 0 ]
  assert_contains "code-audit-a: +a/b/*.ts"
}

@test "UAT-006: repair is confined to the marker span (byte-identical outside it)" {
  local r="$BATS_TEST_TMPDIR/uat006-span"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
      - "a/b/*.ts"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  local before
  before="$(cat "$r/.claude/agents/code-audit-a.md")"

  sed '/^- `a\/b\/\*\.ts`$/d' "$r/.claude/agents/code-audit-a.md" > "$r/tmp-corrupt"
  mv "$r/tmp-corrupt" "$r/.claude/agents/code-audit-a.md"

  run_writer "$r"
  [ "$status" -eq 0 ]

  local after
  after="$(cat "$r/.claude/agents/code-audit-a.md")"
  [ "$before" = "$after" ]
}

@test "UAT-006: repair announces a roster-ungranted glob with a - prefix, after the + list" {
  local r="$BATS_TEST_TMPDIR/uat006-minus"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
      - "a/b/*.ts"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  # Delete a granted bullet AND insert one the roster does not grant, so both
  # halves of the delta appear in the same repair run.
  sed '/^- `a\/b\/\*\.ts`$/d' "$r/.claude/agents/code-audit-a.md" > "$r/tmp1"
  sed '/^- `a\/\*\*`$/a\
- `docs/**`
' "$r/tmp1" > "$r/tmp-corrupt"
  mv "$r/tmp-corrupt" "$r/.claude/agents/code-audit-a.md"
  rm -f "$r/tmp1"

  run_writer "$r"
  [ "$status" -eq 0 ]
  assert_contains "+a/b/*.ts"
  assert_contains "-docs/**"

  local line
  line="$(grep -F 'code-audit-a:' <<<"$output")"
  case "$line" in
    *"+a/b/*.ts"*"-docs/**") : ;;
    *) echo "expected the + list before the - list: $line" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# UAT-007: insertion into a definition with no markers.
# ---------------------------------------------------------------------------

@test "UAT-007: insertion at the primary anchor (heading-bearing stub)" {
  local r="$BATS_TEST_TMPDIR/uat007-heading"
  fixture_root "$r" heading <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  local f="$r/.claude/agents/code-audit-a.md"
  [ "$(grep -cxF -- '<!-- gaia:audit-remit:start -->' "$f")" -eq 1 ]
  [ "$(grep -cxF -- '<!-- gaia:audit-remit:end -->' "$f")" -eq 1 ]

  # The pre-existing content is present verbatim and in order: the heading,
  # then the region, then the stub's own trailing prose.
  local heading_line region_start_line prose_line
  heading_line="$(grep -n -- '^## Remit and self-skip$' "$f" | head -1 | cut -d: -f1)"
  region_start_line="$(grep -n -- '^<!-- gaia:audit-remit:start -->$' "$f" | head -1 | cut -d: -f1)"
  prose_line="$(grep -n -- '^You own things\.$' "$f" | head -1 | cut -d: -f1)"
  [ "$heading_line" -lt "$region_start_line" ]
  [ "$region_start_line" -lt "$prose_line" ]

  run bash "$CHECK" --root "$r" --config "$r/.gaia/audit-ci.yml"
  # The remit invariant does not exist yet at this phase, so this passes
  # vacuously today; it becomes the integration anchor once it lands.
  [ "$status" -eq 0 ]
}

@test "UAT-007: insertion at the fallback anchor (frontmatter-only stub)" {
  local r="$BATS_TEST_TMPDIR/uat007-frontmatter"
  fixture_root "$r" frontmatter <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  local f="$r/.claude/agents/code-audit-a.md"
  [ "$(grep -cxF -- '<!-- gaia:audit-remit:start -->' "$f")" -eq 1 ]
  [ "$(grep -cxF -- '<!-- gaia:audit-remit:end -->' "$f")" -eq 1 ]

  local frontmatter_end_line region_start_line prose_line
  frontmatter_end_line="$(grep -n -- '^---$' "$f" | sed -n '2p' | cut -d: -f1)"
  region_start_line="$(grep -n -- '^<!-- gaia:audit-remit:start -->$' "$f" | head -1 | cut -d: -f1)"
  prose_line="$(grep -n -- '^# code-audit-a$' "$f" | head -1 | cut -d: -f1)"
  [ "$frontmatter_end_line" -lt "$region_start_line" ]
  [ "$region_start_line" -lt "$prose_line" ]

  run bash "$CHECK" --root "$r" --config "$r/.gaia/audit-ci.yml"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# UAT-008: idempotence.
# ---------------------------------------------------------------------------

@test "UAT-008: two repair runs in succession converge to the same tree" {
  local r="$BATS_TEST_TMPDIR/uat008"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
      - "a/b/*.ts"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  sed '/^- `a\/b\/\*\.ts`$/d' "$r/.claude/agents/code-audit-a.md" > "$r/tmp-corrupt"
  mv "$r/tmp-corrupt" "$r/.claude/agents/code-audit-a.md"

  run_writer "$r"
  [ "$status" -eq 0 ]
  local after_first
  after_first="$(find "$r" -type f -exec shasum {} + | sort)"

  run_writer "$r"
  [ "$status" -eq 0 ]
  local after_second
  after_second="$(find "$r" -type f -exec shasum {} + | sort)"

  [ "$after_first" = "$after_second" ]
}

# ---------------------------------------------------------------------------
# UAT-016: the generated sentences.
# ---------------------------------------------------------------------------

@test "UAT-016: the claimant region carries the canonical claimant sentence" {
  local r="$BATS_TEST_TMPDIR/uat016-claimant"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]
  grep -qF 'Filter the changed-file list against the globs above' "$r/.claude/agents/code-audit-a.md"
}

@test "UAT-016: the default region carries the canonical default sentence" {
  local r="$BATS_TEST_TMPDIR/uat016-default"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]
  grep -qF 'second precedence tier' "$r/.claude/agents/code-audit-default.md"
}

@test "UAT-016: no path appears in either region's sentence lines" {
  local r="$BATS_TEST_TMPDIR/uat016-nopath"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  local sentence_lines
  sentence_lines="$(region_sentence_lines "$r/.claude/agents/code-audit-a.md")"
  grep -qE '`|/' <<<"$sentence_lines" && return 1

  sentence_lines="$(region_sentence_lines "$r/.claude/agents/code-audit-default.md")"
  grep -qE '`|/' <<<"$sentence_lines" && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Malformed markers are refused, not repaired.
# ---------------------------------------------------------------------------

@test "malformed markers: two start markers are refused, the file left byte-identical" {
  local r="$BATS_TEST_TMPDIR/malformed-dup-start"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  local f="$r/.claude/agents/code-audit-a.md"
  sed '/^<!-- gaia:audit-remit:start -->$/i\
<!-- gaia:audit-remit:start -->
' "$f" > "$r/tmp-corrupt"
  mv "$r/tmp-corrupt" "$f"

  local before
  before="$(cat "$f")"

  run_writer "$r"
  [ "$status" -eq 1 ]
  assert_contains "code-audit-a"

  local after
  after="$(cat "$f")"
  [ "$before" = "$after" ]
}

@test "malformed markers: a start marker with no end marker is refused, the file left byte-identical" {
  local r="$BATS_TEST_TMPDIR/malformed-no-end"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  local f="$r/.claude/agents/code-audit-a.md"
  sed '/^<!-- gaia:audit-remit:end -->$/d' "$f" > "$r/tmp-corrupt"
  mv "$r/tmp-corrupt" "$f"

  local before
  before="$(cat "$f")"

  run_writer "$r"
  [ "$status" -eq 1 ]
  assert_contains "code-audit-a"

  local after
  after="$(cat "$f")"
  [ "$before" = "$after" ]
}

@test "malformed markers: a reversed pair (end before start) is refused, the file left byte-identical, tail intact" {
  # The critical case: a single balanced pair (start=1, end=1) whose end
  # marker sits ABOVE its start marker. Counting alone reads this as
  # "replace"; only the line-order check catches it. A writer that missed
  # this would print through the start marker, emit the new body, and then
  # (because the state machine's end-marker rule never fires) drop every
  # remaining line to EOF -- including this fixture's distinctive tail line.
  local r="$BATS_TEST_TMPDIR/malformed-reversed"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]

  local f="$r/.claude/agents/code-audit-a.md"
  cat > "$f" <<'MD'
---
name: code-audit-a
---

# code-audit-a

## Remit and self-skip

You own things.

<!-- gaia:audit-remit:end -->
- `a/**`

Filter the changed-file list against the globs above.
<!-- gaia:audit-remit:start -->

## Some other important section

THIS TAIL MUST SURVIVE
MD

  local before
  before="$(cat "$f")"

  run_writer "$r"
  [ "$status" -eq 1 ]
  assert_contains "code-audit-a"

  local after
  after="$(cat "$f")"
  [ "$before" = "$after" ]
  grep -qxF -- "THIS TAIL MUST SURVIVE" "$f"
}

# ---------------------------------------------------------------------------
# Neither anchor present.
# ---------------------------------------------------------------------------

@test "neither anchor present: the writer is refused, naming the member and the file, byte-identical" {
  local r="$BATS_TEST_TMPDIR/no-anchor"
  fixture_root "$r" noanchor <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  local before
  before="$(cat "$r/.claude/agents/code-audit-a.md")"

  run_writer "$r"
  [ "$status" -eq 1 ]
  assert_contains "code-audit-a"

  local after
  after="$(cat "$r/.claude/agents/code-audit-a.md")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Robustness.
# ---------------------------------------------------------------------------

@test "robustness: an unusable TMPDIR is refused before any definition is touched" {
  # Without the guard this is destructive and silent: an empty $tmpdir makes
  # the region body file unwritable, awk's getline cannot tell unreadable
  # from empty, and every definition is rewritten to a region holding the
  # two markers and nothing between them, with exit 0. The writer must
  # refuse instead, leaving every file byte-identical.
  local r="$BATS_TEST_TMPDIR/bad-tmpdir"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  local before_default before_a
  before_default="$(cat "$r/.claude/agents/code-audit-default.md")"
  before_a="$(cat "$r/.claude/agents/code-audit-a.md")"

  run env TMPDIR="$r/no-such-tmpdir" bash "$WRITER" --root "$r" --config "$r/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ]

  # The definitions are untouched, and in particular no emptied region landed.
  local after_default after_a
  after_default="$(cat "$r/.claude/agents/code-audit-default.md")"
  after_a="$(cat "$r/.claude/agents/code-audit-a.md")"
  [ "$before_default" = "$after_default" ]
  [ "$before_a" = "$after_a" ]
}

@test "robustness: a body write that fails after mktemp succeeds is refused, definitions byte-identical" {
  # The sibling case above drives its failure with an unusable TMPDIR, which
  # trips the mktemp guard and returns before the member loop ever runs. This
  # one covers the state that guard cannot reach: mktemp -d succeeds and the
  # region-body write inside the directory it created then fails, the
  # ENOSPC/EIO class the region-body emptiness guard exists for. Without that
  # guard the run installs a region holding the two markers and nothing
  # between them over every definition, and still exits 0.
  [ "$(id -u)" -eq 0 ] && skip "running as root: mode 500 does not deny the write"

  local r="$BATS_TEST_TMPDIR/unwritable-tmpdir"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML

  # A PATH shim is the only handle on that directory: the writer names it with
  # a random mktemp suffix, so no fixture can chmod it by name beforehand. The
  # shim delegates to the real mktemp, then strips write permission from what
  # it just created, leaving it readable and traversable so the body write is
  # the only thing that fails.
  local shim real_mktemp
  shim="$BATS_TEST_TMPDIR/mktemp-shim"
  mkdir -p "$shim"
  real_mktemp="$(command -v mktemp)"
  cat > "$shim/mktemp" <<SH
#!/usr/bin/env bash
d="\$("$real_mktemp" "\$@")" || exit 1
chmod 500 "\$d" || exit 1
printf '%s\n' "\$d"
SH
  chmod +x "$shim/mktemp"

  local before_default before_a
  before_default="$(cat "$r/.claude/agents/code-audit-default.md")"
  before_a="$(cat "$r/.claude/agents/code-audit-a.md")"

  run env PATH="$shim:$PATH" bash "$WRITER" --root "$r" --config "$r/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ]

  # The emptiness guard is what refused, for every member, and the earlier
  # mktemp guard is not what fired: that distinction is the whole point of
  # this case, since the sibling above already covers the mktemp path.
  assert_contains "code-audit-default: region body generation failed"
  assert_contains "code-audit-a: region body generation failed"
  assert_contains "could not create a temporary directory" && return 1

  # No emptied region landed: every definition is byte-identical.
  local after_default after_a
  after_default="$(cat "$r/.claude/agents/code-audit-default.md")"
  after_a="$(cat "$r/.claude/agents/code-audit-a.md")"
  [ "$before_default" = "$after_default" ]
  [ "$before_a" = "$after_a" ]
}

@test "robustness: a roster with no auditors block exits 0 and writes nothing" {
  local r="$BATS_TEST_TMPDIR/no-auditors"
  mkdir -p "$r/.gaia/scripts" "$r/.claude/agents" "$r/.claude/hooks/lib"
  cat > "$r/.gaia/audit-ci.yml" <<'YAML'
default_mode: local
YAML
  run_writer "$r"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "robustness: an agent file deleted after scaffolding is skipped, others still processed" {
  local r="$BATS_TEST_TMPDIR/deleted-agent"
  fixture_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  rm "$r/.claude/agents/code-audit-a.md"

  run_writer "$r"
  [ "$status" -eq 0 ]
  assert_contains "code-audit-default: region inserted"
  grep -qxF -- '<!-- gaia:audit-remit:start -->' "$r/.claude/agents/code-audit-default.md"
}

# ---------------------------------------------------------------------------
# The writer carries no second scrape (UAT-011's structural half).
# ---------------------------------------------------------------------------

@test "UAT-011: the writer carries no second scrape, and obtains globs from the check" {
  grep -qF 'in_globs' "$WRITER" && return 1
  grep -qF 'in_auditors' "$WRITER" && return 1
  grep -qF -- '--emit-roster' "$WRITER"
}
