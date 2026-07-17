#!/usr/bin/env bats
# Tests for .gaia/scripts/verify-audit-roster.sh, the roster's deterministic
# check.
#
# Every invariant is exercised against FIXTURES injected through --config (the
# roster) and --root (everything the check reads about that roster: the agent
# files and both machinery lists). No test mutates the repo's real roster or its
# real machinery lists; UAT-024 is the one test that reads them, and it only
# reads.
#
# Assertion style (.claude/rules/bats-assertions.md): non-final checks use POSIX
# `[ ]` or `grep -qF`, never a bare `[[ ]]`, which macOS's bash 3.2 does not fail
# on. Absence is asserted as `<positive-condition> && return 1`, never as a
# non-final `!`-negation, which `set -e` exempts on every bash version.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.gaia/scripts/verify-audit-roster.sh"
  [ -f "$SCRIPT" ] || skip "verify-audit-roster.sh not present"
}

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

# Scaffolds a fixture root: the roster arrives on stdin, and the agent files and
# both machinery lists are derived from the member names it declares, so a
# fixture is clean unless a test deliberately breaks one of them.
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
  {
    printf 'GATE_MACHINERY_FILES="$(cat <<%s\n' "'EOF'"
    for n in $names; do printf '.claude/agents/%s.md\n' "$n"; done
    printf 'EOF\n)"\n'
  } > "$r/.gaia/scripts/audit-machinery-complete.sh"
  for n in $names; do printf '# %s\n' "$n" > "$r/.claude/agents/$n.md"; done
}

run_root() {
  run bash "$SCRIPT" --root "$1" --config "$1/.gaia/audit-ci.yml"
}

# A two-claimant roster over one glob each, plus a default that claims nothing
# either claimant does. The unit of the disjointness table below.
pair_root() {
  local r="$BATS_TEST_TMPDIR/pair"
  scaffold_root "$r" <<YAML
auditors:
  - name: member-default
    globs:
      - "zzz-default-only/**"
    scope: adopter
    push_fixes: true
    default: true
  - name: member-a
    globs:
      - "$1"
    scope: adopter
    push_fixes: false
  - name: member-b
    globs:
      - "$2"
    scope: adopter
    push_fixes: false
YAML
  run_root "$r"
}

# ---------------------------------------------------------------------------
# Usage surface
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# UAT-024: the roster this SPEC ships passes. If this fails, either the check
# or the roster is wrong; do not relax the check to fit the roster.
# ---------------------------------------------------------------------------

@test "UAT-024: the shipped roster passes the check" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "roster clean"
}

@test "UAT-024: the shipped roster's own claimants are decided, not skipped" {
  # A guard against a vacuous pass: the roster must actually reach the pairwise
  # tier, i.e. carry more than one claimant. One claimant means zero pairs and
  # the disjointness invariant would pass by having nothing to compare.
  local claimants
  claimants="$(awk '
    /^auditors[[:space:]]*:/ { in_a = 1; next }
    !in_a { next }
    /^[A-Za-z_]/ { in_a = 0; next }
    /^[[:space:]]*-[[:space:]]+name[[:space:]]*:/ { n++; next }
    /^[[:space:]]+default[[:space:]]*:[[:space:]]*true/ { d++ }
    END { print n - d }
  ' "$REPO_ROOT/.gaia/audit-ci.yml")"
  [ "$claimants" -ge 2 ]
}

# ---------------------------------------------------------------------------
# UAT-020: two claimants whose globs overlap AS GLOB LANGUAGES, with no such
# file anywhere in the repo. That is the case the invariant exists for.
# ---------------------------------------------------------------------------

@test "UAT-020: overlapping claimants fail, naming the pair and a witness" {
  pair_root 'zz-no-such-tree/**' 'zz-no-such-tree/deep/*.zz'
  [ "$status" -eq 1 ]
  assert_contains "claimant-glob-overlap"
  assert_contains "member-a"
  assert_contains "member-b"
  assert_contains "witness: zz-no-such-tree/deep/"
}

@test "UAT-020: the witness names a path that exists nowhere in the repo" {
  pair_root 'zz-no-such-tree/**' 'zz-no-such-tree/deep/*.zz'
  local witness
  witness="$(grep -F 'witness:' <<<"$output" | awk '{ print $2 }')"
  [ -n "$witness" ]
  # The invariant holds "whether or not any such file is tracked": the check
  # synthesized this path rather than finding it.
  [ ! -e "$REPO_ROOT/$witness" ]
}

@test "UAT-020: the witness matches both globs, tested through the classifier" {
  # Independent of the check's own verification: compile both globs with the
  # real classifier and match the witness against each compiled regex.
  pair_root 'zz-no-such-tree/**' 'zz-no-such-tree/deep/*.zz'
  local witness
  witness="$(grep -F 'witness:' <<<"$output" | awk '{ print $2 }')"
  . "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  local rx_a rx_b
  rx_a="$(printf 'auditors:\n  - name: m\n    globs:\n      - "zz-no-such-tree/**"\n' |
    _audit_scope_parse_auditors | awk '$1 == "GLOB" { print $3 }')"
  rx_b="$(printf 'auditors:\n  - name: m\n    globs:\n      - "zz-no-such-tree/deep/*.zz"\n' |
    _audit_scope_parse_auditors | awk '$1 == "GLOB" { print $3 }')"
  [ -n "$rx_a" ]
  [ -n "$rx_b" ]
  [[ "$witness" =~ $rx_a ]] || return 1
  [[ "$witness" =~ $rx_b ]] || return 1
}

# ---------------------------------------------------------------------------
# UAT-021: the default member is excluded from the pairwise comparison. Its
# tier is reached only after every claimant has failed to match, so an overlap
# with a claimant is what the precedence tier MEANS, not a defect. The shipped
# roster has exactly this overlap by design.
# ---------------------------------------------------------------------------

@test "UAT-021: a default whose globs overlap a claimant's does not fail" {
  local r="$BATS_TEST_TMPDIR/default-overlap"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - ".github/workflows/**"
      - "app/**"
    scope: adopter
    push_fixes: true
    default: true
  - name: member-a
    globs:
      - ".github/workflows/*.yml"
    scope: adopter
    push_fixes: false
YAML
  run_root "$r"
  [ "$status" -eq 0 ]
}

@test "UAT-021: the default is excluded even against several claimants" {
  local r="$BATS_TEST_TMPDIR/default-overlap-many"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "**"
    scope: adopter
    push_fixes: true
    default: true
  - name: member-a
    globs:
      - "a/**/*.ts"
    scope: adopter
    push_fixes: false
  - name: member-b
    globs:
      - "b/**/*.sh"
    scope: adopter
    push_fixes: false
YAML
  run_root "$r"
  # The default claims literally every path and still fails nothing.
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# UAT-022: machinery registration, each list tested independently, via fixture
# lists injected under --root.
# ---------------------------------------------------------------------------

@test "UAT-022: a member missing from AUDIT_MACHINERY_PATHS fails, naming the file and the list" {
  local r="$BATS_TEST_TMPDIR/unreg-machinery"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "app/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
YAML
  grep -v 'member-a.md' "$r/.claude/hooks/lib/audit-machinery.sh" > "$r/tmp-list"
  mv "$r/tmp-list" "$r/.claude/hooks/lib/audit-machinery.sh"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "unregistered-agent-file"
  assert_contains ".claude/agents/member-a.md"
  assert_contains "AUDIT_MACHINERY_PATHS"
}

@test "UAT-022: a member missing from GATE_MACHINERY_FILES fails, naming the file and the list" {
  local r="$BATS_TEST_TMPDIR/unreg-gate"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "app/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
YAML
  grep -v 'member-a.md' "$r/.gaia/scripts/audit-machinery-complete.sh" > "$r/tmp-list"
  mv "$r/tmp-list" "$r/.gaia/scripts/audit-machinery-complete.sh"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "unregistered-agent-file"
  assert_contains ".claude/agents/member-a.md"
  assert_contains "GATE_MACHINERY_FILES"
}

@test "UAT-022: a member missing from AUDIT_MACHINERY_PATHS does not name the other list" {
  local r="$BATS_TEST_TMPDIR/unreg-machinery-only"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "app/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
YAML
  grep -v 'member-a.md' "$r/.claude/hooks/lib/audit-machinery.sh" > "$r/tmp-list"
  mv "$r/tmp-list" "$r/.claude/hooks/lib/audit-machinery.sh"
  run_root "$r"
  # The finding must be attributable to ONE list, or it cannot be acted on.
  grep -qF "missing from: GATE_MACHINERY_FILES" <<<"$output" && return 1
  grep -qF "missing from: AUDIT_MACHINERY_PATHS" <<<"$output"
}

@test "UAT-022: extra entries in either list are fine" {
  # An adopter's lists still name the agents the roster scrub removed. The check
  # walks the roster and asks whether each member is registered, never the
  # reverse.
  local r="$BATS_TEST_TMPDIR/extra-entries"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "app/**"
    default: true
YAML
  printf '.claude/agents/member-not-in-this-roster.md\n' >> "$r/.claude/hooks/lib/audit-machinery.sh"
  printf '.claude/agents/member-not-in-this-roster.md\n' >> "$r/.gaia/scripts/audit-machinery-complete.sh"
  run_root "$r"
  [ "$status" -eq 0 ]
}

@test "an unreadable machinery list fails rather than passing every member" {
  local r="$BATS_TEST_TMPDIR/no-list"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
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

@test "a member whose agent file does not exist on disk fails, naming it" {
  local r="$BATS_TEST_TMPDIR/no-agent"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "app/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
YAML
  rm "$r/.claude/agents/member-a.md"
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "missing-agent-file"
  assert_contains ".claude/agents/member-a.md"
}

# ---------------------------------------------------------------------------
# UAT-023: exactly one default member.
# ---------------------------------------------------------------------------

@test "UAT-023: zero members carrying default: true fails, naming the count" {
  local r="$BATS_TEST_TMPDIR/no-default"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-a
    globs:
      - "a/**"
  - name: member-b
    globs:
      - "b/**"
YAML
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "default-member-count"
  assert_contains "0 (expected exactly 1)"
}

@test "UAT-023: two members carrying default: true fails, naming the count" {
  local r="$BATS_TEST_TMPDIR/two-defaults"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-a
    globs:
      - "a/**"
    default: true
  - name: member-b
    globs:
      - "b/**"
    default: true
YAML
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "default-member-count"
  assert_contains "2 (expected exactly 1)"
}

@test "UAT-023: a roster with no auditors block fails rather than passing empty" {
  local r="$BATS_TEST_TMPDIR/empty-roster"
  scaffold_root "$r" <<'YAML'
default_mode: local
YAML
  run_root "$r"
  [ "$status" -eq 1 ]
  assert_contains "default-member-count"
}

# ---------------------------------------------------------------------------
# UAT-025: a pair the bounded dialect cannot decide FAILS, naming the pair. The
# check never fails open on the assertion it exists to make.
# ---------------------------------------------------------------------------

@test "UAT-025: a '?' glob is undecidable and fails, naming the pair" {
  pair_root 'a/?.ts' 'a/*.ts'
  [ "$status" -eq 1 ]
  assert_contains "undecidable-glob-pair"
  assert_contains "member-a"
  assert_contains "member-b"
  assert_contains "a/?.ts"
}

@test "UAT-025: a bracket class is undecidable and fails" {
  pair_root 'a/[a-z].ts' 'a/*.ts'
  [ "$status" -eq 1 ]
  assert_contains "undecidable-glob-pair"
}

@test "UAT-025: a brace expansion is undecidable and fails" {
  pair_root 'a/{b,c}/x.ts' 'a/b/*.ts'
  [ "$status" -eq 1 ]
  assert_contains "undecidable-glob-pair"
}

@test "UAT-025: '**' inside a segment is undecidable and fails" {
  # app/**.ts is outside the dialect: the segment model cannot represent what
  # the classifier compiles it to. Deciding it would be a guess.
  pair_root 'app/**.ts' 'app/x.ts'
  [ "$status" -eq 1 ]
  assert_contains "undecidable-glob-pair"
}

@test "UAT-025: an undecidable pair is never reported as disjoint" {
  pair_root 'a/?.ts' 'a/*.ts'
  grep -qF "roster clean" <<<"$output" && return 1
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# The disjointness table. The interesting cases are pairs, and the witness is
# what makes an overlap actionable, so each overlapping row asserts its witness.
# ---------------------------------------------------------------------------

@test "pairs: a/** vs a/b/*.ts overlap, witness a/b/<x>.ts" {
  pair_root 'a/**' 'a/b/*.ts'
  [ "$status" -eq 1 ]
  assert_contains "claimant-glob-overlap"
  assert_contains "witness: a/b/"
}

@test "pairs: a/**/*.sh vs a/b/src/** overlap, the witness spans the globstar" {
  # The shape that forces the node member to narrow: a shell glob under a tree
  # another member claims wholesale.
  pair_root 'a/**/*.sh' 'a/b/src/**'
  [ "$status" -eq 1 ]
  assert_contains "claimant-glob-overlap"
  assert_contains "witness: a/b/src/"
  grep -qE 'witness: a/b/src/[^ ]*\.sh' <<<"$output"
}

@test "pairs: *.config.ts vs app/** are disjoint (one is root-only)" {
  pair_root '*.config.ts' 'app/**'
  [ "$status" -eq 0 ]
}

@test "pairs: .github/**/*.sh vs .github/workflows/*.yml are disjoint by extension" {
  pair_root '.github/**/*.sh' '.github/workflows/*.yml'
  [ "$status" -eq 0 ]
}

@test "pairs: x/*/y vs x/**/y overlap" {
  pair_root 'x/*/y' 'x/**/y'
  [ "$status" -eq 1 ]
  assert_contains "claimant-glob-overlap"
}

@test "pairs: a/*.ts vs a/b.ts overlap, the witness is the literal" {
  pair_root 'a/*.ts' 'a/b.ts'
  [ "$status" -eq 1 ]
  assert_contains "witness: a/b.ts"
}

@test "pairs: **/ collapses to zero segments, .github/**/*.sh claims a top-level .github/x.sh" {
  # A checker that assumes **/ consumes at least one segment gets this wrong:
  # `**/` compiles to (.*/)? and matches zero segments.
  pair_root '.github/**/*.sh' '.github/x.sh'
  [ "$status" -eq 1 ]
  assert_contains "witness: .github/x.sh"
}

@test "pairs: a/** vs a are disjoint (a trailing ** needs at least one segment)" {
  pair_root 'a/**' 'a'
  [ "$status" -eq 0 ]
}

@test "pairs: **/foo vs foo overlap on the zero-segment collapse" {
  pair_root '**/foo' 'foo'
  [ "$status" -eq 1 ]
  assert_contains "witness: foo"
}

@test "pairs: *.bats vs *.ts are disjoint (a suffix cannot be both)" {
  pair_root '*.bats' '*.ts'
  [ "$status" -eq 0 ]
}

@test "pairs: two literal globs that differ are disjoint" {
  pair_root '.gaia/audit-ci.yml' '.gaia/VERSION'
  [ "$status" -eq 0 ]
}

@test "pairs: two identical globs overlap" {
  pair_root 'a/b/c.ts' 'a/b/c.ts'
  [ "$status" -eq 1 ]
  assert_contains "witness: a/b/c.ts"
}

@test "pairs: a globstar-only glob claims everything and overlaps any claimant" {
  pair_root '**' 'a/b/*.ts'
  [ "$status" -eq 1 ]
  assert_contains "claimant-glob-overlap"
}

@test "pairs: nested globstars decide, a/**/b/**/c vs a/b/c overlap" {
  pair_root 'a/**/b/**/c' 'a/b/c'
  [ "$status" -eq 1 ]
  assert_contains "witness: a/b/c"
}

@test "pairs: the real roster's shell and node globs are disjoint" {
  # The narrowing this roster depends on: .gaia/**/*.sh and .gaia/cli/src/**
  # overlap (witness .gaia/cli/src/<x>.sh), while .gaia/**/*.sh and the
  # extension-enumerated node globs do not.
  pair_root '.gaia/**/*.sh' '.gaia/cli/src/**/*.ts'
  [ "$status" -eq 0 ]
}

@test "pairs: the un-narrowed node glob overlaps the shell glob, witness under .gaia/cli/src" {
  pair_root '.gaia/**/*.sh' '.gaia/cli/src/**'
  [ "$status" -eq 1 ]
  assert_contains "claimant-glob-overlap"
  grep -qE 'witness: \.gaia/cli/src/[^ ]*\.sh' <<<"$output"
}

@test "pairs: globs of the SAME member are never compared" {
  # A member may claim overlapping globs; the invariant is pairwise across
  # members.
  local r="$BATS_TEST_TMPDIR/same-member"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
      - "a/b/*.ts"
      - "a/b/c.ts"
YAML
  run_root "$r"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The raw-glob scrape is held in lockstep with the classifier
# ---------------------------------------------------------------------------

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
  grep -qF 'g != "a/**"' "$sb/.gaia/scripts/verify-audit-roster.sh"
}

@test "reader drift: a scrape that disagrees with the classifier fails, naming the member" {
  local sb="$BATS_TEST_TMPDIR/drift-sandbox"
  drifted_reader_sandbox "$sb"
  local r="$BATS_TEST_TMPDIR/drift-fixture"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
      - "a/b/*.ts"
YAML
  run bash "$sb/.gaia/scripts/verify-audit-roster.sh" --root "$r" --config "$r/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ]
  assert_contains "roster-reader-drift"
  assert_contains "member-a"
}

@test "reader drift: no disjointness verdict is produced while the readers disagree" {
  # The finding says no verdict was produced; this pins that claim. A verdict
  # computed from globs the two readers do not agree on would line the raw globs
  # up against the wrong compiled regexes.
  local sb="$BATS_TEST_TMPDIR/drift-sandbox-2"
  drifted_reader_sandbox "$sb"
  local r="$BATS_TEST_TMPDIR/drift-fixture-2"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
  - name: member-b
    globs:
      - "a/b/*.ts"
YAML
  run bash "$sb/.gaia/scripts/verify-audit-roster.sh" --root "$r" --config "$r/.gaia/audit-ci.yml"
  # a/** and a/b/*.ts overlap, and the undrifted check reports it (see the pair
  # table above). Under drift the overlap must NOT be reported as a verdict.
  grep -qF "claimant-glob-overlap" <<<"$output" && return 1
  assert_contains "roster-reader-drift"
}

# ---------------------------------------------------------------------------
# The maintainer-only lockstep block
# ---------------------------------------------------------------------------

@test "lockstep: a --config-injected run does not evaluate the builtin-fallback lockstep" {
  # Load-bearing: every fixture roster differs from the builtin fallback by
  # construction, so without the skip every other fixture test in this suite
  # would fail for a reason that has nothing to do with the invariant under
  # test.
  pair_root 'a/**' 'b/**'
  grep -qF "builtin-fallback-lockstep" <<<"$output" && return 1
  [ "$status" -eq 0 ]
}

@test "lockstep: a --root-injected run does not evaluate it either" {
  local r="$BATS_TEST_TMPDIR/root-only"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "app/**"
    default: true
YAML
  run bash "$SCRIPT" --root "$r"
  grep -qF "builtin-fallback-lockstep" <<<"$output" && return 1
  [ "$status" -eq 0 ]
}

@test "lockstep: a default run fires it when the builtin fallback drifts from the roster" {
  # The negative control for the two skip tests above: a lockstep that never
  # fired would pass them vacuously. A git-inited sandbox is what makes the
  # default (no-flag) resolution land inside the fixture rather than the repo.
  local sb="$BATS_TEST_TMPDIR/lockstep-sandbox"
  mkdir -p "$sb/.gaia/scripts" "$sb/.claude/hooks/lib" "$sb/.claude/agents"
  git init -q "$sb"
  cp "$SCRIPT" "$sb/.gaia/scripts/verify-audit-roster.sh"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$sb/.gaia/audit-ci.yml"
  # Drift the builtin fallback: `app/**` occurs only in _audit_scope_builtin_roster.
  sed 's|- "app/\*\*"|- "app-drifted/**"|' \
    "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" > "$sb/.claude/hooks/lib/audit-scope.sh"
  run bash "$sb/.gaia/scripts/verify-audit-roster.sh"
  [ "$status" -eq 1 ]
  assert_contains "builtin-fallback-lockstep"
}

@test "lockstep: the maintainer-only markers balance" {
  local starts ends
  starts="$(grep -c '^# gaia:maintainer-only:start$' "$SCRIPT")"
  ends="$(grep -c '^# gaia:maintainer-only:end$' "$SCRIPT")"
  [ "$starts" -ge 1 ]
  [ "$starts" -eq "$ends" ]
}

@test "lockstep: the script is valid bash with the maintainer-only block stripped" {
  local stripped="$BATS_TEST_TMPDIR/stripped.sh"
  awk '
    /^# gaia:maintainer-only:start$/ { skip = 1; next }
    /^# gaia:maintainer-only:end$/ { skip = 0; next }
    !skip
  ' "$SCRIPT" > "$stripped"
  grep -qF "gaia:maintainer-only" "$stripped" && return 1
  bash -n "$stripped"
}

@test "lockstep: the stripped script still runs and still decides a roster" {
  # What an adopter runs. Resolved in a sandbox mirroring the repo layout, so
  # the stripped copy's own script-relative library resolution is exercised too.
  local sb="$BATS_TEST_TMPDIR/stripped-sandbox"
  mkdir -p "$sb/.gaia/scripts" "$sb/.claude/hooks/lib"
  awk '
    /^# gaia:maintainer-only:start$/ { skip = 1; next }
    /^# gaia:maintainer-only:end$/ { skip = 0; next }
    !skip
  ' "$SCRIPT" > "$sb/.gaia/scripts/verify-audit-roster.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$sb/.claude/hooks/lib/audit-scope.sh"

  local r="$BATS_TEST_TMPDIR/stripped-fixture"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
  - name: member-b
    globs:
      - "a/b/*.ts"
YAML
  run bash "$sb/.gaia/scripts/verify-audit-roster.sh" --root "$r" --config "$r/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ]
  assert_contains "claimant-glob-overlap"
}

# ---------------------------------------------------------------------------
# Read-only
# ---------------------------------------------------------------------------

@test "the check never writes: the fixture root is byte-identical after a run" {
  local r="$BATS_TEST_TMPDIR/readonly"
  scaffold_root "$r" <<'YAML'
auditors:
  - name: member-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: member-a
    globs:
      - "a/**"
  - name: member-b
    globs:
      - "a/b/*.ts"
YAML
  local before after
  before="$(find "$r" -type f -exec shasum {} + | sort)"
  run_root "$r"
  [ "$status" -eq 1 ]
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
