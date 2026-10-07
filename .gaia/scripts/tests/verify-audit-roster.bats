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
# .claude/rules/bats-assertions.md prescribes.
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

# bats file_tags=whole-tree

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
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
# This awk is a hand-kept model, not held to the real parser by a test. Two
# sibling suites carry the same block for the same reason
# (`audit-write-clearance.bats`,
# `.gaia/tests/statusline/statusline-worktree.bats`), so a change here belongs
# in all of them, and in the real parser too if the transform it models changed.
strip_maintainer_only() {
  awk -v start_marker="$MAINTAINER_START" -v end_marker="$MAINTAINER_END" '
    {
      has_start = index($0, start_marker) > 0
      has_end = index($0, end_marker) > 0
      if (!skip && has_start) { if (!has_end) skip = 1; next }
      if (skip) { if (has_end) skip = 0; next }
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
  local fixture_directory="$1" names member_name
  rm -rf "$fixture_directory"
  mkdir -p "$fixture_directory/.gaia/scripts" "$fixture_directory/.claude/agents" "$fixture_directory/.claude/hooks/lib"
  cat > "$fixture_directory/.gaia/audit-ci.yml"
  names="$(awk '/^[[:space:]]*-[[:space:]]+name[[:space:]]*:/ {
    sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, ""); print }' "$fixture_directory/.gaia/audit-ci.yml")"
  {
    printf 'AUDIT_MACHINERY_PATHS="$(cat <<%s\n' "'EOF'"
    for member_name in $names; do printf '.claude/agents/%s.md\n' "$member_name"; done
    printf 'EOF\n)"\n'
  } > "$fixture_directory/.claude/hooks/lib/audit-machinery.sh"
  for member_name in $names; do
    cat > "$fixture_directory/.claude/agents/$member_name.md" <<MD
---
name: $member_name
---

# $member_name

## Remit and self-skip

You own things.
MD
  done
  bash "$WRITER" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml" >/dev/null
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
  local agent_file="$1"
  awk -v start_marker="$REMIT_START" -v end_marker="$REMIT_END" '
    $0 == start_marker { skip = 1; next }
    $0 == end_marker { skip = 0; next }
    !skip
  ' "$agent_file" > "$agent_file.tmp"
  mv "$agent_file.tmp" "$agent_file"
}

duplicate_region() {
  local agent_file="$1" block
  block="$(awk -v start_marker="$REMIT_START" -v end_marker="$REMIT_END" '
    $0 == start_marker { in_region = 1 }
    in_region { print }
    $0 == end_marker { in_region = 0 }
  ' "$agent_file")"
  printf '\n%s\n' "$block" >> "$agent_file"
}

unbalance_region() {
  local agent_file="$1"
  grep -vxF -- "$REMIT_END" "$agent_file" > "$agent_file.tmp"
  mv "$agent_file.tmp" "$agent_file"
}

# Moves the end marker to appear BEFORE the start marker: still exactly one
# of each (start_marker_count=1, end_marker_count=1), so a counts-only classifier reads this as a
# normal balanced pair, but the pair is reversed and the region cannot be
# read in file order.
reverse_region() {
  local agent_file="$1"
  awk -v start_marker="$REMIT_START" -v end_marker="$REMIT_END" '
    $0 == end_marker { next }
    $0 == start_marker { print end_marker; print; next }
    { print }
  ' "$agent_file" > "$agent_file.tmp"
  mv "$agent_file.tmp" "$agent_file"
}

drop_region_glob() {
  local agent_file="$1" glob="$2"
  grep -vxF -- "- \`$glob\`" "$agent_file" > "$agent_file.tmp"
  mv "$agent_file.tmp" "$agent_file"
}

add_region_glob() {
  local agent_file="$1" glob="$2"
  awk -v start_marker="$REMIT_START" -v line="- \`$glob\`" '
    { print }
    $0 == start_marker { print line }
  ' "$agent_file" > "$agent_file.tmp"
  mv "$agent_file.tmp" "$agent_file"
}

swap_region_globs() {
  local agent_file="$1"
  awk -v start_marker="$REMIT_START" -v end_marker="$REMIT_END" '
    $0 == start_marker { in_region = 1; print; next }
    $0 == end_marker { in_region = 0; print; next }
    in_region && /^- `.*`$/ {
      bullet_count++
      if (bullet_count == 1) { first = $0; next }
      if (bullet_count == 2) { print; print first; next }
    }
    { print }
  ' "$agent_file" > "$agent_file.tmp"
  mv "$agent_file.tmp" "$agent_file"
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
  local members name agent_relative_path
  members="$(bash "$SCRIPT" --emit-roster | awk -F'\t' '$1 == "MEMBER" { print $2 }' | sort -u)"
  [ -n "$members" ]
  while IFS= read -r name; do
    agent_relative_path=".claude/agents/${name}.md"
    grep -qxF -- "$agent_relative_path" "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" || {
      printf '%s is not registered in AUDIT_MACHINERY_PATHS\n' "$agent_relative_path" >&2
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
  local fixture_directory="$BATS_TEST_TMPDIR/no-list"
  scaffold_root "$fixture_directory" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
YAML
  rm "$fixture_directory/.claude/hooks/lib/audit-machinery.sh"
  run_root "$fixture_directory"
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
  local fixture_directory="$BATS_TEST_TMPDIR/remit-missing"
  remit_root "$fixture_directory"
  drop_region_glob "$fixture_directory/.claude/agents/code-audit-a.md" 'a/two/*.ts'
  run_root "$fixture_directory"
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
  local fixture_directory="$BATS_TEST_TMPDIR/remit-ungranted"
  remit_root "$fixture_directory"
  # In the dialect on purpose, so the undecidable arm cannot fire and blur the
  # case.
  add_region_glob "$fixture_directory/.claude/agents/code-audit-a.md" 'zzz-not-granted/**'
  run_root "$fixture_directory"
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
  local fixture_directory="$BATS_TEST_TMPDIR/remit-order"
  remit_root "$fixture_directory"
  swap_region_globs "$fixture_directory/.claude/agents/code-audit-a.md"
  run_root "$fixture_directory"
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
  local fixture_directory="$BATS_TEST_TMPDIR/remit-shape-missing"
  remit_root "$fixture_directory"
  strip_region "$fixture_directory/.claude/agents/code-audit-a.md"
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "missing-remit-region"
  assert_contains "code-audit-a"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
}

@test "SPEC-056 UAT-004: a definition with two regions fails" {
  local fixture_directory="$BATS_TEST_TMPDIR/remit-shape-dup"
  remit_root "$fixture_directory"
  duplicate_region "$fixture_directory/.claude/agents/code-audit-a.md"
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "duplicate-remit-region"
  assert_contains "code-audit-a"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
}

@test "SPEC-056 UAT-004: a definition whose markers do not pair up fails" {
  local fixture_directory="$BATS_TEST_TMPDIR/remit-shape-unbalanced"
  remit_root "$fixture_directory"
  unbalance_region "$fixture_directory/.claude/agents/code-audit-a.md"
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "unbalanced-remit-region"
  assert_contains "code-audit-a"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
}

@test "reversed-remit-region: a definition whose end marker precedes its start marker fails" {
  # A single balanced pair (start=1, end=1) is not enough: counting alone
  # would read this as replaceable, which is exactly the shape that made the
  # writer destructive before it checked marker ORDER too.
  local fixture_directory="$BATS_TEST_TMPDIR/remit-shape-reversed"
  remit_root "$fixture_directory"
  reverse_region "$fixture_directory/.claude/agents/code-audit-a.md"
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "reversed-remit-region"
  assert_contains "code-audit-a"
  assert_contains "bash .gaia/scripts/write-audit-remits.sh"
}

@test "SPEC-056 UAT-004: no marker-shape failure is ever reported as parity-clean" {
  local shape agent_file fixture_directory
  for shape in strip duplicate unbalance reverse; do
    fixture_directory="$BATS_TEST_TMPDIR/remit-shape-clean-$shape"
    remit_root "$fixture_directory"
    agent_file="$fixture_directory/.claude/agents/code-audit-a.md"
    case "$shape" in
      strip)     strip_region "$agent_file" ;;
      duplicate) duplicate_region "$agent_file" ;;
      unbalance) unbalance_region "$agent_file" ;;
      reverse)   reverse_region "$agent_file" ;;
    esac
    run_root "$fixture_directory"
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
  local glob
  for glob in 'a/[a-z].ts' 'a/{b,c}/x.ts' 'a/?.ts' 'a/\x.ts' 'app/**.ts' 'a/***/b'; do
    undecidable_remit_root "$BATS_TEST_TMPDIR/remit-undec-default" "$glob" 'a/one/**'
    [ "$status" -eq 1 ] || return 1
    grep -qF "undecidable-remit-glob" <<<"$output" || return 1
    grep -qF "$glob" <<<"$output" || return 1
    grep -qF "reason:" <<<"$output" || return 1
  done
  return 0
}

@test "SPEC-056 UAT-005: an undecidable glob granted to a LONE claimant fails" {
  local glob
  for glob in 'a/[a-z].ts' 'a/{b,c}/x.ts' 'a/?.ts' 'a/\x.ts' 'app/**.ts' 'a/***/b'; do
    undecidable_remit_root "$BATS_TEST_TMPDIR/remit-undec-claimant" 'zzz-default-only/**' "$glob"
    [ "$status" -eq 1 ] || return 1
    grep -qF "undecidable-remit-glob" <<<"$output" || return 1
    grep -qF "$glob" <<<"$output" || return 1
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

  local records members member roster_globs region_globs
  records="$(bash "$SCRIPT" --emit-roster)"
  members="$(printf '%s\n' "$records" | awk -F'\t' '$1 == "MEMBER" { print $2 }')"
  [ -n "$members" ]
  for member in $members; do
    roster_globs="$(printf '%s\n' "$records" |
      awk -F'\t' -v member="$member" '$1 == "RAW" && $2 == member { printf "%s|", $3 }')"
    region_globs="$(awk -v start_marker="$REMIT_START" -v end_marker="$REMIT_END" '
      $0 == start_marker { in_region = 1; next }
      $0 == end_marker { in_region = 0; next }
      in_region && match($0, /^- `.*`$/) { printf "%s|", substr($0, 4, length($0) - 4) }
    ' "$REPO_ROOT/.claude/agents/$member.md")"
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
  local sandbox="$1"
  mkdir -p "$sandbox/.gaia/scripts" "$sandbox/.claude/hooks/lib"
  # A copy of the check whose scrape drops one glob the classifier still
  # compiles: exactly the shape of a future edit to one reader and not the
  # other.
  sed 's|if (glob != "") print "RAW", member, glob|if (glob != "" \&\& glob != "a/**") print "RAW", member, glob|' \
    "$SCRIPT" > "$sandbox/.gaia/scripts/verify-audit-roster.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$sandbox/.claude/hooks/lib/audit-scope.sh"
  # The writer resolves the check beside itself, so a copy here observes the
  # perturbation rather than the repo's real scrape. That is what makes the
  # writer's half of "one scrape, shared" testable at all.
  cp "$WRITER" "$sandbox/.gaia/scripts/write-audit-remits.sh"
  grep -qF 'glob != "a/**"' "$sandbox/.gaia/scripts/verify-audit-roster.sh"
}

@test "reader drift: a scrape that disagrees with the classifier fails, naming the member" {
  local sandbox="$BATS_TEST_TMPDIR/drift-sandbox"
  drifted_reader_sandbox "$sandbox"
  local fixture_directory="$BATS_TEST_TMPDIR/drift-fixture"
  scaffold_root "$fixture_directory" <<'YAML'
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
  run bash "$sandbox/.gaia/scripts/verify-audit-roster.sh" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml"
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
  local sandbox="$BATS_TEST_TMPDIR/drift-sandbox-writer"
  drifted_reader_sandbox "$sandbox"
  local fixture_directory="$BATS_TEST_TMPDIR/drift-writer-fixture"
  drift_writer_fixture "$fixture_directory"
  local agent="$fixture_directory/.claude/agents/code-audit-a.md"
  # scaffold_root ran the REAL writer against the real check, so both globs are
  # in the region.
  grep -qF -- "- \`a/**\`" "$agent"
  # The sandbox writer resolves the perturbed check beside it, whose scrape
  # drops a/**, so the region it regenerates drops it too.
  bash "$sandbox/.gaia/scripts/write-audit-remits.sh" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml" >/dev/null
  grep -qF -- "- \`a/**\`" "$agent" && return 1
  grep -qF -- "- \`a/b/*.ts\`" "$agent"
  # And the real writer puts it back, which is what makes the difference
  # attributable to the perturbation rather than to the writer.
  bash "$WRITER" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml" >/dev/null
  grep -qF -- "- \`a/**\`" "$agent"
}

@test "SPEC-056 UAT-011: the perturbed check still fires roster-reader-drift" {
  # The other half of the same perturbation: the check's own observable output
  # changes too, so the shared scrape is load-bearing on both sides.
  local sandbox="$BATS_TEST_TMPDIR/drift-sandbox-both"
  drifted_reader_sandbox "$sandbox"
  local fixture_directory="$BATS_TEST_TMPDIR/drift-both-fixture"
  drift_writer_fixture "$fixture_directory"
  run bash "$sandbox/.gaia/scripts/verify-audit-roster.sh" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml"
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
  local script_file="$BATS_TEST_TMPDIR/indented-pair.sh"
  # Built from the same constants the model matches on, so the fixture cannot
  # drift into being a third spelling of the marker.
  {
    printf 'before=1\n'
    printf '  %s\n' "$MAINTAINER_START"
    printf '  maintainer_only=1\n'
    printf '  %s\n' "$MAINTAINER_END"
    printf 'after=1\n'
  } > "$script_file"
  run strip_maintainer_only "$script_file"
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
  local sandbox="$BATS_TEST_TMPDIR/stripped-sandbox"
  mkdir -p "$sandbox/.gaia/scripts" "$sandbox/.claude/hooks/lib"
  strip_maintainer_only "$SCRIPT" > "$sandbox/.gaia/scripts/verify-audit-roster.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$sandbox/.claude/hooks/lib/audit-scope.sh"

  local fixture_directory="$BATS_TEST_TMPDIR/stripped-fixture"
  scaffold_root "$fixture_directory" <<'YAML'
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
  run bash "$sandbox/.gaia/scripts/verify-audit-roster.sh" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml"
  [ "$status" -eq 0 ]
  assert_contains "roster clean"
}

# Read-only

@test "the check never writes: the fixture root is byte-identical after a run" {
  local fixture_directory="$BATS_TEST_TMPDIR/readonly"
  remit_root "$fixture_directory"
  drop_region_glob "$fixture_directory/.claude/agents/code-audit-a.md" 'a/two/*.ts'
  local before after
  before="$(find "$fixture_directory" -type f -exec shasum {} + | sort)"
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  after="$(find "$fixture_directory" -type f -exec shasum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "SPEC-056 UAT-008: the check never writes on the passing path either" {
  # The twin of the failing-path case above. A check that repaired a drifted
  # region rather than reporting it would be indistinguishable from a clean run
  # unless the clean run is pinned too. Fixture byte-identity, never git status:
  # $BATS_TEST_TMPDIR is not a git repo.
  local fixture_directory="$BATS_TEST_TMPDIR/readonly-clean"
  remit_root "$fixture_directory"
  local before after
  before="$(find "$fixture_directory" -type f -exec shasum {} + | sort)"
  run_root "$fixture_directory"
  [ "$status" -eq 0 ]
  after="$(find "$fixture_directory" -type f -exec shasum {} + | sort)"
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
  local fixture_directory="$1"
  shift
  scaffold_root "$fixture_directory"
  local tracked_path
  for tracked_path in "$@"; do
    mkdir -p "$fixture_directory/$(dirname "$tracked_path")"
    : > "$fixture_directory/$tracked_path"
  done
  git init -q "$fixture_directory"
  git -C "$fixture_directory" add -A
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
  local fixture_directory="$BATS_TEST_TMPDIR/cov-orphan"
  tracked_roster '.claude/**' '.gaia/**' | scaffold_tracked_root "$fixture_directory" \
    app/a.ts lib/b.ts docs/orphan.md
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "ownerless-path"
  assert_contains "docs/orphan.md"
}

@test "coverage: an owned path is not reported, so the finding is not vacuous" {
  local fixture_directory="$BATS_TEST_TMPDIR/cov-owned"
  tracked_roster '.claude/**' '.gaia/**' | scaffold_tracked_root "$fixture_directory" \
    app/a.ts lib/b.ts docs/orphan.md
  run_root "$fixture_directory"
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
  local fixture_directory="$BATS_TEST_TMPDIR/cov-exempt"
  tracked_roster '.claude/**' '.gaia/**' 'docs/**' | scaffold_tracked_root "$fixture_directory" \
    app/a.ts lib/b.ts docs/orphan.md
  run_root "$fixture_directory"
  [ "$status" -eq 0 ]
  assert_contains "roster clean"
}

@test "coverage: an unowned: glob reaching an OWNED path fails as overbroad" {
  # The anti-rubber-stamp assertion. A blanket exemption is the one move that
  # would turn this invariant into a formality, and it fails here because it
  # necessarily also covers a path some member already owns.
  local fixture_directory="$BATS_TEST_TMPDIR/cov-overbroad"
  tracked_roster '**' | scaffold_tracked_root "$fixture_directory" app/a.ts lib/b.ts
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "overbroad-unowned-glob"
}

@test "coverage: the overbroad finding cites the owned witness and its owner" {
  local fixture_directory="$BATS_TEST_TMPDIR/cov-overbroad-witness"
  tracked_roster '.claude/**' '.gaia/**' 'app/**' | scaffold_tracked_root "$fixture_directory" \
    app/a.ts lib/b.ts
  run_root "$fixture_directory"
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
  local fixture_directory="$BATS_TEST_TMPDIR/cov-dialect"
  tracked_roster '.claude/**' '.gaia/**' 'docs**' | scaffold_tracked_root "$fixture_directory" \
    app/a.ts lib/b.ts docs/orphan.md docsextra/note.md
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "undecidable-unowned-glob"
  assert_contains "docs**"
}

@test "coverage: an in-dialect unowned: glob is not reported as undecidable" {
  # The negative control. The gate above must reject the dialect's rejects and
  # nothing else; a gate that failed every entry would pass its own test while
  # making the list unusable.
  local fixture_directory="$BATS_TEST_TMPDIR/cov-dialect-ok"
  tracked_roster '.claude/**' '.gaia/**' 'docs/**' | scaffold_tracked_root "$fixture_directory" \
    app/a.ts lib/b.ts docs/orphan.md
  run_root "$fixture_directory"
  [ "$status" -eq 0 ]
  grep -qF "undecidable-unowned-glob" <<<"$output" && return 1
  return 0
}

@test "coverage: a non-git fixture root has no universe, so the invariant is silent" {
  # What keeps the rest of this suite green: most tests scaffold bare
  # directories, and this is why that costs them nothing.
  local fixture_directory="$BATS_TEST_TMPDIR/cov-nongit"
  scaffold_root "$fixture_directory" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
YAML
  run_root "$fixture_directory"
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
  local fixture_directory="$BATS_TEST_TMPDIR/cov-nonvacuous"
  scaffold_root "$fixture_directory" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
YAML
  git init -q "$fixture_directory"
  git -C "$fixture_directory" add -A
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "ownerless-path"
  assert_contains ".gaia/audit-ci.yml"
}

@test "coverage: a --root inside a repository does not enumerate that repository" {
  # --root names the tree the answer describes. A subdirectory of a checkout is
  # not a repository root, so enumerating the enclosing repo's tracked files
  # would answer a question nobody asked, with every path outside the fixture
  # reported ownerless.
  local sandbox="$BATS_TEST_TMPDIR/enclosing"
  mkdir -p "$sandbox"
  git init -q "$sandbox"
  : > "$sandbox/outside.md"
  git -C "$sandbox" add -A
  local fixture_directory="$sandbox/nested"
  scaffold_root "$fixture_directory" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
YAML
  run_root "$fixture_directory"
  grep -qF "outside.md" <<<"$output" && return 1
  [ "$status" -eq 0 ]
}

@test "coverage: a roster carrying no auditors skips the coverage invariant" {
  # There is no roster to classify against, and audit_scope_init returns
  # non-zero on it. The exit status is 1 either way (unreadable-machinery-list
  # fires first, since a roster with no auditors names no member to register),
  # so nothing green is at stake; the skip keeps not-run from reading as a
  # coverage verdict.
  local fixture_directory="$BATS_TEST_TMPDIR/cov-no-auditors"
  scaffold_root "$fixture_directory" <<'YAML'
default_mode: local
YAML
  git init -q "$fixture_directory"
  git -C "$fixture_directory" add -A
  run_root "$fixture_directory"
  [ "$status" -eq 1 ]
  assert_contains "unreadable-machinery-list"
  assert_contains "carries no auditors"
  # The spurious ownerless findings an empty roster would produce.
  grep -qF "ownerless-path" <<<"$output" && return 1
  return 0
}

# --- Light-review keys --------------------------------------------------------
#
# Fixture: one default member owning `app/**` and `cfg/*.ts`, carrying the three
# keys. Arguments: <directory> <light_review value> <light_line_cap value, or
# empty to omit the key> then one light_hard_full glob per remaining argument.
light_root() {
  local fixture_directory="$1" review_value="$2" cap_value="$3" hard_full_glob
  shift 3
  {
    printf 'auditors:\n'
    printf '  - name: code-audit-default\n'
    printf '    globs:\n'
    printf '      - "app/**"\n'
    printf '      - "cfg/*.ts"\n'
    printf '    light_review: %s\n' "$review_value"
    if [ -n "$cap_value" ]; then printf '    light_line_cap: %s\n' "$cap_value"; fi
    if [ "$#" -gt 0 ]; then
      printf '    light_hard_full:\n'
      for hard_full_glob in "$@"; do printf '      - "%s"\n' "$hard_full_glob"; done
    fi
    printf '    default: true\n'
  } | scaffold_root "$fixture_directory"
}

@test "light keys: a well-formed member passes, so the failures below are not vacuous" {
  light_root "$BATS_TEST_TMPDIR/light-ok" true 50 'app/tests/**' 'app/**' 'cfg/*.ts' 'cfg/exact.ts' 'app/**/x/*.ts'
  run_root "$BATS_TEST_TMPDIR/light-ok"
  [ "$status" -eq 0 ]
  assert_contains "roster clean"
}

@test "light keys: light_review other than the literal true or false fails" {
  local value
  for value in yes '"true"' True 1 on; do
    light_root "$BATS_TEST_TMPDIR/light-review" "$value" 50 'app/tests/**'
    run_root "$BATS_TEST_TMPDIR/light-review"
    [ "$status" -eq 1 ] || { echo "value '$value' passed" >&2; return 1; }
    grep -qF "invalid-light-review" <<<"$output" || { echo "value '$value' not named: $output" >&2; return 1; }
    grep -qF "$value" <<<"$output" || { echo "value '$value' not echoed" >&2; return 1; }
  done
  # The boolean spellings the router accepts stay clean.
  for value in true false; do
    light_root "$BATS_TEST_TMPDIR/light-review" "$value" 50 'app/tests/**'
    run_root "$BATS_TEST_TMPDIR/light-review"
    [ "$status" -eq 0 ] || { echo "value '$value' failed: $output" >&2; return 1; }
  done
}

@test "light keys: light_line_cap that is not a positive integer no greater than the ceiling fails" {
  local value
  for value in 0 -3 abc 80 51 '"50"' 050 5.5 1000000000000; do
    light_root "$BATS_TEST_TMPDIR/light-cap" true "$value" 'app/tests/**'
    run_root "$BATS_TEST_TMPDIR/light-cap"
    [ "$status" -eq 1 ] || { echo "cap '$value' passed" >&2; return 1; }
    grep -qF "invalid-light-line-cap" <<<"$output" || { echo "cap '$value' not named: $output" >&2; return 1; }
  done
  # The edges that must stay clean: 1 and the ceiling itself.
  for value in 1 50; do
    light_root "$BATS_TEST_TMPDIR/light-cap" true "$value" 'app/tests/**'
    run_root "$BATS_TEST_TMPDIR/light-cap"
    [ "$status" -eq 0 ] || { echo "cap '$value' failed: $output" >&2; return 1; }
  done
}

@test "light keys: a cap above the ceiling is reported as one the router would clamp" {
  light_root "$BATS_TEST_TMPDIR/light-cap-high" true 80 'app/tests/**'
  run_root "$BATS_TEST_TMPDIR/light-cap-high"
  [ "$status" -eq 1 ]
  assert_contains "above the ceiling"
}

@test "light keys: an absent light_line_cap is not a finding" {
  light_root "$BATS_TEST_TMPDIR/light-no-cap" true '' 'app/tests/**'
  run_root "$BATS_TEST_TMPDIR/light-no-cap"
  [ "$status" -eq 0 ]
}

@test "light keys: a hard-Full glob outside the member's owned globs fails, wildcard or literal" {
  local glob
  for glob in 'docs/**' 'docs/*.md' 'docs/readme.md' 'cfg/**' 'app*/x.ts'; do
    light_root "$BATS_TEST_TMPDIR/light-uncovered" true 50 'app/tests/**' "$glob"
    run_root "$BATS_TEST_TMPDIR/light-uncovered"
    [ "$status" -eq 1 ] || { echo "glob '$glob' passed" >&2; return 1; }
    grep -qF "light-hard-full-glob-uncovered" <<<"$output" || { echo "glob '$glob' not named: $output" >&2; return 1; }
    grep -qF "glob:    $glob" <<<"$output" || { echo "glob '$glob' not cited: $output" >&2; return 1; }
  done
}

@test "light keys: a wildcard-free hard-Full path inside an owned glob is decided by the matcher and passes" {
  light_root "$BATS_TEST_TMPDIR/light-literal" true 50 'cfg/exact.ts' 'app/deep/er/file.ts'
  run_root "$BATS_TEST_TMPDIR/light-literal"
  [ "$status" -eq 0 ]
}

@test "light keys: a hard-Full glob outside the classifier dialect fails as undecidable" {
  local glob
  for glob in 'app/[a-z].ts' 'app/{b,c}/x.ts' 'app/?.ts' 'app/**.ts' 'app/***/b'; do
    light_root "$BATS_TEST_TMPDIR/light-undecidable" true 50 "$glob"
    run_root "$BATS_TEST_TMPDIR/light-undecidable"
    [ "$status" -eq 1 ] || { echo "glob '$glob' passed" >&2; return 1; }
    grep -qF "undecidable-light-hard-full-glob" <<<"$output" || { echo "glob '$glob' not named: $output" >&2; return 1; }
    grep -qF "reason:" <<<"$output" || return 1
  done
}

@test "light keys: a matcher that fails with exit 2 is a finding, never a pass" {
  # Scratch copy of the check and its library with the matcher replaced by one
  # that always reports a usage failure. The wildcard-free hard-Full path is
  # the one concrete test this invariant makes, so it must go red.
  local scratch="$BATS_TEST_TMPDIR/matcher-failure-copy"
  mkdir -p "$scratch/.gaia/scripts" "$scratch/.claude/hooks/lib"
  cp "$SCRIPT" "$scratch/.gaia/scripts/verify-audit-roster.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$scratch/.claude/hooks/lib/audit-scope.sh"
  printf '\naudit_glob_matches() { return 2; }\n' >> "$scratch/.claude/hooks/lib/audit-scope.sh"
  light_root "$BATS_TEST_TMPDIR/light-matcher-failure" true 50 'cfg/exact.ts'
  run bash "$scratch/.gaia/scripts/verify-audit-roster.sh" --root "$BATS_TEST_TMPDIR/light-matcher-failure" --config "$BATS_TEST_TMPDIR/light-matcher-failure/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ]
  assert_contains "light-hard-full-glob-uncovered"
  assert_contains "exit 2"
  # The same fixture with the real matcher is clean, so the finding is the
  # matcher's doing and nothing else.
  run_root "$BATS_TEST_TMPDIR/light-matcher-failure"
  [ "$status" -eq 0 ]
}

@test "light keys: the committed roster's opted-in members carry only well-formed, owned hard-Full globs" {
  local opted_members member config_lines hard_full_globs owned_globs glob checked=0
  opted_members=""
  for member in $(bash "$SCRIPT" --emit-roster | awk -F'\t' '$1 == "MEMBER" { print $2 }' | sort -u); do
    config_lines="$(
      . "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
      audit_roster_light_config "$REPO_ROOT" "$member"
    )"
    case "$config_lines" in
      true*) opted_members="$opted_members $member" ;;
      *) continue ;;
    esac
    hard_full_globs="$(printf '%s\n' "$config_lines" | awk -F'\t' '$1 == "HARDFULL" { print $2 }')"
    [ -n "$hard_full_globs" ] || { echo "$member opted in with no hard-Full globs" >&2; return 1; }
    owned_globs="$(bash "$SCRIPT" --emit-roster | awk -F'\t' -v member="$member" '$1 == "RAW" && $2 == member { print $3 }')"
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      checked=$((checked + 1))
      # Parity for the committed roster, derived rather than restated: the
      # glob is owned verbatim or sits under a literal owned `<prefix>/**`.
      if grep -qxF -- "$glob" <<<"$owned_globs"; then continue; fi
      found=0
      while IFS= read -r owned; do
        case "$owned" in
          *"/**") case "$glob" in "${owned%\*\*}"*) found=1 ;; esac ;;
        esac
      done <<<"$owned_globs"
      [ "$found" -eq 1 ] || { echo "$member: hard-Full glob not owned: $glob" >&2; return 1; }
    done <<<"$hard_full_globs"
  done
  [ -n "$opted_members" ] || { echo "no member opts in: the roster no longer exercises light review" >&2; return 1; }
  [ "$checked" -gt 0 ]
}
