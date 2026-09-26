#!/usr/bin/env bats
# SC2016 is intentional file-wide, matching the script under test: the fixture
# writers use single-quoted printf format strings where a $ is literal output
# text (the heredoc line they emit into a fixture), not a shell expansion.
# shellcheck disable=SC2016
# SC2317 and SC2329 likewise, and both trace to one cause that is not bats'
# `@test` dispatch: a `@test` body parses as a top-level brace group rather than
# a function, so each bare `return 0` terminating a test below reads as a
# script-level return. Every `@test` after one then reads as unreachable
# (SC2317), and a helper defined past one reads as never invoked because its
# call sites do (SC2329). Every test runs. shell-lint gates `.bats` at
# severity=warning, above both codes, so this only quiets an ad-hoc run. The
# spelling that avoids both outright is the explicit `true`
# .claude/rules/bats-assertions.md prescribes, and
# .gaia/tests/shell-lint.sh's header carries the full account of the SC2317
# half.
# shellcheck disable=SC2317,SC2329
# Tests for .gaia/scripts/verify-audit-roster.sh, the roster's deterministic
# check.
#
# Every invariant is exercised against FIXTURES injected through --config (the
# roster) and --root (everything the check reads about that roster: the agent
# files and the machinery list). No test mutates the repo's real roster or its
# real machinery list; UAT-024 is the one test that reads them, and it only
# reads.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.gaia/scripts/verify-audit-roster.sh"
  WRITER="$REPO_ROOT/.gaia/scripts/write-audit-remits.sh"
  REMIT_START='<!-- gaia:audit-remit:start -->'
  REMIT_END='<!-- gaia:audit-remit:end -->'
  MAINTAINER_START='# gaia:maintainer-only:start'
  MAINTAINER_END='# gaia:maintainer-only:end'
  # A hard failure, not a skip: a `skip` here would silently retire every
  # test in this suite to skipped-and-green if either committed script ever
  # went missing, which is the opposite of what a missing file should do.
  if [ ! -f "$SCRIPT" ]; then
    printf 'verify-audit-roster.sh missing: %s\n' "$SCRIPT" >&2
    return 1
  fi
  if [ ! -f "$WRITER" ]; then
    printf 'write-audit-remits.sh missing: %s\n' "$WRITER" >&2
    return 1
  fi
}

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

# Strips maintainer-only blocks from the file named by $1, writing the result to
# stdout. One copy, used by every lockstep test that needs a stripped script.
#
# This models `stripMarkerBlocks` in `.gaia/cli/src/release/marker-strip.ts`,
# the parser the release scrub actually runs, and models it by substring
# (`index`) because that is what the shipped parser does (`line.includes`).
# Matching only at column 0 would be a narrower second implementation, free to
# reject a block the release strips cleanly; the branches below cover the same
# cases the shipped state machine does, including a start and end on one line
# and an end with no open block (which the shipped parser keeps).
#
# This awk is a hand-kept model, not held to the real parser by a test. Three
# sibling suites carry the same block for the same reason
# (`audit-write-clearance.bats`, `.gaia/tests/hooks/audit-scope-lib.bats`,
# `.gaia/tests/statusline/statusline-worktree.bats`), so a change here belongs
# in all of them, and in the real parser too if the transform it models changed.
strip_maintainer_only() {
  awk -v s="$MAINTAINER_START" -v e="$MAINTAINER_END" '
    {
      has_s = index($0, s) > 0
      has_e = index($0, e) > 0
      if (!skip && has_s) { if (!has_e) skip = 1; next }
      if (skip) { if (has_e) skip = 0; next }
      print
    }
  ' "$1"
}

# Scaffolds a fixture root: the roster arrives on stdin, and the agent files and
# the machinery list are derived from the member names it declares, so a
# fixture is clean unless a test deliberately breaks one of them.
#
# Every stub carries a `## Remit and self-skip` heading, and the remit regions
# come from the WRITER rather than from a generator here. A hand-rolled region
# in this helper would be a second implementation of the region format, free to
# drift from the writer's; invoking the writer cannot drift, and it gives every
# fixture in this suite free integration coverage of the pair.
scaffold_root() {
  local r="$1" names n
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
  for n in $names; do
    cat > "$r/.claude/agents/$n.md" <<MD
---
name: $n
---

# $n

## Remit and self-skip

You own things.
MD
  done
  bash "$WRITER" --root "$r" --config "$r/.gaia/audit-ci.yml" >/dev/null
}

run_root() {
  run bash "$SCRIPT" --root "$1" --config "$1/.gaia/audit-ci.yml"
}

# --- Region post-processing, for the negative remit fixtures -----------------
#
# Each operates on one scaffolded agent file, breaking exactly one property the
# remit invariant asserts. The fixture stubs carry no markdown bullets outside
# the region, so a line-oriented edit reaches only the region.

strip_region() {
  local f="$1"
  awk -v s="$REMIT_START" -v e="$REMIT_END" '
    $0 == s { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

duplicate_region() {
  local f="$1" block
  block="$(awk -v s="$REMIT_START" -v e="$REMIT_END" '
    $0 == s { infl = 1 }
    infl { print }
    $0 == e { infl = 0 }
  ' "$f")"
  printf '\n%s\n' "$block" >> "$f"
}

unbalance_region() {
  local f="$1"
  grep -vxF -- "$REMIT_END" "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

# Moves the end marker to appear BEFORE the start marker: still exactly one
# of each (nstart=1, nend=1), so a counts-only classifier reads this as a
# normal balanced pair, but the pair is reversed and the region cannot be
# read in file order.
reverse_region() {
  local f="$1"
  awk -v s="$REMIT_START" -v e="$REMIT_END" '
    $0 == e { next }
    $0 == s { print e; print; next }
    { print }
  ' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

drop_region_glob() {
  local f="$1" g="$2"
  grep -vxF -- "- \`$g\`" "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

add_region_glob() {
  local f="$1" g="$2"
  awk -v s="$REMIT_START" -v line="- \`$g\`" '
    { print }
    $0 == s { print line }
  ' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

swap_region_globs() {
  local f="$1"
  awk -v s="$REMIT_START" -v e="$REMIT_END" '
    $0 == s { infl = 1; print; next }
    $0 == e { infl = 0; print; next }
    infl && /^- `.*`$/ {
      n++
      if (n == 1) { first = $0; next }
      if (n == 2) { print; print first; next }
    }
    { print }
  ' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

# One default plus one claimant carrying two globs: enough to permute.
remit_root() {
  scaffold_root "$1" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/one/**"
      - "a/two/*.ts"
YAML
}

# Usage surface

@test "usage: --help exits 0 and prints the usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_contains "Usage: verify-audit-roster.sh"
}

@test "usage: an unknown flag exits 2" {
  run bash "$SCRIPT" --not-a-real-flag
  [ "$status" -eq 2 ]
}

@test "usage: a value-taking flag with no value exits 2" {
  run bash "$SCRIPT" --config
  [ "$status" -eq 2 ]
}

@test "usage: a roster that does not exist exits 2 and names it" {
  run bash "$SCRIPT" --root "$BATS_TEST_TMPDIR" --config "$BATS_TEST_TMPDIR/nope.yml"
  [ "$status" -eq 2 ]
}

# UAT-024: the roster this SPEC ships passes. If this fails, either the check
# or the roster is wrong; do not relax the check to fit the roster.

@test "UAT-024: the shipped roster passes the check" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "roster clean"
}

# Machinery registration and the member-name convention are asserted against
# the REAL committed roster here rather than through a --root fixture: both
# hold over .gaia/audit-ci.yml as it is checked in, whether or not a fixture
# roster is under test elsewhere in this suite.

@test "every roster member's agent file is registered in AUDIT_MACHINERY_PATHS" {
  local members name agent_rel
  members="$(bash "$SCRIPT" --emit-roster | awk -F'\t' '$1 == "MEMBER" { print $2 }' | sort -u)"
  [ -n "$members" ]
  while IFS= read -r name; do
    agent_rel=".claude/agents/${name}.md"
    grep -qxF -- "$agent_rel" "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" || {
      printf '%s is not registered in AUDIT_MACHINERY_PATHS\n' "$agent_rel" >&2
      return 1
    }
  done <<<"$members"
}

@test "every roster member's name carries the code-audit- prefix" {
  local members name
  members="$(bash "$SCRIPT" --emit-roster | awk -F'\t' '$1 == "MEMBER" { print $2 }' | sort -u)"
  [ -n "$members" ]
  while IFS= read -r name; do
    case "$name" in
      code-audit-*) ;;
      *)
        printf '%s does not carry the code-audit- prefix\n' "$name" >&2
        return 1
        ;;
    esac
  done <<<"$members"
}

@test "an unreadable machinery list fails rather than passing every member" {
  local r="$BATS_TEST_TMPDIR/no-list"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
YAML
  rm "$r/.claude/hooks/lib/audit-machinery.sh"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "unreadable-machinery-list"
  assert_contains "AUDIT_MACHINERY_PATHS"
}

# SPEC-056 UAT-001/002/003: remit region parity. The roster is the authority on
# what each member owns; its definition's region must say the same thing, in
# the same order. Every case asserts the specific slug by name rather than a
# process-wide exit code: the check emits one block per violation across
# independent invariants, so an unrelated one firing would mask the case.

@test "SPEC-056 UAT-001: a roster glob missing from the region fails, naming the glob" {
  local r="$BATS_TEST_TMPDIR/remit-missing"
  remit_root "$r"
  drop_region_glob "$r/.claude/agents/code-audit-a.md" 'a/two/*.ts'
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "remit-glob-missing"
  assert_contains "code-audit-a"
  assert_contains "a/two/*.ts"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
  # The omission direction only: an omitted glob is not also an over-claim.
  grep -qF "remit-glob-ungranted" <<<"$output" && return 1
  return 0
}

@test "SPEC-056 UAT-002: an un-granted glob in the region fails, naming the glob" {
  local r="$BATS_TEST_TMPDIR/remit-ungranted"
  remit_root "$r"
  # In the dialect on purpose, so the undecidable arm cannot fire and blur the
  # case.
  add_region_glob "$r/.claude/agents/code-audit-a.md" 'zzz-not-granted/**'
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "remit-glob-ungranted"
  assert_contains "code-audit-a"
  assert_contains "zzz-not-granted/**"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
  # The over-claim direction only, and distinguishable from UAT-001's block.
  grep -qF "remit-glob-missing" <<<"$output" && return 1
  return 0
}

@test "SPEC-056 UAT-003: a permuted region fails, naming both globs at the position" {
  # The case that proves parity is ordered, not a set comparison: the region
  # holds exactly the roster's globs and still fails.
  local r="$BATS_TEST_TMPDIR/remit-order"
  remit_root "$r"
  swap_region_globs "$r/.claude/agents/code-audit-a.md"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "remit-glob-order"
  assert_contains "code-audit-a"
  assert_contains "position: 1"
  assert_contains "roster:   a/one/**"
  assert_contains "region:   a/two/*.ts"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
  grep -qF "remit-glob-missing" <<<"$output" && return 1
  grep -qF "remit-glob-ungranted" <<<"$output" && return 1
  return 0
}

# SPEC-056 UAT-004: the region's SHAPE. A region that cannot be read leaves
# nothing to compare, so each of the three is its own finding and none of them
# is reported as parity-clean.

@test "SPEC-056 UAT-004: a definition with no region fails" {
  local r="$BATS_TEST_TMPDIR/remit-shape-missing"
  remit_root "$r"
  strip_region "$r/.claude/agents/code-audit-a.md"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "missing-remit-region"
  assert_contains "code-audit-a"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
}

@test "SPEC-056 UAT-004: a definition with two regions fails" {
  local r="$BATS_TEST_TMPDIR/remit-shape-dup"
  remit_root "$r"
  duplicate_region "$r/.claude/agents/code-audit-a.md"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "duplicate-remit-region"
  assert_contains "code-audit-a"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
}

@test "SPEC-056 UAT-004: a definition whose markers do not pair up fails" {
  local r="$BATS_TEST_TMPDIR/remit-shape-unbalanced"
  remit_root "$r"
  unbalance_region "$r/.claude/agents/code-audit-a.md"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "unbalanced-remit-region"
  assert_contains "code-audit-a"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
}

@test "reversed-remit-region: a definition whose end marker precedes its start marker fails" {
  # A single balanced pair (start=1, end=1) is not enough: counting alone
  # would read this as replaceable, which is exactly the shape that made the
  # writer destructive before it checked marker ORDER too.
  local r="$BATS_TEST_TMPDIR/remit-shape-reversed"
  remit_root "$r"
  reverse_region "$r/.claude/agents/code-audit-a.md"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "reversed-remit-region"
  assert_contains "code-audit-a"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
}

@test "SPEC-056 UAT-004: no marker-shape failure is ever reported as parity-clean" {
  local shape f r
  for shape in strip duplicate unbalance reverse; do
    r="$BATS_TEST_TMPDIR/remit-shape-clean-$shape"
    remit_root "$r"
    f="$r/.claude/agents/code-audit-a.md"
    case "$shape" in
      strip)     strip_region "$f" ;;
      duplicate) duplicate_region "$f" ;;
      unbalance) unbalance_region "$f" ;;
      reverse)   reverse_region "$f" ;;
    esac
    run_root "$r"
    [ "$status" -eq 1 ] || return 1
    grep -qF "roster clean" <<<"$output" && return 1
  done
  return 0
}

# SPEC-056 UAT-005: a region glob the bounded dialect cannot decide FAILS. The
# only way a rejected glob reaches a region is a roster that grants one, and
# the two fixtures below cover the default member and a lone claimant. A
# default plus one claimant is the whole adopter roster shape.

undecidable_remit_root() {
  # <fixture-dir> <default-glob> <claimant-glob>
  scaffold_root "$1" <<YAML
auditors:
  - name: code-audit-default
    globs:
      - "$2"
    default: true
  - name: code-audit-a
    globs:
      - "$3"
YAML
  run_root "$1"
}

@test "SPEC-056 UAT-005: an undecidable glob granted to the DEFAULT member fails" {
  local g
  for g in 'a/[a-z].ts' 'a/{b,c}/x.ts' 'a/?.ts' 'a/\x.ts' 'app/**.ts' 'a/***/b'; do
    undecidable_remit_root "$BATS_TEST_TMPDIR/remit-undec-default" "$g" 'a/one/**'
    [ "$status" -eq 1 ] || return 1
    grep -qF "undecidable-remit-glob" <<<"$output" || return 1
    grep -qF "$g" <<<"$output" || return 1
    grep -qF "reason:" <<<"$output" || return 1
  done
  return 0
}

@test "SPEC-056 UAT-005: an undecidable glob granted to a LONE claimant fails" {
  local g
  for g in 'a/[a-z].ts' 'a/{b,c}/x.ts' 'a/?.ts' 'a/\x.ts' 'app/**.ts' 'a/***/b'; do
    undecidable_remit_root "$BATS_TEST_TMPDIR/remit-undec-claimant" 'zzz-default-only/**' "$g"
    [ "$status" -eq 1 ] || return 1
    grep -qF "undecidable-remit-glob" <<<"$output" || return 1
    grep -qF "$g" <<<"$output" || return 1
    grep -qF "reason:" <<<"$output" || return 1
  done
  return 0
}

# SPEC-056 UAT-009: the committed tree. Every shipped definition's region is
# its roster entry, verbatim and in order. Read from the roster through
# --emit-roster, never from a list or a count written down here.

@test "SPEC-056 UAT-009: every committed definition's region equals its roster globs, in order" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "roster clean"

  local records members m roster_globs region_globs
  records="$(bash "$SCRIPT" --emit-roster)"
  members="$(printf '%s\n' "$records" | awk -F'\t' '$1 == "MEMBER" { print $2 }')"
  [ -n "$members" ]
  for m in $members; do
    roster_globs="$(printf '%s\n' "$records" |
      awk -F'\t' -v m="$m" '$1 == "RAW" && $2 == m { printf "%s|", $3 }')"
    region_globs="$(awk -v s="$REMIT_START" -v e="$REMIT_END" '
      $0 == s { infl = 1; next }
      $0 == e { infl = 0; next }
      infl && match($0, /^- `.*`$/) { printf "%s|", substr($0, 4, length($0) - 4) }
    ' "$REPO_ROOT/.claude/agents/$m.md")"
    [ -n "$roster_globs" ] || return 1
    [ "$roster_globs" = "$region_globs" ] || return 1
  done
  return 0
}

# The raw-glob scrape is held in lockstep with the classifier

# Reading the raw globs with a second reader is a deliberate exception to the
# no-second-parser rule, and the per-member glob-count comparison is what makes
# that exception safe. These two tests are its negative control: a guard that
# silently never fired would leave the exception unprotected.
drifted_reader_sandbox() {
  local sb="$1"
  mkdir -p "$sb/.gaia/scripts" "$sb/.claude/hooks/lib"
  # A copy of the check whose scrape drops one glob the classifier still
  # compiles: exactly the shape of a future edit to one reader and not the
  # other.
  sed 's|if (g != "") print "RAW", member, g|if (g != "" \&\& g != "a/**") print "RAW", member, g|' \
    "$SCRIPT" > "$sb/.gaia/scripts/verify-audit-roster.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$sb/.claude/hooks/lib/audit-scope.sh"
  # The writer resolves the check beside itself, so a copy here observes the
  # perturbation rather than the repo's real scrape. That is what makes the
  # writer's half of "one scrape, shared" testable at all.
  cp "$WRITER" "$sb/.gaia/scripts/write-audit-remits.sh"
  grep -qF 'g != "a/**"' "$sb/.gaia/scripts/verify-audit-roster.sh"
}

@test "reader drift: a scrape that disagrees with the classifier fails, naming the member" {
  local sb="$BATS_TEST_TMPDIR/drift-sandbox"
  drifted_reader_sandbox "$sb"
  local r="$BATS_TEST_TMPDIR/drift-fixture"
  scaffold_root "$r" <<'YAML'
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
  run bash "$sb/.gaia/scripts/verify-audit-roster.sh" --root "$r" --config "$r/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ]
  assert_contains "roster-reader-drift"
  assert_contains "code-audit-a"
}

# SPEC-056 UAT-011: the writer reads the roster through THIS check's scrape,
# so there is one scrape between the two scripts, not two. Perturbing it must
# change what both observe.

drift_writer_fixture() {
  scaffold_root "$1" <<'YAML'
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
}

@test "SPEC-056 UAT-011: perturbing the scrape changes what the writer generates" {
  local sb="$BATS_TEST_TMPDIR/drift-sandbox-writer"
  drifted_reader_sandbox "$sb"
  local r="$BATS_TEST_TMPDIR/drift-writer-fixture"
  drift_writer_fixture "$r"
  local agent="$r/.claude/agents/code-audit-a.md"
  # scaffold_root ran the REAL writer against the real check, so both globs are
  # in the region.
  grep -qF -- "- \`a/**\`" "$agent"
  # The sandbox writer resolves the perturbed check beside it, whose scrape
  # drops a/**, so the region it regenerates drops it too.
  bash "$sb/.gaia/scripts/write-audit-remits.sh" --root "$r" --config "$r/.gaia/audit-ci.yml" >/dev/null
  grep -qF -- "- \`a/**\`" "$agent" && return 1
  grep -qF -- "- \`a/b/*.ts\`" "$agent"
  # And the real writer puts it back, which is what makes the difference
  # attributable to the perturbation rather than to the writer.
  bash "$WRITER" --root "$r" --config "$r/.gaia/audit-ci.yml" >/dev/null
  grep -qF -- "- \`a/**\`" "$agent"
}

@test "SPEC-056 UAT-011: the perturbed check still fires roster-reader-drift" {
  # The other half of the same perturbation: the check's own observable output
  # changes too, so the shared scrape is load-bearing on both sides.
  local sb="$BATS_TEST_TMPDIR/drift-sandbox-both"
  drifted_reader_sandbox "$sb"
  local r="$BATS_TEST_TMPDIR/drift-both-fixture"
  drift_writer_fixture "$r"
  run bash "$sb/.gaia/scripts/verify-audit-roster.sh" --root "$r" --config "$r/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ]
  assert_contains "roster-reader-drift"
  assert_contains "code-audit-a"
}

@test "SPEC-056 UAT-011: the writer carries no second roster scrape" {
  # The structural half. Not `grep -qE 'globs[[:space:]]*:'`: the scrape's own
  # line is `if (raw ~ /^[[:space:]]+globs[[:space:]]*:/)`, where the character
  # after `globs` is a literal `[`, so that ERE would miss the scrape and match
  # only finding-block printf lines. A verbatim copy would sail past it. These
  # two state names are the scrape's own, and the last line is the positive
  # control that they still name something real.
  grep -qF 'in_globs' "$WRITER" && return 1
  grep -qF 'in_auditors' "$WRITER" && return 1
  grep -qF 'in_globs' "$SCRIPT"
}

# The maintainer-only lockstep block

# The lockstep tests below strip with `strip_maintainer_only`, this suite's model
# of the shipped scrub (`.gaia/cli/src/release/marker-strip.ts`). This one pins
# the model to the shipped semantics rather than to a convenient subset of them:
# the real parser recognizes a marker by substring, so it strips an indented
# pair, and indented pairs are legitimate and already in the tree wherever a
# block sits inside an `if` or an `else`. A model that only matched at column 0
# would leave the maintainer-only text in the "stripped" copy, failing every
# test below it on a file the release scrubs correctly.
@test "lockstep: the marker model strips an indented pair, as the shipped stripper does" {
  local f="$BATS_TEST_TMPDIR/indented-pair.sh"
  # Built from the same constants the model matches on, so the fixture cannot
  # drift into being a third spelling of the marker.
  {
    printf 'before=1\n'
    printf '  %s\n' "$MAINTAINER_START"
    printf '  maintainer_only=1\n'
    printf '  %s\n' "$MAINTAINER_END"
    printf 'after=1\n'
  } > "$f"
  run strip_maintainer_only "$f"
  [ "$status" -eq 0 ]
  assert_contains "before=1"
  assert_contains "after=1"
  grep -qF "maintainer_only=1" <<<"$output" && return 1
  grep -qF "gaia:maintainer-only" <<<"$output" && return 1
  true
}

@test "lockstep: the maintainer-only markers balance" {
  local starts ends
  starts="$(grep -cF -- "$MAINTAINER_START" "$SCRIPT")"
  ends="$(grep -cF -- "$MAINTAINER_END" "$SCRIPT")"
  [ "$starts" -ge 1 ]
  [ "$starts" -eq "$ends" ]
}

@test "lockstep: the script is valid bash with the maintainer-only block stripped" {
  local stripped="$BATS_TEST_TMPDIR/stripped.sh"
  strip_maintainer_only "$SCRIPT" > "$stripped"
  grep -qF "gaia:maintainer-only" "$stripped" && return 1
  bash -n "$stripped"
}

@test "lockstep: the stripped script still runs and still decides a roster" {
  # What an adopter runs. Resolved in a sandbox mirroring the repo layout, so
  # the stripped copy's own script-relative library resolution is exercised too.
  local sb="$BATS_TEST_TMPDIR/stripped-sandbox"
  mkdir -p "$sb/.gaia/scripts" "$sb/.claude/hooks/lib"
  strip_maintainer_only "$SCRIPT" > "$sb/.gaia/scripts/verify-audit-roster.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$sb/.claude/hooks/lib/audit-scope.sh"

  local r="$BATS_TEST_TMPDIR/stripped-fixture"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
  - name: code-audit-b
    globs:
      - "a/b/*.ts"
YAML
  run bash "$sb/.gaia/scripts/verify-audit-roster.sh" --root "$r" --config "$r/.gaia/audit-ci.yml"
  [ "$status" -eq 0 ]
  assert_contains "roster clean"
}

# Read-only

@test "the check never writes: the fixture root is byte-identical after a run" {
  local r="$BATS_TEST_TMPDIR/readonly"
  remit_root "$r"
  drop_region_glob "$r/.claude/agents/code-audit-a.md" 'a/two/*.ts'
  local before after
  before="$(find "$r" -type f -exec shasum {} + | sort)"
  run_root "$r"
  [ "$status" -eq 1 ]
  after="$(find "$r" -type f -exec shasum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "SPEC-056 UAT-008: the check never writes on the passing path either" {
  # The twin of the failing-path case above. A check that repaired a drifted
  # region rather than reporting it would be indistinguishable from a clean run
  # unless the clean run is pinned too. Fixture byte-identity, never git status:
  # $BATS_TEST_TMPDIR is not a git repo.
  local r="$BATS_TEST_TMPDIR/readonly-clean"
  remit_root "$r"
  local before after
  before="$(find "$r" -type f -exec shasum {} + | sort)"
  run_root "$r"
  [ "$status" -eq 0 ]
  after="$(find "$r" -type f -exec shasum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "the check never writes: no mutating command appears in the source" {
  # A structural backstop for the runtime check above: the script reads live
  # state and must never acquire a writer.
  grep -qE 'gh api .*--method (POST|PUT|PATCH|DELETE)' "$SCRIPT" && return 1
  grep -qE '^[^#]*git [a-z -]*(commit|push|checkout|add|reset)' "$SCRIPT" && return 1
  return 0
}

# Invariant 7: every tracked path resolves an owner (#1245).
#
# The universe is the tracked file list of the repository ROOTED AT --root, so
# these fixtures `git init` and `git add` rather than being bare directories.
# The sibling fixtures above deliberately stay non-git: the invariant has no
# universe there and does not run, which is what keeps it from re-reddening
# every other test in this suite.

# Scaffolds a fixture root as scaffold_root does, then makes it a repository
# and stages everything, so `git ls-files` has an answer. Extra tracked files
# are passed as trailing arguments and created empty.
scaffold_tracked_root() {
  local r="$1"
  shift
  scaffold_root "$r"
  local f
  for f in "$@"; do
    mkdir -p "$r/$(dirname "$f")"
    : > "$r/$f"
  done
  git init -q "$r"
  git -C "$r" add -A
}

# The roster every test in this section starts from: two claimants plus the
# default, and an `unowned:` list covering the scaffolding itself (the roster,
# the agent files and the machinery list) so a fixture is clean unless the
# test deliberately adds an unowned path.
tracked_roster() {
  cat <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    default: true
  - name: code-audit-alpha
    globs:
      - "lib/**"
YAML
  printf 'unowned:\n'
  printf '  - "%s"\n' "$@"
}

@test "coverage: a tracked path owned by nobody and exempted by nobody fails" {
  local r="$BATS_TEST_TMPDIR/cov-orphan"
  tracked_roster '.claude/**' '.gaia/**' | scaffold_tracked_root "$r" \
    app/a.ts lib/b.ts docs/orphan.md
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "ownerless-path"
  assert_contains "docs/orphan.md"
}

@test "coverage: an owned path is not reported, so the finding is not vacuous" {
  local r="$BATS_TEST_TMPDIR/cov-owned"
  tracked_roster '.claude/**' '.gaia/**' | scaffold_tracked_root "$r" \
    app/a.ts lib/b.ts docs/orphan.md
  run_root "$r"
  # Anchor on the finding this test controls for before asserting the absences.
  # Two `grep … && return 1` checks plus `return 0` pass on ANY output that
  # happens not to name the owned paths -- an exit-2 usage error, or an empty
  # run -- so without these two lines the vacuity guard is itself vacuous.
  [ "$status" -eq 1 ]
  assert_contains "docs/orphan.md"
  grep -qF "app/a.ts" <<<"$output" && return 1
  grep -qF "lib/b.ts" <<<"$output" && return 1
  return 0
}

@test "coverage: an unowned: glob covering the path clears it" {
  local r="$BATS_TEST_TMPDIR/cov-exempt"
  tracked_roster '.claude/**' '.gaia/**' 'docs/**' | scaffold_tracked_root "$r" \
    app/a.ts lib/b.ts docs/orphan.md
  run_root "$r"
  [ "$status" -eq 0 ]
  assert_contains "roster clean"
}

@test "coverage: an unowned: glob reaching an OWNED path fails as overbroad" {
  # The anti-rubber-stamp assertion. A blanket exemption is the one move that
  # would turn this invariant into a formality, and it fails here because it
  # necessarily also covers a path some member already owns.
  local r="$BATS_TEST_TMPDIR/cov-overbroad"
  tracked_roster '**' | scaffold_tracked_root "$r" app/a.ts lib/b.ts
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "overbroad-unowned-glob"
}

@test "coverage: the overbroad finding cites the owned witness and its owner" {
  local r="$BATS_TEST_TMPDIR/cov-overbroad-witness"
  tracked_roster '.claude/**' '.gaia/**' 'app/**' | scaffold_tracked_root "$r" \
    app/a.ts lib/b.ts
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "overbroad-unowned-glob"
  assert_contains "app/a.ts"
  assert_contains "code-audit-frontend"
}

@test "coverage: an unowned: glob outside the classifier dialect fails as undecidable" {
  # `docs**` spells `**` inside a segment rather than as a whole one, so the
  # classifier escapes it into `^docs.*$`, which crosses `/`. The entry then
  # exempts docsextra/note.md as well, silently, and the run reports clean --
  # the exact fail-open its sibling glob position already refuses (a region
  # glob fails undecidable-remit-glob).
  local r="$BATS_TEST_TMPDIR/cov-dialect"
  tracked_roster '.claude/**' '.gaia/**' 'docs**' | scaffold_tracked_root "$r" \
    app/a.ts lib/b.ts docs/orphan.md docsextra/note.md
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "undecidable-unowned-glob"
  assert_contains "docs**"
}

@test "coverage: an in-dialect unowned: glob is not reported as undecidable" {
  # The negative control. The gate above must reject the dialect's rejects and
  # nothing else; a gate that failed every entry would pass its own test while
  # making the list unusable.
  local r="$BATS_TEST_TMPDIR/cov-dialect-ok"
  tracked_roster '.claude/**' '.gaia/**' 'docs/**' | scaffold_tracked_root "$r" \
    app/a.ts lib/b.ts docs/orphan.md
  run_root "$r"
  [ "$status" -eq 0 ]
  grep -qF "undecidable-unowned-glob" <<<"$output" && return 1
  return 0
}

@test "coverage: a non-git fixture root has no universe, so the invariant is silent" {
  # What keeps the rest of this suite green: most tests scaffold bare
  # directories, and this is why that costs them nothing.
  local r="$BATS_TEST_TMPDIR/cov-nongit"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
YAML
  run_root "$r"
  [ "$status" -eq 0 ]
  grep -qF "ownerless-path" <<<"$output" && return 1
  return 0
}

@test "coverage: that silence is the missing universe, not a vacuous invariant" {
  # The negative control for the test above, and the one this suite most needs:
  # if the invariant were simply never firing, that test would pass for the
  # wrong reason and every other fixture's green would mean nothing. Same
  # scaffolding, same roster, the ONLY difference being that this root is a
  # repository -- and it must report, because a scaffolded fixture's own roster
  # and agent files are ownerless under a roster that claims `app/**` alone.
  local r="$BATS_TEST_TMPDIR/cov-nonvacuous"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
YAML
  git init -q "$r"
  git -C "$r" add -A
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "ownerless-path"
  assert_contains ".gaia/audit-ci.yml"
}

@test "coverage: a --root inside a repository does not enumerate that repository" {
  # --root names the tree the answer describes. A subdirectory of a checkout is
  # not a repository root, so enumerating the enclosing repo's tracked files
  # would answer a question nobody asked, with every path outside the fixture
  # reported ownerless.
  local sb="$BATS_TEST_TMPDIR/enclosing"
  mkdir -p "$sb"
  git init -q "$sb"
  : > "$sb/outside.md"
  git -C "$sb" add -A
  local r="$sb/nested"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
YAML
  run_root "$r"
  grep -qF "outside.md" <<<"$output" && return 1
  [ "$status" -eq 0 ]
}

@test "coverage: a roster carrying no auditors skips rather than answering for the builtin" {
  # audit_scope_init falls back to the BUILTIN roster when the config yields no
  # records, so without the skip this fixture's paths get classified against
  # GAIA's own roster while every finding prints the injected config's name. The
  # exit status is 1 either way (unreadable-machinery-list fires first, since a
  # roster with no auditors names no member to register), so nothing green is
  # at stake; what the skip protects is attribution, which is the whole value
  # of a finding that names a roster.
  local r="$BATS_TEST_TMPDIR/cov-no-auditors"
  scaffold_root "$r" <<'YAML'
default_mode: local
YAML
  git init -q "$r"
  git -C "$r" add -A
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "unreadable-machinery-list"
  assert_contains "carries no auditors"
  # The misattributed finding the skip exists to suppress.
  grep -qF "ownerless-path" <<<"$output" && return 1
  return 0
}
