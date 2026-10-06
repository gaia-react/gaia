#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-write-clearance.sh, the ONE shared writer for
# every Code Audit Team clearance artifact, and its acceptance by the shared
# reader .claude/hooks/lib/audit-clearance.sh.
#
# The writer takes the audited working root as a REQUIRED argument, derives
# the member's content digest from it via the digest engine
# (.claude/hooks/lib/audit-digest.sh, never from CWD), writes atomically, and
# records a versioned schema-4 body with a `provenance` field. It is NOT
# evidence-gated: it takes no --report, calls no detector, and its body
# carries no evidence block. Provenance is earned or refused only; there is no
# carried family, no --anchor-tree, and every write lands unconditionally
# (overwrites a stale body at the same path).
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  WRITER="$THIS_DIRECTORY/../audit-write-clearance.sh"
  READER="$THIS_DIRECTORY/../../../.claude/hooks/lib/audit-clearance.sh"
  DIGEST_LIBRARY="$THIS_DIRECTORY/../../../.claude/hooks/lib/audit-digest.sh"
  RESOLVER="$THIS_DIRECTORY/../resolve-audit-members.sh"
  # The delimiters of the marker-strip transform in .gaia/release-scrub.yml that
  # governs shell files and .gaia/audit-ci.yml, the two shapes scrub_maintainer_only
  # below is pointed at.
  MAINTAINER_START='# gaia:maintainer-only:start'
  MAINTAINER_END='# gaia:maintainer-only:end'
  [ -x "$WRITER" ] || skip "audit-write-clearance.sh not executable"
  [ -f "$DIGEST_LIBRARY" ] || skip "audit-digest.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # The open-finding accounting is skipped when GITHUB_ACTIONS is true, so a
  # runner's value would leave every accounting arm below unexercised in CI.
  # The CI arms set it per invocation.
  unset GITHUB_ACTIONS

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/.gaia"
  printf '1.6.1\n' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" init --quiet --initial-branch=main
  git -C "$ROOT" config user.email "test@example.com"
  git -C "$ROOT" config user.name "Test"
  git -C "$ROOT" config commit.gpgsign false
  echo "# readme" > "$ROOT/README.md"
  seed_audit_roster "$ROOT"
  git -C "$ROOT" add .gaia/audit-ci.yml .gaia/VERSION README.md
  git -C "$ROOT" commit --quiet -m "init"

  TREE="$(git -C "$ROOT" rev-parse "HEAD^{tree}")"
  HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  AUDIT_DIRECTORY="$ROOT/.gaia/local/audit"
}

# member_digest <root> <member> -> 64-hex digest on stdout
member_digest() {
  local root="$1" member="$2"
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$DIGEST_LIBRARY" "$root" "$member"
}

# Required --root, digest resolved from the root, atomic write, body

@test "UAT-020: omitting --root exits 2 with a usage message on stderr" {
  run bash "$WRITER" --member code-audit-frontend --provenance earned
  [ "$status" -eq 2 ]
  # bats `run` merges stderr into `$output`, so `$output` cannot tell the two
  # apart. Re-run with stdout discarded to prove the usage text goes to stderr
  # specifically, which is what this test claims.
  stderr_output="$(bash "$WRITER" --member code-audit-frontend --provenance earned 2>&1 1>/dev/null || true)"
  grep -qF "usage" <<<"$stderr_output"
  grep -qF "root is required" <<<"$stderr_output"
}

@test "--root naming a subdirectory of a checkout exits 2 and writes no marker" {
  # The digest, the HEAD tree and the marker store are all derived from --root,
  # so a subdirectory would mint a marker keyed to content the caller never
  # named. Assert the marker's ABSENCE on disk, not just the exit code: a
  # writer that exits 2 after publishing still poisons the gate.
  subdirectory="$ROOT/app/components"
  mkdir -p "$subdirectory"
  run bash "$WRITER" --root "$subdirectory" --member code-audit-frontend --provenance earned
  [ "$status" -eq 2 ]
  grep -qF "not a checkout root" <<<"$output" || return 1
  leftover="$(find "$ROOT" -name '*.ok' 2>/dev/null || true)"
  [ -z "$leftover" ]
}

@test "resolves the digest from --root, never the caller's CWD" {
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  git -C "$other" init --quiet --initial-branch=main
  git -C "$other" config user.email "test@example.com"
  git -C "$other" config user.name "Test"
  git -C "$other" config commit.gpgsign false
  echo "different content entirely" > "$other/x.txt"
  seed_audit_roster "$other"
  git -C "$other" add .gaia/audit-ci.yml x.txt
  git -C "$other" commit --quiet -m "other"
  other_digest="$(member_digest "$other" code-audit-frontend)"
  root_digest="$(member_digest "$ROOT" code-audit-frontend)"
  [ -n "$other_digest" ]
  [ -n "$root_digest" ]
  [ "$other_digest" != "$root_digest" ]

  # Run with CWD inside `other`, but --root pointing at ROOT.
  written_path="$( cd "$other" && bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$root_digest" )"
  [ "$written_path" = "$AUDIT_DIRECTORY/${root_digest}.ok" ]
  [ -f "$AUDIT_DIRECTORY/${root_digest}.ok" ]
  # The CWD's digest was NOT used as the key.
  [ ! -f "$AUDIT_DIRECTORY/${other_digest}.ok" ]
}

@test "UAT-020: writes atomically via a temp file in the target dir + mv, leaving no stray temp" {
  # Structural: the writer stages a temp in the audit dir and publishes with mv.
  grep -qF "mktemp" "$WRITER"
  grep -qF "mv " "$WRITER"
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest")"
  [ -f "$written_path" ]
  # No stray temp file left behind after the mv.
  leftover="$(find "$AUDIT_DIRECTORY" -name '.audit-write-clearance.*' 2>/dev/null)"
  [ -z "$leftover" ]
}

@test "earned body records the schema-4 fields, digest as validity key, no carried leftovers" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest" >/dev/null
  marker="$AUDIT_DIRECTORY/${digest}.ok"
  [ -f "$marker" ]
  [ "$(jq -r .version "$marker")" = "1.6.1" ]
  [ "$(jq -r .schema "$marker")" = "4" ]
  [ "$(jq -r .member "$marker")" = "code-audit-frontend" ]
  [ "$(jq -r .provenance "$marker")" = "earned" ]
  [ "$(jq -r .digest "$marker")" = "$digest" ]
  [ "$(jq -r .sha "$marker")" = "$HEAD_SHA" ]
  [ "$(jq -r .tree "$marker")" = "$TREE" ]
  # `sidecar` answers "does this member file a findings sidecar" (every member does).
  [ "$(jq -r .sidecar "$marker")" = "true" ]
  grep -qE '"audited_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$marker"
  # No evidence block, no anchor_tree, no second sidecar pointer.
  [ "$(jq -r 'has("evidence")' "$marker")" = "false" ]
  [ "$(jq -r 'has("sidecar_path")' "$marker")" = "false" ]
  [ "$(jq -r 'has("report")' "$marker")" = "false" ]
  [ "$(jq -r 'has("anchor_tree")' "$marker")" = "false" ]
}

@test "a specialized member's sidecar flag is TRUE: it files a findings sidecar too" {
  # This field used to record false for every specialized member, which the
  # store itself contradicts: most of the findings sidecars on disk belong to
  # specialized members. Anything reasoning from it about whether a report
  # exists was wrong for four of the five, and "no report" is exactly what makes
  # a refusal look unrepairable.
  digest="$(member_digest "$ROOT" code-audit-maintainer-shell)"
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance earned --scope-digest "$digest" >/dev/null
  marker="$AUDIT_DIRECTORY/${digest}.code-audit-maintainer-shell.ok"
  [ -f "$marker" ]
  [ "$(jq -r .sidecar "$marker")" = "true" ]
}

@test "every member records sidecar true" {
  for member in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node \
           code-audit-github-workflows; do
    digest="$(member_digest "$ROOT" "$member")"
    written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned --scope-digest "$digest")"
    [ "$(jq -r .sidecar "$written_path")" = "true" ]
  done
}

@test "a refusal carries the same flag as an earned marker" {
  # A refusal is the case that matters most: its sidecar flag is what tells a
  # reader a report exists to work from.
  digest="$(member_digest "$ROOT" code-audit-maintainer-shell)"
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance refused >/dev/null
  marker="$AUDIT_DIRECTORY/${digest}.code-audit-maintainer-shell.refused"
  [ "$(jq -r .sidecar "$marker")" = "true" ]
}

@test "back-compat: a schema-3 body still validates through the shared reader" {
  # The schema bump is informational; clearance_acceptable ignores the field, so
  # a marker written under the previous contract is still acceptable and the
  # gate's accept/reject behavior is unchanged by the bump.
  digest="$(member_digest "$ROOT" code-audit-maintainer-shell)"
  marker="$AUDIT_DIRECTORY/${digest}.code-audit-maintainer-shell.ok"
  mkdir -p "$AUDIT_DIRECTORY"
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-maintainer-shell","provenance":"earned","digest":"%s","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":false}\n' \
    "$digest" > "$marker"
  run bash -c '. "$1"; clearance_acceptable "$2" "$3" "$4"' _ "$READER" "$marker" code-audit-maintainer-shell "$digest"
  [ "$status" -eq 0 ]
}

# Body escaping: the body is built by `jq -n`, so every value is escaped by
# construction. `version` is the only field read from a file (.gaia/VERSION),
# which makes it the field a stray `"` or `\` actually reaches.

@test "escaping: a version carrying a quote and a backslash still produces valid parseable JSON" {
  # shellcheck disable=SC1003  # the backslash is a literal, which is the point
  printf '%s\n' '1.6.1"\' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "version with quote and backslash"
  digest="$(member_digest "$ROOT" code-audit-frontend)"

  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.ok" ]

  # The body parses at all. A hand-built template emits a bare `\"` here, which
  # closes the string early and makes the whole marker unparseable.
  jq -e . "$written_path" >/dev/null

  # The value round-trips byte-exact: escaped, not stripped or mangled.
  # shellcheck disable=SC1003  # the backslash is a literal, which is the point
  [ "$(jq -r .version "$written_path")" = '1.6.1"\' ]

  # A marker with an awkward version is still acceptable to the gate's reader.
  # shellcheck source=/dev/null
  . "$READER"
  clearance_acceptable "$written_path" code-audit-frontend "$digest"
}

@test "escaping: a version that injects body keys lands as data, never as structure" {
  # The crafted value closes the version string and appends its own member /
  # provenance keys. Escaped, it can only ever be a version string.
  printf '%s\n' '1.6.1","member":"code-audit-frontend","provenance":"earned' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "version attempting key injection"
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"

  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused)"
  jq -e . "$written_path" >/dev/null

  # The injected text is the version VALUE, not new keys.
  [ "$(jq -r .version "$written_path")" = '1.6.1","member":"code-audit-frontend","provenance":"earned' ]
  [ "$(jq -r .member "$written_path")" = "$member" ]
  [ "$(jq -r .provenance "$written_path")" = "refused" ]

  # Structural: each key is emitted exactly once. A template would have spliced
  # a second "member" / "provenance" pair into the raw body.
  [ "$(grep -o '"member":' "$written_path" | wc -l | tr -d ' ')" = "1" ]
  [ "$(grep -o '"provenance":' "$written_path" | wc -l | tr -d ' ')" = "1" ]

  # The forged `earned` never becomes a clearance: no earned marker exists, and
  # the refusal reads as a refusal.
  # shellcheck source=/dev/null
  . "$READER"
  clearance_member_cleared "$ROOT" "$digest" "$member" && return 1
  clearance_member_refused "$ROOT" "$digest" "$member"
}

@test "fails closed (exit non-zero, no marker, no stray temp) when jq cannot build the body" {
  # Shadow jq with a failing stub, keeping the real PATH behind it so git,
  # mktemp and date still resolve and the run reaches the body build. A jq
  # failure must never publish an empty or partial marker on a zero exit.
  shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/jq"
  chmod +x "$shim/jq"
  digest="$(member_digest "$ROOT" code-audit-frontend)"

  run env PATH="$shim:$PATH" bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest"
  [ "$status" -ne 0 ]

  # Pin WHICH guard fired: the body build, not the digest derive. The digest
  # chain needs no jq today, so a bare status check passes for the right reason
  # by luck; were digest derivation to grow a jq dependency it would fail first
  # and this test would green while covering nothing.
  grep -qF "cannot build the marker body" <<<"$output"

  # No marker published, and no half-written temp left staged in the audit dir.
  leftover="$(find "$AUDIT_DIRECTORY" -name '*.ok' 2>/dev/null || true)"
  [ -z "$leftover" ]
  stray="$(find "$AUDIT_DIRECTORY" -name '.audit-write-clearance.*' 2>/dev/null || true)"
  [ -z "$stray" ]
}

# Clean, zero-finding earned write lands for EVERY member. No report, no
# detector; each member's filename stem equals its own body .digest.

@test "clean zero-finding earned write lands for every member, no detector involved" {
  for member in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    digest="$(member_digest "$ROOT" "$member")"
    written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned --scope-digest "$digest")"
    if [ "$member" = "code-audit-frontend" ]; then
      expect="$AUDIT_DIRECTORY/${digest}.ok"
    else
      expect="$AUDIT_DIRECTORY/${digest}.${member}.ok"
    fi
    [ "$written_path" = "$expect" ]
    [ -f "$expect" ]
    [ "$(jq -r .member "$expect")" = "$member" ]
    [ "$(jq -r .provenance "$expect")" = "earned" ]
    [ "$(jq -r .digest "$expect")" = "$digest" ]
  done
}

@test "structural: the writer never references audit-noop-detect.sh and carries no evidence key" {
  grep -qF "audit-noop-detect" "$WRITER" && return 1
  # The JSON evidence key (quoted) never appears in the produced body.
  grep -qF '"evidence"' "$WRITER" && return 1
  return 0
}

# Hard cutover: carried / anchor-tree are gone. Rejected as usage errors.

@test "usage: --provenance carried is rejected, no marker written" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance carried
  [ "$status" -eq 2 ]
  # AUDIT_DIRECTORY may not even exist (the writer fails before mkdir -p); `find` on
  # a missing dir exits non-zero, so guard with `|| true` under bats' set -e.
  leftover="$(find "$AUDIT_DIRECTORY" -name '*.carried' 2>/dev/null || true)"
  [ -z "$leftover" ]
}

@test "usage: --anchor-tree is rejected as an unrecognized argument" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --anchor-tree "$TREE"
  [ "$status" -eq 2 ]
}

@test "usage: an invalid --provenance exits 2" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance bogus
  [ "$status" -eq 2 ]
}

# Fail-closed: the digest must derive, or nothing is written (SC7/UAT-013).

@test "fails closed (exit non-zero, no marker) when the digest cannot be derived" {
  sha256sum() { return 1; }
  shasum() { return 1; }
  export -f sha256sum shasum
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned
  [ "$status" -ne 0 ]
  # AUDIT_DIRECTORY may not even exist (the writer fails before mkdir -p); `find` on
  # a missing dir exits non-zero, so guard with `|| true` under bats' set -e.
  leftover="$(find "$AUDIT_DIRECTORY" -name '*.ok' 2>/dev/null || true)"
  [ -z "$leftover" ]
}

@test "an earned write replaces a stale body at the same digest path" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  mkdir -p "$AUDIT_DIRECTORY"
  printf '{"sha":"old","tree":"%s","audited_at":"1999-01-01T00:00:00Z"}\n' "$TREE" > "$AUDIT_DIRECTORY/${digest}.ok"

  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.ok" ]
  [ "$(jq -r .provenance "$AUDIT_DIRECTORY/${digest}.ok")" = "earned" ]
  [ "$(jq -r .schema "$AUDIT_DIRECTORY/${digest}.ok")" = "4" ]
  [ "$(jq -r .digest "$AUDIT_DIRECTORY/${digest}.ok")" = "$digest" ]
}

# Refusals: a first-class, digest-keyed artifact; not evidence-gated

@test "refusal: --provenance refused lands at the digest-keyed .refused filename" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused)"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.${member}.refused" ]
  [ "$(jq -r .provenance "$written_path")" = "refused" ]
  [ "$(jq -r .member "$written_path")" = "$member" ]
  [ "$(jq -r .digest "$written_path")" = "$digest" ]
  [ "$(jq -r .tree "$written_path")" = "$TREE" ]

  # The default member's refusal carries no member infix.
  frontend_digest="$(member_digest "$ROOT" code-audit-frontend)"
  second_written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance refused)"
  [ "$second_written_path" = "$AUDIT_DIRECTORY/${frontend_digest}.refused" ]
}

@test "clearance_member_refused matches a writer-produced refusal for the exact digest" {
  # shellcheck source=/dev/null
  . "$READER"
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused >/dev/null
  clearance_member_refused "$ROOT" "$digest" "$member"

  # A digest mismatch does not match.
  clearance_member_refused "$ROOT" "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "$member" && return 1

  # An earned marker for a different member+digest is not a refusal.
  frontend_digest="$(member_digest "$ROOT" code-audit-frontend)"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$frontend_digest" >/dev/null
  clearance_member_refused "$ROOT" "$frontend_digest" code-audit-frontend && return 1
  return 0
}

# Reader: clearance_member_cleared is earned-only, no carried fallback
# (the .carried family and clearance_carried_path no longer exist).

@test "structural: clearance_carried_path is deleted from the reader" {
  # shellcheck source=/dev/null
  . "$READER"
  command -v clearance_carried_path >/dev/null 2>&1 && return 1
  return 0
}

@test "clearance_member_cleared: earned only, no carried fallback" {
  # shellcheck source=/dev/null
  . "$READER"
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  # Not cleared before any write.
  clearance_member_cleared "$ROOT" "$digest" code-audit-frontend && return 1

  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest" >/dev/null
  clearance_member_cleared "$ROOT" "$digest" code-audit-frontend

  # A refusal for a DIFFERENT member+digest never makes that member cleared.
  node_digest="$(member_digest "$ROOT" code-audit-maintainer-node)"
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused >/dev/null
  clearance_member_cleared "$ROOT" "$node_digest" code-audit-maintainer-node && return 1
  return 0
}

# Acceptance, end to end: the reader accepts writer-produced earned markers
# only, matched to the exact digest and member (UAT-007).

@test "acceptance: a writer-produced earned marker satisfies clearance_acceptable; legacy, digest-mismatch, member-mismatch, refused do not" {
  # shellcheck source=/dev/null
  . "$READER"
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest" >/dev/null
  marker="$AUDIT_DIRECTORY/${digest}.ok"

  clearance_acceptable "$marker" code-audit-frontend "$digest"

  # A hand-written legacy body (no .digest field) does NOT satisfy the reader.
  printf '{"sha":"x","tree":"%s","audited_at":"z"}\n' "$TREE" > "$AUDIT_DIRECTORY/legacy.ok"
  clearance_acceptable "$AUDIT_DIRECTORY/legacy.ok" code-audit-frontend "$digest" && return 1

  # A digest mismatch does NOT satisfy the reader.
  clearance_acceptable "$marker" code-audit-frontend "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" && return 1

  # A member mismatch does NOT satisfy the reader.
  clearance_acceptable "$marker" code-audit-maintainer-shell "$digest" && return 1

  # A refused body does NOT satisfy clearance_acceptable (earned only).
  node_digest="$(member_digest "$ROOT" code-audit-maintainer-node)"
  refused_marker_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused)"
  clearance_acceptable "$refused_marker_path" code-audit-maintainer-node "$node_digest" && return 1

  return 0
}

@test "jq absent: clearance_acceptable and clearance_member_refused fail closed, never bare-existence" {
  # shellcheck source=/dev/null
  . "$READER"
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest" >/dev/null
  marker="$AUDIT_DIRECTORY/${digest}.ok"
  [ -f "$marker" ]

  node_digest="$(member_digest "$ROOT" code-audit-maintainer-node)"
  refused_marker_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused)"
  [ -f "$refused_marker_path" ]

  emptybin="$BATS_TEST_TMPDIR/emptybin"
  mkdir -p "$emptybin"
  OLDPATH="$PATH"
  PATH="$emptybin"
  if command -v jq >/dev/null 2>&1; then
    PATH="$OLDPATH"
    skip "could not simulate jq absence on this PATH"
  fi

  acceptable_status=0
  clearance_acceptable "$marker" code-audit-frontend "$digest" || acceptable_status=$?
  refused_status=0
  clearance_member_refused "$ROOT" "$node_digest" code-audit-maintainer-node || refused_status=$?

  PATH="$OLDPATH"

  [ "$acceptable_status" -eq 1 ]
  [ "$refused_status" -eq 1 ]
}

# The adopter shape. The release scrub strips the maintainer-only blocks; the
# roster collapses to the single default member, and the shipped writer
# produces a valid digest-keyed marker with no maintainer member.

# Strips maintainer-only blocks from the file named by $1, writing the result to
# stdout, as the bundle-time scrub does to shipped files.
#
# This awk is a hand-kept model of the shipped parser (`stripMarkerBlocks` in
# `.gaia/cli/src/release/marker-strip.ts`), not held to it by a test. Two
# sibling suites carry the same block (`verify-audit-roster.bats`,
# `.gaia/tests/statusline/statusline-worktree.bats`), so a change here belongs
# in all of them, and in the real parser too if the transform it models changed.
#
# The unanchored `/gaia:maintainer-only:start/` pair this replaces was a third
# marker vocabulary: it fired on the HTML-comment form too, which the transform
# governing shell files does not use. The constants above are the ones that
# transform declares.
scrub_maintainer_only() {
  awk -v marker_start="$MAINTAINER_START" -v marker_end="$MAINTAINER_END" '
    {
      has_start = index($0, marker_start) > 0
      has_end = index($0, marker_end) > 0
      if (!skip && has_start) { if (!has_end) skip = 1; next }
      if (skip) { if (has_end) skip = 0; next }
      print
    }
  ' "$1"
}

@test "UAT-021: adopter shape collapses the roster and the shipped writer produces a valid digest-keyed marker" {
  ADOPTER="$BATS_TEST_TMPDIR/adopter"
  mkdir -p "$ADOPTER/.gaia/scripts"
  printf '1.6.1\n' > "$ADOPTER/.gaia/VERSION"

  # Base commit on main.
  git -C "$ADOPTER" init --quiet --initial-branch=main
  git -C "$ADOPTER" config user.email "test@example.com"
  git -C "$ADOPTER" config user.name "Test"
  git -C "$ADOPTER" config commit.gpgsign false
  echo "# readme" > "$ADOPTER/README.md"
  git -C "$ADOPTER" add .gaia/VERSION README.md
  git -C "$ADOPTER" commit --quiet -m "init"

  # Feature branch with an app/ change (owned by the default member).
  git -C "$ADOPTER" checkout --quiet -b feature
  mkdir -p "$ADOPTER/frontend/app"
  echo "export const x = 1;" > "$ADOPTER/frontend/app/x.ts"
  git -C "$ADOPTER" add frontend/app/x.ts
  git -C "$ADOPTER" commit --quiet -m "feat: x"

  # Provision the adopter shape (all UNTRACKED, so they never join the diff):
  #  1. scrub the maintainer-only block from the roster config,
  #  2. copy the resolver through the same scrub the release applies, and
  #  3. omit the two maintainer agent definitions.
  scrub_maintainer_only "$THIS_DIRECTORY/../../audit-ci.yml" > "$ADOPTER/.gaia/audit-ci.yml"
  scrub_maintainer_only "$RESOLVER" > "$ADOPTER/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$ADOPTER/.gaia/scripts/resolve-audit-members.sh"
  cp "$WRITER" "$ADOPTER/.gaia/scripts/audit-write-clearance.sh"
  chmod +x "$ADOPTER/.gaia/scripts/audit-write-clearance.sh"

  # The writer copy resolves its digest lib relative to ITSELF
  # ($ADOPTER/.claude/hooks/lib/), and the resolver copy resolves its
  # ownership classifier the same way, so provision both there. The scrubbed
  # .gaia/audit-ci.yml (written above) drives the adopter roster.
  _library_directory="$(dirname "$READER")"
  mkdir -p "$ADOPTER/.claude/hooks/lib"
  cp "$_library_directory/audit-scope.sh" "$ADOPTER/.claude/hooks/lib/audit-scope.sh"
  cp "$_library_directory/audit-machinery.sh" "$ADOPTER/.claude/hooks/lib/audit-machinery.sh"
  cp "$_library_directory/audit-clearance.sh" "$ADOPTER/.claude/hooks/lib/audit-clearance.sh"
  cp "$DIGEST_LIBRARY" "$ADOPTER/.claude/hooks/lib/audit-digest.sh"
  cp "$_library_directory/audit-base-provenance.sh" "$ADOPTER/.claude/hooks/lib/audit-base-provenance.sh"

  # The roster really did collapse: a .gaia/**/*.sh change (which the scrubbed-
  # away maintainer-shell member would own) resolves to NOBODY now.
  echo "#!/bin/bash" > "$ADOPTER/.gaia/scripts/probe.sh"
  git -C "$ADOPTER" add .gaia/scripts/probe.sh
  git -C "$ADOPTER" commit --quiet -m "probe"
  set_after_probe="$( cd "$ADOPTER" && bash .gaia/scripts/resolve-audit-members.sh )"
  grep -qF "code-audit-maintainer-shell" <<<"$set_after_probe" && return 1
  # Undo the probe so the diff under test is app/ only again.
  git -C "$ADOPTER" reset --quiet --hard HEAD~1

  # The default member alone is dispatched for the app/ diff.
  members="$( cd "$ADOPTER" && bash .gaia/scripts/resolve-audit-members.sh )"
  [ "$members" = "code-audit-frontend" ]

  # The shipped writer writes the default member's digest-keyed marker.
  adopter_digest="$(member_digest "$ADOPTER" code-audit-frontend)"
  written_path="$( cd "$ADOPTER" && bash .gaia/scripts/audit-write-clearance.sh \
    --root "$ADOPTER" --member code-audit-frontend --provenance earned --scope-digest "$adopter_digest" )"
  [ "$written_path" = "$ADOPTER/.gaia/local/audit/${adopter_digest}.ok" ]
  [ -f "$written_path" ]
  [ "$(jq -r .schema "$written_path")" = "4" ]
  [ "$(jq -r .digest "$written_path")" = "$adopter_digest" ]
  [ "$(jq -r .member "$written_path")" = "code-audit-frontend" ]
}

# --supersede-refusal: a member's explicit, reasoned reversal of its OWN prior
# same-digest refusal.
#
# The earned and refused families live at DIFFERENT filenames, so an earned
# write alone leaves a refusal on disk and the gate (which checks the refusal
# family first) stays shut forever. Superseding is the authored exit. The
# anti-gaming invariant is the second test below: a PLAIN earned write must
# never clear a refusal, or refusal-precedence decays into "newest marker
# wins" and re-running an auditor until it passes becomes a merge bypass.

@test "supersede: earned + --supersede-refusal removes the sibling refusal and records the reason" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  refused="$AUDIT_DIRECTORY/${digest}.${member}.refused"
  reason="operator acknowledged the Important with a stated reason"

  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused >/dev/null
  [ -f "$refused" ] || return 1

  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --supersede-refusal "$reason")"

  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
  [ "$(jq -r .provenance "$written_path")" = "earned" ]
  # The refusal is gone, so the gate has nothing left to find.
  [ ! -f "$refused" ]
  # The reversal stays auditable in the earned body.
  [ "$(jq -r .supersedes.provenance "$written_path")" = "refused" ]
  [ "$(jq -r .supersedes.reason "$written_path")" = "$reason" ]
  [ "$(jq -r .supersedes.superseded_at "$written_path")" = "$(jq -r .audited_at "$written_path")" ]
}

@test "supersede: ANTI-GAMING, a plain earned write never clears a same-digest refusal" {
  # shellcheck source=/dev/null
  . "$READER"
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  refused="$AUDIT_DIRECTORY/${digest}.${member}.refused"

  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused >/dev/null
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned --scope-digest "$digest")"

  # Both artifacts coexist, and no supersedes block is recorded.
  [ -f "$refused" ] || return 1
  [ -f "$written_path" ] || return 1
  jq -e '.supersedes == null' "$written_path" >/dev/null || return 1

  # The refusal still reads live: re-running an auditor until it passes must
  # NOT open the gate. Final command, so its status decides the test.
  clearance_member_refused "$ROOT" "$digest" "$member"
}

@test "supersede: rejected with --provenance refused, and no marker is written" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused \
    --supersede-refusal "a refusal supersedes nothing"
  [ "$status" -eq 2 ]
  grep -qF -- "valid only with --provenance earned" <<<"$output" || return 1
  [ ! -f "$AUDIT_DIRECTORY/${digest}.${member}.refused" ]
  [ ! -f "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
}

@test "supersede: an empty or whitespace-only reason is a usage error" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"

  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned --supersede-refusal ""
  [ "$status" -eq 2 ]
  grep -qF -- "non-empty reason" <<<"$output" || return 1

  # Whitespace is not a reason either: supersession must stay auditable.
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned --supersede-refusal "   "
  [ "$status" -eq 2 ]
  [ ! -f "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
}

@test "supersede: ORDERING, the earned marker publishes before the refusal is removed" {
  # Crash-safety invariant: an interruption between the publish and the removal
  # must leave BOTH artifacts on disk, so the gate stays shut (the refusal
  # still outranks), never neither. Removing first would open a window where no
  # clearance of either provenance exists and the refusal record, which is the
  # anti-gaming evidence, is already gone.
  #
  # This is pinned STRUCTURALLY on purpose: swapping the two statements leaves
  # every behavioural supersede test above green, so only the order itself can
  # catch a future reorder. Matches this suite's existing structural checks.
  publish_line="$(grep -nF 'mv -f "$temporary_file" "$target"' "$WRITER" | head -1 | cut -d: -f1)"
  remove_line="$(grep -nF 'rm -f "$refused_path"' "$WRITER" | head -1 | cut -d: -f1)"
  [ -n "$publish_line" ] || return 1
  [ -n "$remove_line" ] || return 1
  [ "$publish_line" -lt "$remove_line" ]
}

@test "supersede: with no refusal on disk the earned write is a plain idempotent write" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --scope-digest "$digest" --supersede-refusal "nothing on disk to supersede")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
  [ "$(jq -r .provenance "$written_path")" = "earned" ]
  # No sibling refusal existed, so no supersedes block is recorded.
  jq -e '.supersedes == null' "$written_path" >/dev/null
}

# ========== the narrowed supersede operand, pinned ==========
#
# The gate exempts --supersede-refusal from the staleness comparison only
# when a sibling refusal is actually on disk. Widening that operand back to
# the flag-only form reds "supersede: no refusal on disk, a mismatched
# --scope-digest refuses" and "supersede: no refusal on disk, an absent
# --scope-digest refuses by its own token": both call the flag with nothing to
# supersede, so a flag-only gate skips the comparison outright and each
# publishes instead of refusing. The surviving two-call route below stays
# green either way, because it writes a real refusal first and a widened
# operand never reaches that path.

@test "supersede: no refusal on disk, a mismatched --scope-digest refuses" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  stale="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --supersede-refusal "nothing on disk to supersede" --scope-digest "$stale"
  [ "$status" -eq 2 ]
  grep -qF -- "review scope superseded" <<<"$output" || return 1
  grep -qF -- "$stale" <<<"$output" || return 1
  grep -qF -- "$digest" <<<"$output" || return 1
  [ ! -f "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
}

@test "supersede: no refusal on disk, an absent --scope-digest refuses by its own token" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --supersede-refusal "nothing on disk to supersede"
  [ "$status" -eq 2 ]
  grep -qF -- "scope digest not supplied" <<<"$output" || return 1
  grep -qF -- "review scope superseded" <<<"$output" && return 1
  [ ! -f "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
}

@test "supersede: the surviving two-call route publishes a supersedes block naming the reason and the time" {
  # The narrowing does not make a stale-scope marker unreachable: writing a
  # refusal and then superseding it with a mismatched digest still reaches an
  # .ok marker. What it buys is that the route cannot be taken silently -- the
  # refusal has to exist on disk first, and the body it publishes records who
  # superseded it, why, and when.
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  refused="$AUDIT_DIRECTORY/${digest}.${member}.refused"
  reason="operator accepted the tradeoff after review"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused >/dev/null
  [ -f "$refused" ] || return 1

  stale="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --supersede-refusal "$reason" --scope-digest "$stale")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
  [ ! -f "$refused" ]
  [ "$(jq -r .supersedes.provenance "$written_path")" = "refused" ]
  [ "$(jq -r .supersedes.reason "$written_path")" = "$reason" ]
  [ "$(jq -r .supersedes.superseded_at "$written_path")" = "$(jq -r .audited_at "$written_path")" ]
}

# Re-run carry-forward ledger (--base)
#
# The ledger is what makes a refusal self-describing. A refusal blocks a merge
# and is retired only by its own author, so an operator who cannot learn what
# was refused can neither repair it nor legitimately supersede it. These tests
# pin that a refusal writes a ledger carrying the actionable detail, that the
# ledger is derived from the member's own findings sidecar, and that it never
# gets in the way of the marker write it rides along with.

# ledger_setup: a base commit, a branch off it, and the audit key both artifacts
# share. Sets LEDGER_BASE_SHA, LEDGER, and defines sidecar_for.
ledger_setup() {
  LEDGER_BASE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  git -C "$ROOT" checkout --quiet -b "fix/ledger"
  echo "more" >> "$ROOT/README.md"
  git -C "$ROOT" add README.md
  git -C "$ROOT" commit --quiet -m "work"
  LEDGER_HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  # gaia_key_slug percent-encodes "/" as "%2F".
  LEDGER="$AUDIT_DIRECTORY/${LEDGER_BASE_SHA}.fix%2Fledger.rerun.json"
}

# finding_json <line> [<severity>] [<entry_id>] [<finding_class>]: one complete
# finding object. A non-empty entry_id makes it a re-report of that open entry.
finding_json() {
  jq -cn --argjson line "$1" --arg severity "${2:-warning}" --arg entry_id "${3:-}" \
    --arg finding_class "${4:-holistic/secret-exposure}" '
    {finding_class: $finding_class, severity: $severity,
     path: ".claude/hooks/block-secrets-write.sh", line: $line,
     title: "the path arm admits arbitrary trailing text",
     failure_mode: "a separator after the closing brace unbounds the tail over the secret character set",
     verified_by: "ran the hook at base and at HEAD: base denies, HEAD allows",
     suggested_fix: "bound each trailing segment"}
    + (if $entry_id != "" then {entry_id: $entry_id} else {} end)'
}

# write_findings_sidecar <member> <findings-array> [<resolutions-array>]: the
# member's sidecar at the ledger key, through the real findings writer.
write_findings_sidecar() {
  local member="$1" findings="$2" resolutions="${3:-}"
  local writer="$THIS_DIRECTORY/../audit-write-findings.sh"
  [ -x "$writer" ] || skip "audit-write-findings.sh not executable"
  if [ -n "$resolutions" ]; then
    printf '%s' "$resolutions" > "$BATS_TEST_TMPDIR/resolutions.json"
    printf '%s' "$findings" | bash "$writer" --root "$ROOT" --member "$member" --base "$LEDGER_BASE_SHA" \
      --findings - --resolutions "$BATS_TEST_TMPDIR/resolutions.json" >/dev/null
  else
    printf '%s' "$findings" | bash "$writer" --root "$ROOT" --member "$member" --base "$LEDGER_BASE_SHA" \
      --findings - >/dev/null
  fi
}

# write_sidecar_for <member> <line> [<severity>] [<entry_id>]: a complete
# one-finding sidecar; with an entry_id it re-reports that open entry.
write_sidecar_for() {
  write_findings_sidecar "$1" "[$(finding_json "$2" "${3:-warning}" "${4:-}")]"
}

# open_entry_id <member> [<index>]: the entry_id of that member's open ledger
# entry at that position, failing when there is none.
open_entry_id() {
  local entry_identifier
  entry_identifier="$(jq -r --arg member "$1" --argjson index "${2:-0}" \
    '[.remaining[] | select(.member == $member)][$index].entry_id // empty' "$LEDGER")"
  [ -n "$entry_identifier" ] || return 1
  printf '%s\n' "$entry_identifier"
}

# rereport_all_open <member>: a sidecar re-reporting every open entry of the
# member by its entry_id, the way a member whose findings all still stand does.
rereport_all_open() {
  local findings
  findings="$(jq -c --arg member "$1" '[.remaining[] | select(.member == $member)
    | {finding_class, path, line, title, failure_mode, verified_by, suggested_fix, entry_id,
       severity: ({"critical":"error","important":"warning","suggestion":"suggestion"}[.severity] // "warning")}]' "$LEDGER")"
  write_findings_sidecar "$1" "$findings"
}

# resolve_all_open <member> [<rationale>]: a sidecar with no findings that
# resolves every open entry of the member.
resolve_all_open() {
  local resolutions
  resolutions="$(jq -c --arg member "$1" --arg rationale "${2:-bounded the trailing segment}" \
    '[.remaining[] | select(.member == $member) | {entry_id, rationale: $rationale}]' "$LEDGER")"
  write_findings_sidecar "$1" '[]' "$resolutions"
}

@test "ledger: a refusal with --base writes the carry-forward ledger from the findings sidecar" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ -f "$LEDGER" ]
  [ "$(jq -r .schema "$LEDGER")" = "1" ]
  [ "$(jq -r .base_sha "$LEDGER")" = "$LEDGER_BASE_SHA" ]
  [ "$(jq -r .branch "$LEDGER")" = "fix/ledger" ]
  [ "$(jq -r .head_sha "$LEDGER")" = "$LEDGER_HEAD_SHA" ]
  [ "$(jq -r .round "$LEDGER")" = "1" ]
  [ "$(jq '.remaining | length' "$LEDGER")" = "1" ]
}

@test "ledger: every actionable field reaches remaining[], so the refusal briefs its own repair" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  entry="$(jq -c '.remaining[0]' "$LEDGER")"
  [ "$(jq -r .member <<<"$entry")" = "$member" ]
  [ "$(jq -r .path <<<"$entry")" = ".claude/hooks/block-secrets-write.sh" ]
  [ "$(jq -r .line <<<"$entry")" = "113" ]
  [ "$(jq -r .finding_class <<<"$entry")" = "holistic/secret-exposure" ]
  grep -qF "unbounds the tail" <<<"$(jq -r .failure_mode <<<"$entry")"
  grep -qF "base denies, HEAD allows" <<<"$(jq -r .verified_by <<<"$entry")"
  grep -qF "bound each trailing segment" <<<"$(jq -r .suggested_fix <<<"$entry")"
  [ "$(jq -r .first_seen_round <<<"$entry")" = "1" ]
}

@test "ledger: the sidecar's severity scale is mapped onto the ledger's" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113 error
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq -r '.remaining[0].severity' "$LEDGER")" = "critical" ]

  write_sidecar_for "$member" 113 warning "$(open_entry_id "$member")"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq -r '.remaining[0].severity' "$LEDGER")" = "important" ]

  write_sidecar_for "$member" 113 suggestion "$(open_entry_id "$member")"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq -r '.remaining[0].severity' "$LEDGER")" = "suggestion" ]
}

@test "ledger: round increments across refusals and first_seen_round carries" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  rereport_all_open "$member"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  rereport_all_open "$member"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq -r .round "$LEDGER")" = "3" ]
  # The finding has been open since round 1 and says so.
  [ "$(jq -r '.remaining[0].first_seen_round' "$LEDGER")" = "1" ]
  [ "$(jq -r '.remaining[0].entry_id' "$LEDGER")" = "r1-1" ]
}

@test "ledger: an open finding the sidecar omits refuses the write with exit 3, never closes silently" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq '.remaining | length' "$LEDGER")" = "1" ]
  open_identifier="$(open_entry_id "$member")"
  [ -n "$open_identifier" ]
  cp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  # Round two: the member still refuses, but its report names only a different
  # finding and says nothing about the open one.
  write_sidecar_for "$member" 59
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA"
  [ "$status" -eq 3 ]
  grep -qF -- "   ${open_identifier}  " <<<"$output" || return 1
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
}

@test "ledger: a resolved open finding closes into fixed_last_round with its resolution" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  open_identifier="$(open_entry_id "$member")"
  [ -n "$open_identifier" ]
  # Round two: the member still refuses on a different finding, and accounts
  # for the open one with a resolution.
  write_findings_sidecar "$member" "[$(finding_json 59)]" \
    "[{\"entry_id\":\"${open_identifier}\",\"rationale\":\"bounded the trailing segment\"}]"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq '.remaining | length' "$LEDGER")" = "1" ]
  [ "$(jq -r '.remaining[0].line' "$LEDGER")" = "59" ]
  # A new finding starts its own clock, under an id of its own round.
  [ "$(jq -r '.remaining[0].first_seen_round' "$LEDGER")" = "2" ]
  [ "$(jq -r '.remaining[0].entry_id' "$LEDGER")" = "r2-1" ]
  [ "$(jq '.fixed_last_round | length' "$LEDGER")" = "1" ]
  [ "$(jq -r '.fixed_last_round[0].entry_id' "$LEDGER")" = "$open_identifier" ]
  [ "$(jq -r '.fixed_last_round[0].resolution' "$LEDGER")" = "bounded the trailing segment" ]
  [ "$(jq -r '.fixed_last_round[0].line' "$LEDGER")" = "113" ]
}

@test "ledger: one member's write never touches a co-dispatched member's entries" {
  ledger_setup
  write_sidecar_for code-audit-maintainer-shell 113
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  write_sidecar_for code-audit-maintainer-node 7
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq '.remaining | length' "$LEDGER")" = "2" ]
  [ "$(jq '[.remaining[] | select(.member == "code-audit-maintainer-shell")] | length' "$LEDGER")" = "1" ]
  [ "$(jq '[.remaining[] | select(.member == "code-audit-maintainer-node")] | length' "$LEDGER")" = "1" ]
}

@test "ledger: an earned write retires that member's entries into fixed_last_round" {
  ledger_setup
  write_sidecar_for code-audit-maintainer-shell 113
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  write_sidecar_for code-audit-maintainer-node 7
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null

  # Supersede, not a plain earned write: this member's own refusal is live, and
  # retiring its entries beneath a live refusal would claim a repair no commit
  # made. Superseding removes the refusal first, which is what legitimately ends
  # the loop. The plain-earned case is pinned by its own test below.
  open_identifier="$(open_entry_id code-audit-maintainer-shell)"
  [ -n "$open_identifier" ]
  resolve_all_open code-audit-maintainer-shell "operator accepted the tradeoff"
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance earned --base "$LEDGER_BASE_SHA" \
    --supersede-refusal "operator accepted the tradeoff" >/dev/null
  [ -f "$LEDGER" ]
  # The cleared member is gone from remaining; the other member survives.
  [ "$(jq '[.remaining[] | select(.member == "code-audit-maintainer-shell")] | length' "$LEDGER")" = "0" ]
  [ "$(jq '[.remaining[] | select(.member == "code-audit-maintainer-node")] | length' "$LEDGER")" = "1" ]
  [ "$(jq -r '.fixed_last_round[0].member' "$LEDGER")" = "code-audit-maintainer-shell" ]
  [ "$(jq -r '.fixed_last_round[0].line' "$LEDGER")" = "113" ]
  [ "$(jq -r '.fixed_last_round[0].fixed_in_sha' "$LEDGER")" = "$LEDGER_HEAD_SHA" ]
  [ "$(jq -r '.fixed_last_round[0].entry_id' "$LEDGER")" = "$open_identifier" ]
  [ "$(jq -r '.fixed_last_round[0].resolution' "$LEDGER")" = "operator accepted the tradeoff" ]
  # The retired member leaves no provenance to anchor on; the other keeps its own.
  [ "$(jq -r '.member_provenance | has("code-audit-maintainer-shell")' "$LEDGER")" = "false" ]
  [ "$(jq -r '.member_provenance | has("code-audit-maintainer-node")' "$LEDGER")" = "true" ]
}

@test "ledger: the file is removed only once NO member has anything left" {
  ledger_setup
  write_sidecar_for code-audit-maintainer-shell 113
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  write_sidecar_for code-audit-maintainer-node 7
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null

  resolve_all_open code-audit-maintainer-shell
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance earned --base "$LEDGER_BASE_SHA" \
    --supersede-refusal "operator accepted the tradeoff" >/dev/null
  [ -f "$LEDGER" ]
  resolve_all_open code-audit-maintainer-node
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance earned --base "$LEDGER_BASE_SHA" \
    --supersede-refusal "operator accepted the tradeoff" >/dev/null
  [ -f "$LEDGER" ] && return 1
  return 0
}

@test "ledger: a plain earned write beside a live refusal leaves the briefing intact" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq '.remaining | length' "$LEDGER")" = "1" ]

  # A plain earned write never clears a live refusal, so the merge is still
  # blocked on this finding. Retiring it here would stamp fixed_in_sha on a
  # repair no commit made and then delete the only briefing that can clear the
  # block, which is the exact opaque-refusal state this channel exists to end.
  # The member re-reports the finding, so the write is accounted and reaches
  # the retirement gate this test is about.
  rereport_all_open "$member"
  digest="$(member_digest "$ROOT" "$member")"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned --base "$LEDGER_BASE_SHA" --scope-digest "$digest" >/dev/null

  [ -f "$LEDGER" ]
  [ "$(jq '.remaining | length' "$LEDGER")" = "1" ]
  [ "$(jq -r '.remaining[0].line' "$LEDGER")" = "113" ]
  [ "$(jq '.fixed_last_round | length' "$LEDGER")" = "0" ]
}

@test "ledger: a repair rotates the digest, and the plain earned write then retires" {
  ledger_setup
  write_sidecar_for code-audit-maintainer-shell 113
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  write_sidecar_for code-audit-maintainer-node 7
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  old_digest="$(member_digest "$ROOT" code-audit-maintainer-shell)"

  # The documented primary exit: repairing the finding edits content the member
  # covers, which rotates its digest, so no refusal exists at the new key and
  # nothing needs superseding. This is the arm the gate must NOT block; pinning
  # it is what stops the gate from being narrowed to "only a supersede retires".
  printf '1.6.2\n' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "repair"
  new_digest="$(member_digest "$ROOT" code-audit-maintainer-shell)"
  [ "$new_digest" != "$old_digest" ]
  [ -f "$AUDIT_DIRECTORY/${old_digest}.code-audit-maintainer-shell.refused" ]
  [ -f "$AUDIT_DIRECTORY/${new_digest}.code-audit-maintainer-shell.refused" ] && return 1

  resolve_all_open code-audit-maintainer-shell
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance earned --base "$LEDGER_BASE_SHA" --scope-digest "$new_digest" >/dev/null

  [ -f "$LEDGER" ]
  [ "$(jq '[.remaining[] | select(.member == "code-audit-maintainer-shell")] | length' "$LEDGER")" = "0" ]
  [ "$(jq '[.remaining[] | select(.member == "code-audit-maintainer-node")] | length' "$LEDGER")" = "1" ]
  [ "$(jq -r '.fixed_last_round[0].member' "$LEDGER")" = "code-audit-maintainer-shell" ]
  [ "$(jq -r '.fixed_last_round[0].line' "$LEDGER")" = "113" ]
}

@test "ledger: two findings sharing a line do not double remaining[] each round" {
  ledger_setup
  member="code-audit-maintainer-shell"
  # Two distinct defects on one line, same finding_class: the findings writer
  # permits this, and the carry-forward must match one prior entry per finding
  # (by entry_id) rather than binding a generator that re-emits the body per match.
  printf '[{"finding_class":"holistic/unclassified","severity":"warning","path":".gaia/scripts/a.sh","line":42,"title":"first defect","failure_mode":"the guard admits an empty value","verified_by":"ran it at base and at HEAD","suggested_fix":"reject an empty value"},{"finding_class":"holistic/unclassified","severity":"warning","path":".gaia/scripts/a.sh","line":42,"title":"second defect","failure_mode":"the same line also swallows stderr","verified_by":"stubbed the program to exit non-zero","suggested_fix":"check the status"}]' \
    | bash "$THIS_DIRECTORY/../audit-write-findings.sh" --root "$ROOT" --member "$member" --base "$LEDGER_BASE_SHA" --findings - >/dev/null

  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq '.remaining | length' "$LEDGER")" = "2" ]
  rereport_all_open "$member"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq '.remaining | length' "$LEDGER")" = "2" ]
  rereport_all_open "$member"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq '.remaining | length' "$LEDGER")" = "2" ]
  # Both have been open since round 1 and say so, each under its own id.
  [ "$(jq -c '[.remaining[].first_seen_round] | sort' "$LEDGER")" = "[1,1]" ]
  [ "$(jq -c '[.remaining[].entry_id] | sort' "$LEDGER")" = '["r1-1","r1-2"]' ]
}

@test "ledger: a stale ledger (different base) is replaced, never extended" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  # Rewrite the on-disk ledger to claim a different base; the writer must not
  # inherit its round or its entries.
  jq '.base_sha = "0000000000000000000000000000000000000000" | .round = 9' "$LEDGER" > "$LEDGER.tmp"
  mv "$LEDGER.tmp" "$LEDGER"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq -r .round "$LEDGER")" = "1" ]
  [ "$(jq -r .base_sha "$LEDGER")" = "$LEDGER_BASE_SHA" ]
}

@test "ledger: omitting --base leaves behavior exactly as before, no ledger written" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused)"
  digest="$(member_digest "$ROOT" "$member")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.${member}.refused" ]
  [ -f "$LEDGER" ] && return 1
  return 0
}

@test "ledger: a refusal with NO sidecar still writes the marker, and says the briefing is missing" {
  ledger_setup
  member="code-audit-maintainer-shell"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA"
  [ "$status" -eq 0 ]
  grep -qF "no findings sidecar" <<<"$output"
  digest="$(member_digest "$ROOT" "$member")"
  [ -f "$AUDIT_DIRECTORY/${digest}.${member}.refused" ]
  [ -f "$LEDGER" ] && return 1
  return 0
}

@test "ledger: an unresolvable audit key warns and never fails the marker write" {
  ledger_setup
  member="code-audit-maintainer-shell"
  write_sidecar_for "$member" 113
  git -C "$ROOT" checkout --quiet --detach HEAD
  digest="$(member_digest "$ROOT" "$member")"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA"
  [ "$status" -eq 0 ]
  grep -qF "audit key does not resolve" <<<"$output"
  [ -f "$AUDIT_DIRECTORY/${digest}.${member}.refused" ]
}

@test "ledger: the marker is published BEFORE any ledger work, so a ledger failure cannot lose it" {
  # Structural. The marker is the gate artifact and the ledger is a briefing, so
  # the order is load-bearing: reversing it would let a ledger problem abort a
  # write that must always land. Every behavioural test above stays green under a
  # reorder, so only this can catch one.
  publish_line="$(grep -nF 'mv -f "$temporary_file" "$target"' "$WRITER" | head -1 | cut -d: -f1)"
  ledger_line="$(grep -nF 'Re-run carry-forward ledger (only with --base)' "$WRITER" | head -1 | cut -d: -f1)"
  [ -n "$publish_line" ] || return 1
  [ -n "$ledger_line" ] || return 1
  [ "$publish_line" -lt "$ledger_line" ]
}

@test "ledger: a jq failure while building it is surfaced, never silently swallowed" {
  # Both jq passes here once used `2>/dev/null || true`, which turned a real
  # program error into "there was nothing to write". The status is checked now.
  grep -qF 'cannot build the carry-forward ledger' "$WRITER"
  grep -qF 'cannot update the carry-forward ledger' "$WRITER"
}

# -----------------------------------------------------------------------------
# Open-finding accounting
#
# A member anchored on its own refusal reviews only the fixer's delta, which is
# sound only if no later write can drop a finding that refusal left open. Every
# write for a member with open ledger entries must re-report each one by its
# entry_id or resolve it with a rationale, checked before anything publishes,
# and an exit 3 leaves every artifact as it was.
#
# Every fixture keeps capture, sidecar, and ledger on one key: the sandbox has
# no hook libraries, so the writer's resolver degrades to `main`, and the
# derived key base is `git merge-base main HEAD`, which ledger_setup makes
# equal to LEDGER_BASE_SHA. A fixture that lost that equality would find no
# ledger and pass every accounting arm vacuously, so the fixture asserts it.
# -----------------------------------------------------------------------------

ACCOUNTING_MEMBER="code-audit-maintainer-shell"
SIBLING_MEMBER="code-audit-maintainer-node"

# capture_scope <member> [<extra capture flags>...]: this member's scope
# capture at the ledger key, through the real capture script.
capture_scope() {
  local member="$1"
  shift
  bash "$THIS_DIRECTORY/../audit-scope-digest.sh" --capture --recapture "$@" \
    --root "$ROOT" --member "$member" --base "$LEDGER_BASE_SHA" >/dev/null
}

# rotate_member_digest: a fixer commit that rotates every member's digest.
rotate_member_digest() {
  printf '%s\n' "${1:-1.6.2}" > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "fixer: ${1:-1.6.2}"
}

# accounting_fixture: the member refuses at A with two open entries (FIRST_ID,
# SECOND_ID) beside a sibling's own open entry; a fixer commit B rotates the
# member's digest (B_DIGEST); the round at B is captured on member-refusal.
accounting_fixture() {
  ledger_setup
  [ "$(git -C "$ROOT" merge-base main HEAD)" = "$LEDGER_BASE_SHA" ]
  member="$ACCOUNTING_MEMBER"
  write_findings_sidecar "$member" \
    "[$(finding_json 113 error),$(finding_json 59 warning "" holistic/swallowed-error)]"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  write_sidecar_for "$SIBLING_MEMBER" 7
  bash "$WRITER" --root "$ROOT" --member "$SIBLING_MEMBER" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  FIRST_ID="$(open_entry_id "$member" 0)"
  SECOND_ID="$(open_entry_id "$member" 1)"
  [ -n "$FIRST_ID" ]
  [ -n "$SECOND_ID" ]
  [ "$FIRST_ID" != "$SECOND_ID" ]
  A_DIGEST="$(member_digest "$ROOT" "$member")"
  rotate_member_digest
  B_DIGEST="$(member_digest "$ROOT" "$member")"
  [ "$A_DIGEST" != "$B_DIGEST" ]
  capture_scope "$member" --base-reason member-refusal
  [ "$(jq -r .base_reason "$AUDIT_DIRECTORY/${LEDGER_BASE_SHA}.fix%2Fledger.${member}.scope.json")" = "member-refusal" ]
  SIDECAR_PATH="$AUDIT_DIRECTORY/${LEDGER_BASE_SHA}.fix%2Fledger.${member}.findings.json"
}

# resolution_json <entry_id>...: a resolutions array with one record per id.
resolution_json() {
  local entry_identifier first=1
  printf '['
  for entry_identifier in "$@"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    jq -cn --arg entry_id "$entry_identifier" '{entry_id: $entry_id, rationale: "bounded the trailing segment"}'
  done
  printf ']'
}

# snapshot_ledger: a copy of the ledger to compare bytes against afterwards.
snapshot_ledger() {
  cp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
}

@test "accounting: an earned write that omits an open finding exits 3 and publishes nothing" {
  accounting_fixture
  write_findings_sidecar "$member" '[]' "$(resolution_json "$FIRST_ID")"
  snapshot_ledger

  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --base "$LEDGER_BASE_SHA" --scope-digest "$B_DIGEST"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ] && return 1
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  # The omitted entry is named; the accounted one never is.
  grep -qF -- "   ${SECOND_ID}  " <<<"$output" || return 1
  grep -qF -- "   ${FIRST_ID}  " <<<"$output" && return 1
  grep -qF "Recovery:" <<<"$output" || return 1
  grep -qF -- "--resolutions" <<<"$output" || return 1
  grep -qF ".claude/hooks/lib/audit-member-protocol.md" <<<"$output" || return 1

  # Control: accounting for the omitted entry is all it takes.
  write_findings_sidecar "$member" '[]' "$(resolution_json "$FIRST_ID" "$SECOND_ID")"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --base "$LEDGER_BASE_SHA" --scope-digest "$B_DIGEST"
  [ "$status" -eq 0 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ]
}

@test "accounting: an earned write resolving every open entry retires them with their ids and rationale" {
  accounting_fixture
  [ "$(jq -r --arg member "$member" '.member_provenance | has($member)' "$LEDGER")" = "true" ]
  write_findings_sidecar "$member" '[]' "$(resolution_json "$FIRST_ID" "$SECOND_ID")"

  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --base "$LEDGER_BASE_SHA" --scope-digest "$B_DIGEST"
  [ "$status" -eq 0 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ]
  [ "$(jq --arg member "$member" '[.remaining[] | select(.member == $member)] | length' "$LEDGER")" = "0" ]
  [ "$(jq -c --arg member "$member" '[.fixed_last_round[] | select(.member == $member) | .entry_id] | sort' "$LEDGER")" \
    = "$(jq -cn --arg first "$FIRST_ID" --arg second "$SECOND_ID" '[$first, $second] | sort')" ]
  [ "$(jq -r --arg member "$member" '[.fixed_last_round[] | select(.member == $member) | .resolution] | unique | .[]' "$LEDGER")" \
    = "bounded the trailing segment" ]
  [ "$(jq -r --arg member "$member" '.member_provenance | has($member)' "$LEDGER")" = "false" ]
}

@test "accounting: a refused write that drops an open finding exits 3; re-reporting it carries its id" {
  ledger_setup
  member="$ACCOUNTING_MEMBER"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  open_identifier="$(open_entry_id "$member")"
  [ -n "$open_identifier" ]
  rotate_member_digest
  b_digest="$(member_digest "$ROOT" "$member")"
  b_tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
  b_sha="$(git -C "$ROOT" rev-parse HEAD)"

  # The round at B finds a new defect and says nothing about the open one.
  write_findings_sidecar "$member" "[$(finding_json 40 warning "" holistic/swallowed-error)]"
  snapshot_ledger
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${b_digest}.${member}.refused" ] && return 1
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  grep -qF -- "   ${open_identifier}  " <<<"$output" || return 1

  # Control: the open finding re-reported by its id at a shifted line, plus the new one.
  write_findings_sidecar "$member" \
    "[$(finding_json 120 warning "$open_identifier"),$(finding_json 40 warning "" holistic/swallowed-error)]"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA"
  [ "$status" -eq 0 ]
  [ -f "$AUDIT_DIRECTORY/${b_digest}.${member}.refused" ]
  carried="$(jq -c --arg member "$member" --arg id "$open_identifier" \
    '.remaining[] | select(.member == $member and .entry_id == $id)' "$LEDGER")"
  [ "$(jq -r .line <<<"$carried")" = "120" ]
  [ "$(jq -r .first_seen_round <<<"$carried")" = "1" ]
  new_identifier="$(jq -r --arg member "$member" --arg id "$open_identifier" \
    '.remaining[] | select(.member == $member and .entry_id != $id) | .entry_id' "$LEDGER")"
  [ "$new_identifier" = "r2-1" ]
  [ "$(jq --arg member "$member" '[.remaining[] | select(.member == $member)] | length' "$LEDGER")" = "2" ]
  provenance="$(jq -c --arg member "$member" '.member_provenance[$member]' "$LEDGER")"
  [ "$(jq -r .refusal_digest <<<"$provenance")" = "$b_digest" ]
  [ "$(jq -r .refusal_tree <<<"$provenance")" = "$b_tree" ]
  [ "$(jq -r .refusal_sha <<<"$provenance")" = "$b_sha" ]
  [ "$(jq -r .version <<<"$provenance")" = "1.6.2" ]
}

@test "accounting: omitting --base and the sidecar's review flags never skips the check" {
  accounting_fixture
  # The sidecar is written without --review-base/--base-reason, and the earned
  # write carries no --base: only its --scope-digest.
  write_findings_sidecar "$member" '[]' "$(resolution_json "$FIRST_ID")"
  [ "$(jq -r 'has("review_base")' "$SIDECAR_PATH")" = "false" ]
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned --scope-digest "$B_DIGEST"
  [ "$status" -ne 0 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ] && return 1
  grep -qF -- "   ${SECOND_ID}  " <<<"$output" || return 1
}

@test "accounting: a round captured on member-refusal with no readable ledger exits 3, never an empty open set" {
  accounting_fixture
  write_findings_sidecar "$member" '[]' "$(resolution_json "$FIRST_ID" "$SECOND_ID")"

  rm -f "$LEDGER"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --base "$LEDGER_BASE_SHA" --scope-digest "$B_DIGEST"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ] && return 1
  grep -qF -- "audit-scope-digest.sh --release" <<<"$output" || return 1
  grep -qF "re-run the scope resolver" <<<"$output" || return 1

  printf 'not json {' > "$LEDGER"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --base "$LEDGER_BASE_SHA" --scope-digest "$B_DIGEST"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ] && return 1
  grep -qF -- "audit-scope-digest.sh --release" <<<"$output" || return 1
}

@test "accounting: a resolution whose rationale is blank leaves its entry unaccounted" {
  accounting_fixture
  # Hand-written: the findings writer itself rejects a blank rationale.
  jq -cn --arg member "$member" --arg first "$FIRST_ID" --arg second "$SECOND_ID" \
    '{schema: 1, member: $member, findings: [],
      resolutions: [{entry_id: $first, rationale: "bounded the trailing segment"},
                    {entry_id: $second, rationale: "   "}]}' > "$SIDECAR_PATH"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --base "$LEDGER_BASE_SHA" --scope-digest "$B_DIGEST"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ] && return 1
  grep -qF -- "   ${SECOND_ID}  " <<<"$output" || return 1
  grep -qF -- "   ${FIRST_ID}  " <<<"$output" && return 1
  true
}

@test "accounting: open entries with no sidecar refuse both a refused and an earned write" {
  accounting_fixture
  rm -f "$SIDECAR_PATH"
  snapshot_ledger

  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.refused" ] && return 1
  grep -qF "no readable findings sidecar" <<<"$output" || return 1

  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --base "$LEDGER_BASE_SHA" --scope-digest "$B_DIGEST"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ] && return 1
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
}

@test "accounting: a sibling's later refusal leaves this member's entries and provenance byte-identical" {
  accounting_fixture
  projection() {
    jq -S --arg member "$member" \
      '{remaining: [.remaining[] | select(.member == $member)], provenance: .member_provenance[$member]}' "$LEDGER"
  }
  before="$(projection)"
  [ "$(jq '.remaining | length' <<<"$before")" = "2" ]
  [ "$(jq -r '.provenance.refusal_digest' <<<"$before")" = "$A_DIGEST" ]

  rotate_member_digest 1.6.3
  rereport_all_open "$SIBLING_MEMBER"
  bash "$WRITER" --root "$ROOT" --member "$SIBLING_MEMBER" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq -r .round "$LEDGER")" = "3" ]
  [ "$(projection)" = "$before" ]
}

@test "accounting: a refusal records its review coverage only when its own capture matches it" {
  ledger_setup
  member="$ACCOUNTING_MEMBER"
  digest="$(member_digest "$ROOT" "$member")"

  # A capture of the write-time digest, on the resolved base.
  capture_scope "$member"
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused)"
  [ "$(jq -r '.review_coverage.scope_digest' "$written_path")" = "$digest" ]
  [ "$(jq -r .digest "$written_path")" = "$digest" ]

  # A capture on a caller-overridden base proves nothing about the resolved one.
  capture_scope "$member" --base-overridden
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused)"
  [ "$(jq -r 'has("review_coverage")' "$written_path")" = "false" ]

  # A capture taken before a commit that rotated the digest covers other content.
  capture_scope "$member"
  rotate_member_digest
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused)"
  [ "$(jq -r .digest "$written_path")" != "$digest" ]
  [ "$(jq -r 'has("review_coverage")' "$written_path")" = "false" ]

  # No capture at all.
  rm -f "$AUDIT_DIRECTORY/${LEDGER_BASE_SHA}.fix%2Fledger.${member}.scope.json"
  rotate_member_digest 1.6.3
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused)"
  [ "$(jq -r 'has("review_coverage")' "$written_path")" = "false" ]
}

@test "accounting: a member with nothing open publishes as before beside another member's entries" {
  ledger_setup
  write_sidecar_for "$SIBLING_MEMBER" 7
  bash "$WRITER" --root "$ROOT" --member "$SIBLING_MEMBER" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  [ "$(jq '.remaining | length' "$LEDGER")" = "1" ]
  member="$ACCOUNTING_MEMBER"
  digest="$(member_digest "$ROOT" "$member")"
  # No sidecar for this member at all: nothing of its own is open.
  [ -f "$AUDIT_DIRECTORY/${LEDGER_BASE_SHA}.fix%2Fledger.${member}.findings.json" ] && return 1
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --base "$LEDGER_BASE_SHA" --scope-digest "$digest"
  [ "$status" -eq 0 ]
  [ -f "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
  [ "$(jq '.remaining | length' "$LEDGER")" = "1" ]
}

@test "accounting: only GITHUB_ACTIONS=true skips the check; CI alone does not" {
  accounting_fixture
  write_findings_sidecar "$member" '[]' "$(resolution_json "$FIRST_ID")"

  run env -u GITHUB_ACTIONS CI=true bash "$WRITER" --root "$ROOT" --member "$member" \
    --provenance earned --scope-digest "$B_DIGEST"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ] && return 1

  run env GITHUB_ACTIONS=true bash "$WRITER" --root "$ROOT" --member "$member" \
    --provenance earned --scope-digest "$B_DIGEST"
  [ "$status" -eq 0 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.ok" ]
}

@test "accounting: a --base that differs from the derived key base still keys everything to the derived one" {
  ledger_setup
  member="$ACCOUNTING_MEMBER"
  # A commit on the feature branch after the fork point: not the merge-base.
  offset_base="$LEDGER_HEAD_SHA"
  [ "$offset_base" != "$LEDGER_BASE_SHA" ]
  [ "$(git -C "$ROOT" merge-base main HEAD)" = "$LEDGER_BASE_SHA" ]
  offset_ledger="$AUDIT_DIRECTORY/${offset_base}.fix%2Fledger.rerun.json"

  capture_scope "$member"
  write_sidecar_for "$member" 113
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$offset_base" >/dev/null
  [ -f "$LEDGER" ]
  [ -f "$offset_ledger" ] && return 1
  [ "$(jq -r .base_sha "$LEDGER")" = "$LEDGER_BASE_SHA" ]
  open_identifier="$(open_entry_id "$member")"
  [ -n "$open_identifier" ]

  # The next write finds the open set at the derived key and refuses to drop it.
  write_sidecar_for "$member" 59
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$offset_base"
  [ "$status" -eq 3 ]
  grep -qF -- "   ${open_identifier}  " <<<"$output" || return 1

  write_findings_sidecar "$member" "[$(finding_json 113 warning "$open_identifier"),$(finding_json 59)]"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$offset_base"
  [ "$status" -eq 0 ]
  [ "$(jq -r .base_sha "$LEDGER")" = "$LEDGER_BASE_SHA" ]
  [ "$(jq -r .round "$LEDGER")" = "2" ]
  [ -f "$offset_ledger" ] && return 1
  true
}

@test "accounting: a write with no --base still reads the open set at the derived key" {
  ledger_setup
  member="$ACCOUNTING_MEMBER"
  write_findings_sidecar "$member" "[$(finding_json 113 error),$(finding_json 59)]"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  first_identifier="$(open_entry_id "$member" 0)"
  second_identifier="$(open_entry_id "$member" 1)"
  [ -n "$first_identifier" ]
  [ -n "$second_identifier" ]
  snapshot_ledger

  write_findings_sidecar "$member" '[]' "$(resolution_json "$first_identifier")"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused
  [ "$status" -eq 3 ]
  grep -qF -- "   ${second_identifier}  " <<<"$output" || return 1

  write_findings_sidecar "$member" '[]' "$(resolution_json "$first_identifier" "$second_identifier")"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused
  [ "$status" -eq 0 ]
  # --base is what arms the ledger write, so the ledger is untouched.
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
}

@test "accounting: a supersede that drops an open finding exits 3 and leaves the refusal in place" {
  ledger_setup
  member="$ACCOUNTING_MEMBER"
  digest="$(member_digest "$ROOT" "$member")"
  write_findings_sidecar "$member" "[$(finding_json 113 error),$(finding_json 59)]"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA" >/dev/null
  refused="$AUDIT_DIRECTORY/${digest}.${member}.refused"
  [ -f "$refused" ]
  first_identifier="$(open_entry_id "$member" 0)"
  second_identifier="$(open_entry_id "$member" 1)"
  [ -n "$first_identifier" ]
  [ -n "$second_identifier" ]
  write_findings_sidecar "$member" '[]' "$(resolution_json "$first_identifier")"
  snapshot_ledger

  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned --base "$LEDGER_BASE_SHA" \
    --supersede-refusal "operator accepted the tradeoff"
  [ "$status" -eq 3 ]
  grep -qF -- "   ${second_identifier}  " <<<"$output" || return 1
  [ -f "$refused" ]
  [ -f "$AUDIT_DIRECTORY/${digest}.${member}.ok" ] && return 1
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
}

@test "accounting: a refused write in a member-refusal round with no ledger exits 3" {
  accounting_fixture
  write_findings_sidecar "$member" "[$(finding_json 113 error "$FIRST_ID"),$(finding_json 59 warning "$SECOND_ID")]"
  rm -f "$LEDGER"
  run bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --base "$LEDGER_BASE_SHA"
  [ "$status" -eq 3 ]
  [ -f "$AUDIT_DIRECTORY/${B_DIGEST}.${member}.refused" ] && return 1
  grep -qF -- "audit-scope-digest.sh --release" <<<"$output" || return 1
  grep -qF "re-run the scope resolver" <<<"$output" || return 1
}

# -----------------------------------------------------------------------------
# The compensating status post on a refusal
# -----------------------------------------------------------------------------
# A refusal blocks only the merge path that runs the local merge hook. GitHub's
# auto-merge fires on the required GAIA-Audit status alone, so a refusal landing
# behind an already-posted success has to retract it, and the one moment a
# refusal is guaranteed to be recorded is the moment the writer writes it.
# These arms pin that the writer makes the call, that it makes it ONLY on a
# refusal, that CI is left to its own terminal status, and that the call can
# never disturb the write that already landed.

# Install a post-audit-status.sh stub under ROOT that records its argv.
install_status_hook_stub() {
  local exit_status="${1:-0}"
  mkdir -p "$ROOT/.claude/hooks"
  STATUS_CALLS="$BATS_TEST_TMPDIR/status-calls"
  : > "$STATUS_CALLS"
  cat > "$ROOT/.claude/hooks/post-audit-status.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STATUS_CALLS"
echo "status: stub"
exit $exit_status
EOF
  chmod +x "$ROOT/.claude/hooks/post-audit-status.sh"
}

@test "a refusal write invokes the status hook with the refusal artifact's path" {
  install_status_hook_stub
  digest="$(member_digest "$ROOT" code-audit-frontend)"

  run env -u GITHUB_ACTIONS -u CI bash "$WRITER" \
    --root "$ROOT" --member code-audit-frontend --provenance refused
  [ "$status" -eq 0 ]

  grep -qF -- "${digest}.refused" "$STATUS_CALLS" || return 1
}

@test "an earned write never invokes the status hook: only the orchestrator posts success" {
  install_status_hook_stub
  digest="$(member_digest "$ROOT" code-audit-frontend)"

  run env -u GITHUB_ACTIONS -u CI bash "$WRITER" \
    --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest"
  [ "$status" -eq 0 ]

  [ ! -s "$STATUS_CALLS" ] || return 1
}

@test "a refusal write in CI leaves the status to the workflow's own terminal post" {
  install_status_hook_stub

  # -u CI is load-bearing: Actions sets CI=true on every step, so the guard's
  # CI term alone would satisfy the skip on a runner and this arm could never
  # fail there, whatever the GITHUB_ACTIONS term did. Each arm isolates the one
  # variable it is about.
  run env -u CI GITHUB_ACTIONS=true bash "$WRITER" \
    --root "$ROOT" --member code-audit-frontend --provenance refused
  [ "$status" -eq 0 ]
  [ ! -s "$STATUS_CALLS" ] || return 1
  # The skip says so. A local shell exporting CI for unrelated reasons takes
  # this arm too, and a silent skip there reproduces the incident with no
  # diagnostic at all.
  grep -qF -- "compensating GAIA-Audit failure status skipped" <<<"$output" || return 1

  run env -u GITHUB_ACTIONS CI=true bash "$WRITER" \
    --root "$ROOT" --member code-audit-frontend --provenance refused
  [ "$status" -eq 0 ]
  [ ! -s "$STATUS_CALLS" ] || return 1
}

@test "a failing status hook never fails the refusal write, and never reaches stdout" {
  install_status_hook_stub 1
  digest="$(member_digest "$ROOT" code-audit-frontend)"

  # stdout is the writer's marker-path contract; the hook's chatter goes to
  # stderr so a caller capturing the path gets the path and nothing else.
  written_path="$(env -u GITHUB_ACTIONS -u CI bash "$WRITER" \
    --root "$ROOT" --member code-audit-frontend --provenance refused 2>/dev/null)"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.refused" ]
  [ -f "$AUDIT_DIRECTORY/${digest}.refused" ]
  grep -qF -- "${digest}.refused" "$STATUS_CALLS" || return 1
}

@test "an absent status hook leaves the refusal write untouched" {
  # An adopter tree that has not installed the hook, and every non-local caller.
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  [ ! -e "$ROOT/.claude/hooks/post-audit-status.sh" ]

  run env -u GITHUB_ACTIONS -u CI bash "$WRITER" \
    --root "$ROOT" --member code-audit-frontend --provenance refused
  [ "$status" -eq 0 ]
  [ -f "$AUDIT_DIRECTORY/${digest}.refused" ]
}

# -----------------------------------------------------------------------------
# --scope-digest: the staleness gate (FC-1).
#
# A member resolves its review scope at one HEAD, then finishes and writes at a
# later one. --scope-digest carries the digest captured at scope resolution;
# the writer refuses a PLAIN earned write when it no longer matches the fresh
# write-time derive, rather than publishing a marker keyed to unread content.
# -----------------------------------------------------------------------------

@test "UAT-001: a rotated digest refuses on the earned path and writes nothing" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"

  # A legitimately earned prior marker for a DIFFERENT member+digest, so the
  # byte-identity assertion below proves the refusal leaves it alone rather
  # than merely finding an empty directory.
  other_member="code-audit-maintainer-shell"
  bash "$WRITER" --root "$ROOT" --member "$other_member" --provenance earned \
    --scope-digest "$(member_digest "$ROOT" "$other_member")" >/dev/null

  snapshot="$BATS_TEST_TMPDIR/audit-snapshot"
  rm -rf "$snapshot"
  cp -a "$AUDIT_DIRECTORY" "$snapshot"

  # Rotate every member's digest: a machinery-path change, not an owned-file
  # change, so the rotation is not specific to this member's own globs.
  printf '1.6.2\n' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "rotate"
  new_digest="$(member_digest "$ROOT" code-audit-frontend)"
  [ "$digest" != "$new_digest" ]

  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest"
  [ "$status" -eq 2 ]
  grep -qF "review scope superseded" <<<"$output" || return 1
  grep -qF "$digest" <<<"$output" || return 1
  grep -qF "$new_digest" <<<"$output" || return 1

  # Nothing on disk moved: no artifact of either family created, modified, or
  # removed, and the prior marker written above is untouched.
  diff -r "$snapshot" "$AUDIT_DIRECTORY"
}

@test "UAT-002: a matching scope digest publishes exactly as before" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.ok" ]
  [ -f "$written_path" ]
  [ "$(jq -r .provenance "$written_path")" = "earned" ]
  [ "$(jq -r .digest "$written_path")" = "$digest" ]
}

@test "UAT-003a: an out-of-glob commit does not rotate the digest; the captured scope digest still publishes" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  echo "## [Unreleased]" > "$ROOT/CHANGELOG.md"
  git -C "$ROOT" add CHANGELOG.md
  git -C "$ROOT" commit --quiet -m "changelog"
  [ "$(member_digest "$ROOT" code-audit-frontend)" = "$digest" ]

  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.ok" ]
  [ -f "$written_path" ]
}

@test "UAT-003b: an empty commit does not rotate the digest; the captured scope digest still publishes" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  git -C "$ROOT" commit --quiet --allow-empty -m "empty"
  [ "$(member_digest "$ROOT" code-audit-frontend)" = "$digest" ]

  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.ok" ]
  [ -f "$written_path" ]
}

@test "UAT-004: an absent --scope-digest refuses by its own distinct token" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned
  [ "$status" -eq 2 ]
  grep -qF "scope digest not supplied" <<<"$output" || return 1
  grep -qF "review scope superseded" <<<"$output" && return 1
  grep -qF "cannot derive a content digest" <<<"$output" && return 1
  return 0
}

@test "UAT-004: an underivable write-time digest refuses by the writer's existing token (PATH shim removes the sha256 tools)" {
  # Modelled on the jq shim above: failing executables placed first on PATH,
  # not an unloadable lib (that fires the EARLIER "cannot load the digest
  # engine" guard, a different token than this arm asserts).
  shim="$BATS_TEST_TMPDIR/shim-nosha"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/sha256sum"
  printf '#!/bin/sh\nexit 1\n' > "$shim/shasum"
  chmod +x "$shim/sha256sum" "$shim/shasum"

  run env PATH="$shim:$PATH" bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned \
    --scope-digest "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  [ "$status" -ne 0 ]
  grep -qF "cannot derive a content digest" <<<"$output" || return 1
  grep -qF "review scope superseded" <<<"$output" && return 1
  grep -qF "scope digest not supplied" <<<"$output" && return 1
  return 0
}

@test "the not-supplied refusal names the stale-definition cause and points at --root" {
  # A member dispatched into a worktree that edits its OWN agent definition
  # resolves that definition from the main checkout, so it runs a pre-branch
  # prompt that never learned to capture a scope digest. Its earned write lands
  # on this arm, and the refusal text is the only thing that reaches it, so the
  # refusal has to name that cause and the remedy rather than read as the
  # member's own mistake.
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned
  [ "$status" -eq 2 ]
  grep -qF "scope digest not supplied" <<<"$output" || return 1
  grep -qF "worktree" <<<"$output" || return 1
  grep -qF -- "--root" <<<"$output" || return 1
  true
}

@test "the forfeiture could-not-resolve refusal names every cause that reaches it" {
  # The arm this guards is the case statement's catch-all, so what it speaks for
  # is every helper return whose status has no explicit arm, not the literal 2.
  # Both halves of that are derived from the writer rather than restated here:
  # a cause added later under a brand-new status routes to this same arm and
  # must be named in it. So the guard recounts instead of trusting a sentence.
  # One assertion per named cause as well, since a single pin stays green while
  # an edit drops one of the others and re-opens the very gap this drains.
  # Driven through the no---base condition; what is pinned is that the
  # parenthetical reads as the full set it is, not as a closed subset that
  # sends the operator to rule out the wrong things.
  causes="--base
unresolvable audit key
key library
removal itself failed"
  helper="$(sed -n '/^_release_forfeited_capture() {/,/^}/p' "$WRITER")"
  [ -n "$helper" ]
  # The statuses the caller gives an explicit arm; everything else falls to *).
  arms="$(sed -n '/^    _release_forfeited_capture$/,/^    esac$/p' "$WRITER" \
          | sed -n 's/^      \([0-9][0-9]*\)).*/\1/p')"
  [ -n "$arms" ]
  returns="$(grep -oE 'return [0-9]+' <<<"$helper" | sed 's/^return //')"
  [ -n "$returns" ]
  uncaught=0
  while IFS= read -r return_status; do
    [ -n "$return_status" ] || continue
    grep -qxF -- "$return_status" <<<"$arms" || uncaught=$((uncaught + 1))
  done <<<"$returns"
  [ "$uncaught" -eq "$(grep -c . <<<"$causes")" ]

  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned \
    --scope-digest "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  [ "$status" -eq 2 ]
  grep -qF "review scope superseded" <<<"$output" || return 1
  grep -qF "could not be located or removed" <<<"$output" || return 1
  while IFS= read -r cause; do
    grep -qF -- "$cause" <<<"$output" || return 1
  done <<<"$causes"
  true
}

@test "UAT-012: --provenance refused ignores a stale --scope-digest and behaves exactly as before" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  stale="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused --scope-digest "$stale")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.${member}.refused" ]
  [ -f "$written_path" ]
  [ "$(jq -r .provenance "$written_path")" = "refused" ]
}

@test "UAT-012: an earned write carrying --supersede-refusal ignores a stale --scope-digest, publishes, and removes the sibling refusal" {
  member="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$member")"
  refused="$AUDIT_DIRECTORY/${digest}.${member}.refused"
  bash "$WRITER" --root "$ROOT" --member "$member" --provenance refused >/dev/null
  [ -f "$refused" ] || return 1

  stale="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$member" --provenance earned \
    --supersede-refusal "operator accepted the tradeoff" --scope-digest "$stale")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${digest}.${member}.ok" ]
  [ "$(jq -r .provenance "$written_path")" = "earned" ]
  [ ! -f "$refused" ]
}

@test "usage: a malformed --scope-digest exits 2 with the format error, no marker written" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "not-a-digest"
  [ "$status" -eq 2 ]
  grep -qF -- "--scope-digest must be a 64-hex digest" <<<"$output" || return 1
  leftover="$(find "$AUDIT_DIRECTORY" -name '*.ok' 2>/dev/null || true)"
  [ -z "$leftover" ]
}

@test "usage: an uppercase --scope-digest exits 2 with the format error" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  upper="$(printf '%s' "$digest" | tr 'a-f' 'A-F')"
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$upper"
  [ "$status" -eq 2 ]
  grep -qF -- "--scope-digest must be a 64-hex digest" <<<"$output" || return 1
}

@test "control: an ordinary member is still hard-refused on the same empty value" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend \
    --provenance earned --scope-digest ""
  [ "$status" -eq 2 ]
  grep -qF -- "--scope-digest must be a 64-hex digest" <<<"$output" || return 1
  leftover="$(find "$AUDIT_DIRECTORY" -name '*.ok' 2>/dev/null || true)"
  [ -z "$leftover" ]
}

# --review: earned bodies always carry the field; a light write is licensed by
# a fresh router decision record and by nothing else.

# write_route_record <path> <member> <route> <digest> <tree>
write_route_record() {
  jq -cn --arg member "$2" --arg route "$3" --arg digest "$4" --arg tree "$5" \
    '{route:$route, member:$member, digest:$digest, tree:$tree}' > "$1"
}

# light_fixture: sets $light_member, $light_digest and a matching $light_record
light_fixture() {
  light_member="code-audit-frontend"
  light_digest="$(member_digest "$ROOT" "$light_member")"
  light_record="$BATS_TEST_TMPDIR/route.json"
  write_route_record "$light_record" "$light_member" light "$light_digest" "$TREE"
}

@test "review: an earned write with no --review records review full" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --scope-digest "$digest")"
  [ "$(jq -r .review "$written_path")" = "full" ]
}

@test "review: an explicit --review full records review full" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --review full --scope-digest "$digest")"
  [ "$(jq -r .review "$written_path")" = "full" ]
}

@test "review: a refused body carries no review key" {
  written_path="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance refused)"
  [ "$(jq -r 'has("review")' "$written_path")" = "false" ]
}

@test "review: --review full with --provenance refused exits 2 and writes nothing" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance refused --review full
  [ "$status" -eq 2 ]
  leftover="$(find "$AUDIT_DIRECTORY" \( -name '*.refused' -o -name '*.ok' \) 2>/dev/null || true)"
  [ -z "$leftover" ]
}

@test "review: an unknown --review value exits 2 and writes nothing" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned --review bogus --scope-digest "$digest"
  [ "$status" -eq 2 ]
  [ ! -f "$AUDIT_DIRECTORY/${digest}.ok" ]
}

@test "review: --route-record without --review light is a usage error" {
  light_fixture
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --route-record "$light_record" --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}

@test "light: a matching route record and scope digest write a marker carrying review light" {
  light_fixture
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest")"
  [ "$written_path" = "$AUDIT_DIRECTORY/${light_digest}.ok" ]
  [ "$(jq -r .review "$written_path")" = "light" ]
  [ "$(jq -r .provenance "$written_path")" = "earned" ]
  [ "$(jq -r .schema "$written_path")" = "4" ]
}

@test "light: the marker still satisfies the merge gate's acceptance predicate" {
  light_fixture
  written_path="$(bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest")"
  run bash -c '. "$1"; clearance_member_cleared "$2" "$3" "$4"' _ "$READER" "$ROOT" "$light_digest" "$light_member"
  [ "$status" -eq 0 ]
  [ "$(bash -c '. "$1"; clearance_review_kind "$2"' _ "$READER" "$written_path")" = "light" ]
}

@test "light: a missing --route-record exits 2 and writes no marker" {
  light_fixture
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}

@test "light: an absent route record file exits 2 and writes no marker" {
  light_fixture
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$BATS_TEST_TMPDIR/no-such-record.json" --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}

@test "light: a route record that is not JSON exits 2 and writes no marker" {
  light_fixture
  printf 'not json {' > "$light_record"
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}

@test "light: a route record deciding full exits 2 and writes no marker" {
  light_fixture
  write_route_record "$light_record" "$light_member" full "$light_digest" "$TREE"
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  grep -qF "route is not light" <<<"$output" || return 1
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}

@test "light: a route record naming another member exits 2 and writes no marker" {
  light_fixture
  write_route_record "$light_record" code-audit-maintainer-shell light "$light_digest" "$TREE"
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  grep -qF "different member" <<<"$output" || return 1
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}

@test "light: a route record with a stale digest exits 2 and writes no marker" {
  light_fixture
  printf '1.6.2\n' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "rotate"
  new_digest="$(member_digest "$ROOT" "$light_member")"
  [ "$light_digest" != "$new_digest" ]
  # Both the record and the scope digest are the pre-rotation digest, so only
  # the record check can be what refuses.
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  grep -qF "digest is stale" <<<"$output" || return 1
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
  [ ! -f "$AUDIT_DIRECTORY/${new_digest}.ok" ]
}

@test "light: a route record with a stale tree exits 2 and writes no marker" {
  light_fixture
  echo "more" >> "$ROOT/README.md"
  git -C "$ROOT" add README.md
  git -C "$ROOT" commit --quiet -m "out of glob"
  [ "$(member_digest "$ROOT" "$light_member")" = "$light_digest" ]
  [ "$(git -C "$ROOT" rev-parse 'HEAD^{tree}')" != "$TREE" ]
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  grep -qF "tree is stale" <<<"$output" || return 1
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}

@test "light: --supersede-refusal together with --review light exits 2 and writes no marker" {
  light_fixture
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest" \
    --supersede-refusal "a stated reason"
  [ "$status" -eq 2 ]
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}

@test "light: a same-digest refusal sibling exits 2, writes no marker, and leaves the refusal in place" {
  light_fixture
  refused="$AUDIT_DIRECTORY/${light_digest}.refused"
  bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance refused >/dev/null
  [ -f "$refused" ]
  before="$(cat "$refused")"
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$light_digest"
  [ "$status" -eq 2 ]
  grep -qF "refusal exists" <<<"$output" || return 1
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
  [ -f "$refused" ]
  [ "$(cat "$refused")" = "$before" ]
}

@test "light: a mismatched --scope-digest still refuses through the staleness gate" {
  light_fixture
  stale="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  run bash "$WRITER" --root "$ROOT" --member "$light_member" --provenance earned \
    --review light --route-record "$light_record" --scope-digest "$stale"
  [ "$status" -eq 2 ]
  grep -qF "review scope superseded" <<<"$output" || return 1
  [ ! -f "$AUDIT_DIRECTORY/${light_digest}.ok" ]
}
