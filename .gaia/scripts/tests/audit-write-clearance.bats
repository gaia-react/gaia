#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-write-clearance.sh, the ONE shared writer for
# every Code Audit Team clearance artifact, and its acceptance by the shared
# reader .claude/hooks/lib/audit-clearance.sh.
#
# The writer takes the audited working root as a REQUIRED argument, derives
# the member's content digest from it via the digest engine
# (.claude/hooks/lib/audit-digest.sh, never from CWD), writes atomically, and
# records a versioned schema-3 body with a `provenance` field. It is NOT
# evidence-gated: it takes no --report, calls no detector, and its body
# carries no evidence block. Provenance is earned or refused only; there is no
# carried family, no --anchor-tree, and every write lands unconditionally
# (overwrites a stale body at the same path).
#
# Assertion style (.claude/rules/bats-assertions.md): macOS's system bash 3.2
# does not fail a @test on a false bare `[[ ]]` that is not the last command,
# so non-final checks use POSIX `[ ]`, `grep -q`, or an explicit `return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  WRITER="$THIS_DIR/../audit-write-clearance.sh"
  READER="$THIS_DIR/../../../.claude/hooks/lib/audit-clearance.sh"
  DIGEST_LIB="$THIS_DIR/../../../.claude/hooks/lib/audit-digest.sh"
  RESOLVER="$THIS_DIR/../resolve-audit-members.sh"
  [ -x "$WRITER" ] || skip "audit-write-clearance.sh not executable"
  [ -f "$DIGEST_LIB" ] || skip "audit-digest.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/.gaia"
  printf '1.6.1\n' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" init --quiet --initial-branch=main
  git -C "$ROOT" config user.email "test@example.com"
  git -C "$ROOT" config user.name "Test"
  git -C "$ROOT" config commit.gpgsign false
  echo "# readme" > "$ROOT/README.md"
  git -C "$ROOT" add .gaia/VERSION README.md
  git -C "$ROOT" commit --quiet -m "init"

  TREE="$(git -C "$ROOT" rev-parse "HEAD^{tree}")"
  HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  AUDIT_DIR="$ROOT/.gaia/local/audit"
}

# member_digest <root> <member> -> 64-hex digest on stdout
member_digest() {
  local root="$1" member="$2"
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$DIGEST_LIB" "$root" "$member"
}

# -----------------------------------------------------------------------------
# Required --root, digest resolved from the root, atomic write, body
# -----------------------------------------------------------------------------

@test "UAT-020: omitting --root exits 2 with a usage message on stderr" {
  run bash "$WRITER" --member code-audit-frontend --provenance earned
  [ "$status" -eq 2 ]
  # bats `run` merges stderr into `$output`, so `$output` cannot tell the two
  # apart. Re-run with stdout discarded to prove the usage text goes to stderr
  # specifically, which is what this test claims.
  err="$(bash "$WRITER" --member code-audit-frontend --provenance earned 2>&1 1>/dev/null || true)"
  grep -qF "usage" <<<"$err"
  grep -qF "root is required" <<<"$err"
}

@test "resolves the digest from --root, never the caller's CWD" {
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  git -C "$other" init --quiet --initial-branch=main
  git -C "$other" config user.email "test@example.com"
  git -C "$other" config user.name "Test"
  git -C "$other" config commit.gpgsign false
  echo "different content entirely" > "$other/x.txt"
  git -C "$other" add x.txt
  git -C "$other" commit --quiet -m "other"
  other_digest="$(member_digest "$other" code-audit-frontend)"
  root_digest="$(member_digest "$ROOT" code-audit-frontend)"
  [ -n "$other_digest" ]
  [ -n "$root_digest" ]
  [ "$other_digest" != "$root_digest" ]

  # Run with CWD inside `other`, but --root pointing at ROOT.
  out="$( cd "$other" && bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned )"
  [ "$out" = "$AUDIT_DIR/${root_digest}.ok" ]
  [ -f "$AUDIT_DIR/${root_digest}.ok" ]
  # The CWD's digest was NOT used as the key.
  [ ! -f "$AUDIT_DIR/${other_digest}.ok" ]
}

@test "UAT-020: writes atomically via a temp file in the target dir + mv, leaving no stray temp" {
  # Structural: the writer stages a temp in the audit dir and publishes with mv.
  grep -qF "mktemp" "$WRITER"
  grep -qF "mv " "$WRITER"
  out="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned)"
  [ -f "$out" ]
  # No stray temp file left behind after the mv.
  leftover="$(find "$AUDIT_DIR" -name '.audit-write-clearance.*' 2>/dev/null)"
  [ -z "$leftover" ]
}

@test "earned body records the schema-3 fields, digest as validity key, no carried leftovers" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned >/dev/null
  marker="$AUDIT_DIR/${digest}.ok"
  [ -f "$marker" ]
  [ "$(jq -r .version "$marker")" = "1.6.1" ]
  [ "$(jq -r .schema "$marker")" = "3" ]
  [ "$(jq -r .member "$marker")" = "code-audit-frontend" ]
  [ "$(jq -r .provenance "$marker")" = "earned" ]
  [ "$(jq -r .digest "$marker")" = "$digest" ]
  [ "$(jq -r .sha "$marker")" = "$HEAD_SHA" ]
  [ "$(jq -r .tree "$marker")" = "$TREE" ]
  [ "$(jq -r .sidecar "$marker")" = "true" ]
  grep -qE '"audited_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$marker"
  # No evidence block, no anchor_tree, no second sidecar pointer.
  [ "$(jq -r 'has("evidence")' "$marker")" = "false" ]
  [ "$(jq -r 'has("sidecar_path")' "$marker")" = "false" ]
  [ "$(jq -r 'has("report")' "$marker")" = "false" ]
  [ "$(jq -r 'has("anchor_tree")' "$marker")" = "false" ]
}

@test "a specialized member's earned sidecar flag is false" {
  digest="$(member_digest "$ROOT" code-audit-maintainer-shell)"
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance earned >/dev/null
  marker="$AUDIT_DIR/${digest}.code-audit-maintainer-shell.ok"
  [ -f "$marker" ]
  [ "$(jq -r .sidecar "$marker")" = "false" ]
}

# -----------------------------------------------------------------------------
# Body escaping: the body is built by `jq -n`, so every value is escaped by
# construction. `version` is the only field read from a file (.gaia/VERSION),
# which makes it the field a stray `"` or `\` actually reaches.
# -----------------------------------------------------------------------------

@test "escaping: a version carrying a quote and a backslash still produces valid parseable JSON" {
  # shellcheck disable=SC1003  # the backslash is a literal, which is the point
  printf '%s\n' '1.6.1"\' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "version with quote and backslash"
  digest="$(member_digest "$ROOT" code-audit-frontend)"

  out="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned)"
  [ "$out" = "$AUDIT_DIR/${digest}.ok" ]

  # The body parses at all. A hand-built template emits a bare `\"` here, which
  # closes the string early and makes the whole marker unparseable.
  jq -e . "$out" >/dev/null

  # The value round-trips byte-exact: escaped, not stripped or mangled.
  # shellcheck disable=SC1003  # the backslash is a literal, which is the point
  [ "$(jq -r .version "$out")" = '1.6.1"\' ]

  # A marker with an awkward version is still acceptable to the gate's reader.
  # shellcheck source=/dev/null
  . "$READER"
  clearance_acceptable "$out" code-audit-frontend "$digest"
}

@test "escaping: a version that injects body keys lands as data, never as structure" {
  # The crafted value closes the version string and appends its own member /
  # provenance keys. Escaped, it can only ever be a version string.
  printf '%s\n' '1.6.1","member":"code-audit-frontend","provenance":"earned' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "version attempting key injection"
  m="code-audit-maintainer-shell"
  digest="$(member_digest "$ROOT" "$m")"

  out="$(bash "$WRITER" --root "$ROOT" --member "$m" --provenance refused)"
  jq -e . "$out" >/dev/null

  # The injected text is the version VALUE, not new keys.
  [ "$(jq -r .version "$out")" = '1.6.1","member":"code-audit-frontend","provenance":"earned' ]
  [ "$(jq -r .member "$out")" = "$m" ]
  [ "$(jq -r .provenance "$out")" = "refused" ]

  # Structural: each key is emitted exactly once. A template would have spliced
  # a second "member" / "provenance" pair into the raw body.
  [ "$(grep -o '"member":' "$out" | wc -l | tr -d ' ')" = "1" ]
  [ "$(grep -o '"provenance":' "$out" | wc -l | tr -d ' ')" = "1" ]

  # The forged `earned` never becomes a clearance: no earned marker exists, and
  # the refusal reads as a refusal.
  # shellcheck source=/dev/null
  . "$READER"
  clearance_member_cleared "$ROOT" "$digest" "$m" && return 1
  clearance_member_refused "$ROOT" "$digest" "$m"
}

@test "fails closed (exit non-zero, no marker, no stray temp) when jq cannot build the body" {
  # Shadow jq with a failing stub, keeping the real PATH behind it so git,
  # mktemp and date still resolve and the run reaches the body build. A jq
  # failure must never publish an empty or partial marker on a zero exit.
  shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/jq"
  chmod +x "$shim/jq"

  run env PATH="$shim:$PATH" bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned
  [ "$status" -ne 0 ]

  # Pin WHICH guard fired: the body build, not the digest derive. The digest
  # chain needs no jq today, so a bare status check passes for the right reason
  # by luck; were digest derivation to grow a jq dependency it would fail first
  # and this test would green while covering nothing.
  grep -qF "cannot build the marker body" <<<"$output"

  # No marker published, and no half-written temp left staged in the audit dir.
  leftover="$(find "$AUDIT_DIR" -name '*.ok' 2>/dev/null || true)"
  [ -z "$leftover" ]
  stray="$(find "$AUDIT_DIR" -name '.audit-write-clearance.*' 2>/dev/null || true)"
  [ -z "$stray" ]
}

# -----------------------------------------------------------------------------
# Clean, zero-finding earned write lands for ALL THREE members. No report, no
# detector; each member's filename stem equals its own body .digest.
# -----------------------------------------------------------------------------

@test "clean zero-finding earned write lands for all three members, no detector involved" {
  for m in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    d="$(member_digest "$ROOT" "$m")"
    out="$(bash "$WRITER" --root "$ROOT" --member "$m" --provenance earned)"
    if [ "$m" = "code-audit-frontend" ]; then
      expect="$AUDIT_DIR/${d}.ok"
    else
      expect="$AUDIT_DIR/${d}.${m}.ok"
    fi
    [ "$out" = "$expect" ]
    [ -f "$expect" ]
    [ "$(jq -r .member "$expect")" = "$m" ]
    [ "$(jq -r .provenance "$expect")" = "earned" ]
    [ "$(jq -r .digest "$expect")" = "$d" ]
  done
}

@test "structural: the writer never references audit-noop-detect.sh and carries no evidence key" {
  grep -qF "audit-noop-detect" "$WRITER" && return 1
  # The JSON evidence key (quoted) never appears in the produced body.
  grep -qF '"evidence"' "$WRITER" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# Hard cutover: carried / anchor-tree are gone. Rejected as usage errors.
# -----------------------------------------------------------------------------

@test "usage: --provenance carried is rejected, no marker written" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance carried
  [ "$status" -eq 2 ]
  # AUDIT_DIR may not even exist (the writer fails before mkdir -p); `find` on
  # a missing dir exits non-zero, so guard with `|| true` under bats' set -e.
  leftover="$(find "$AUDIT_DIR" -name '*.carried' 2>/dev/null || true)"
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

# -----------------------------------------------------------------------------
# Fail-closed: the digest must derive, or nothing is written (SC7/UAT-013).
# -----------------------------------------------------------------------------

@test "fails closed (exit non-zero, no marker) when the digest cannot be derived" {
  sha256sum() { return 1; }
  shasum() { return 1; }
  export -f sha256sum shasum
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned
  [ "$status" -ne 0 ]
  # AUDIT_DIR may not even exist (the writer fails before mkdir -p); `find` on
  # a missing dir exits non-zero, so guard with `|| true` under bats' set -e.
  leftover="$(find "$AUDIT_DIR" -name '*.ok' 2>/dev/null || true)"
  [ -z "$leftover" ]
}

@test "an earned write replaces a stale body at the same digest path" {
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  mkdir -p "$AUDIT_DIR"
  printf '{"sha":"old","tree":"%s","audited_at":"1999-01-01T00:00:00Z"}\n' "$TREE" > "$AUDIT_DIR/${digest}.ok"

  out="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned)"
  [ "$out" = "$AUDIT_DIR/${digest}.ok" ]
  [ "$(jq -r .provenance "$AUDIT_DIR/${digest}.ok")" = "earned" ]
  [ "$(jq -r .schema "$AUDIT_DIR/${digest}.ok")" = "3" ]
  [ "$(jq -r .digest "$AUDIT_DIR/${digest}.ok")" = "$digest" ]
}

# -----------------------------------------------------------------------------
# Refusals: a first-class, digest-keyed artifact; not evidence-gated
# -----------------------------------------------------------------------------

@test "refusal: --provenance refused lands at the digest-keyed .refused filename" {
  m="code-audit-maintainer-shell"
  d="$(member_digest "$ROOT" "$m")"
  out="$(bash "$WRITER" --root "$ROOT" --member "$m" --provenance refused)"
  [ "$out" = "$AUDIT_DIR/${d}.${m}.refused" ]
  [ "$(jq -r .provenance "$out")" = "refused" ]
  [ "$(jq -r .member "$out")" = "$m" ]
  [ "$(jq -r .digest "$out")" = "$d" ]
  [ "$(jq -r .tree "$out")" = "$TREE" ]

  # The default member's refusal carries no member infix.
  fd="$(member_digest "$ROOT" code-audit-frontend)"
  out2="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance refused)"
  [ "$out2" = "$AUDIT_DIR/${fd}.refused" ]
}

@test "clearance_member_refused matches a writer-produced refusal for the exact digest" {
  # shellcheck source=/dev/null
  . "$READER"
  m="code-audit-maintainer-shell"
  d="$(member_digest "$ROOT" "$m")"
  bash "$WRITER" --root "$ROOT" --member "$m" --provenance refused >/dev/null
  clearance_member_refused "$ROOT" "$d" "$m"

  # A digest mismatch does not match.
  clearance_member_refused "$ROOT" "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "$m" && return 1

  # An earned marker for a different member+digest is not a refusal.
  fd="$(member_digest "$ROOT" code-audit-frontend)"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned >/dev/null
  clearance_member_refused "$ROOT" "$fd" code-audit-frontend && return 1
  return 0
}

# -----------------------------------------------------------------------------
# Reader: clearance_member_cleared is earned-only, no carried fallback
# (the .carried family and clearance_carried_path no longer exist).
# -----------------------------------------------------------------------------

@test "structural: clearance_carried_path is deleted from the reader" {
  # shellcheck source=/dev/null
  . "$READER"
  command -v clearance_carried_path >/dev/null 2>&1 && return 1
  return 0
}

@test "clearance_member_cleared: earned only, no carried fallback" {
  # shellcheck source=/dev/null
  . "$READER"
  d="$(member_digest "$ROOT" code-audit-frontend)"
  # Not cleared before any write.
  clearance_member_cleared "$ROOT" "$d" code-audit-frontend && return 1

  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned >/dev/null
  clearance_member_cleared "$ROOT" "$d" code-audit-frontend

  # A refusal for a DIFFERENT member+digest never makes that member cleared.
  rd="$(member_digest "$ROOT" code-audit-maintainer-node)"
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused >/dev/null
  clearance_member_cleared "$ROOT" "$rd" code-audit-maintainer-node && return 1
  return 0
}

# -----------------------------------------------------------------------------
# Acceptance, end to end: the reader accepts writer-produced earned markers
# only, matched to the exact digest and member (UAT-007).
# -----------------------------------------------------------------------------

@test "acceptance: a writer-produced earned marker satisfies clearance_acceptable; legacy, digest-mismatch, member-mismatch, refused do not" {
  # shellcheck source=/dev/null
  . "$READER"
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned >/dev/null
  marker="$AUDIT_DIR/${digest}.ok"

  clearance_acceptable "$marker" code-audit-frontend "$digest"

  # A hand-written legacy body (no .digest field) does NOT satisfy the reader.
  printf '{"sha":"x","tree":"%s","audited_at":"z"}\n' "$TREE" > "$AUDIT_DIR/legacy.ok"
  clearance_acceptable "$AUDIT_DIR/legacy.ok" code-audit-frontend "$digest" && return 1

  # A digest mismatch does NOT satisfy the reader.
  clearance_acceptable "$marker" code-audit-frontend "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" && return 1

  # A member mismatch does NOT satisfy the reader.
  clearance_acceptable "$marker" code-audit-maintainer-shell "$digest" && return 1

  # A refused body does NOT satisfy clearance_acceptable (earned only).
  node_digest="$(member_digest "$ROOT" code-audit-maintainer-node)"
  refused_out="$(bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused)"
  clearance_acceptable "$refused_out" code-audit-maintainer-node "$node_digest" && return 1

  return 0
}

@test "jq absent: clearance_acceptable and clearance_member_refused fail closed, never bare-existence" {
  # shellcheck source=/dev/null
  . "$READER"
  digest="$(member_digest "$ROOT" code-audit-frontend)"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned >/dev/null
  marker="$AUDIT_DIR/${digest}.ok"
  [ -f "$marker" ]

  node_digest="$(member_digest "$ROOT" code-audit-maintainer-node)"
  refused_out="$(bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-node --provenance refused)"
  [ -f "$refused_out" ]

  emptybin="$BATS_TEST_TMPDIR/emptybin"
  mkdir -p "$emptybin"
  OLDPATH="$PATH"
  PATH="$emptybin"
  if command -v jq >/dev/null 2>&1; then
    PATH="$OLDPATH"
    skip "could not simulate jq absence on this PATH"
  fi

  status1=0
  clearance_acceptable "$marker" code-audit-frontend "$digest" || status1=$?
  status2=0
  clearance_member_refused "$ROOT" "$node_digest" code-audit-maintainer-node || status2=$?

  PATH="$OLDPATH"

  [ "$status1" -eq 1 ]
  [ "$status2" -eq 1 ]
}

# -----------------------------------------------------------------------------
# The adopter shape. The release scrub strips the maintainer-only blocks; the
# roster collapses to the single default member, and the shipped writer
# produces a valid digest-keyed marker with no maintainer member.
# -----------------------------------------------------------------------------

# Strip # gaia:maintainer-only:start ... :end blocks (inclusive), as the
# bundle-time scrub does to shipped files.
scrub_maintainer_only() {
  awk '
    /gaia:maintainer-only:start/ { skip = 1 }
    !skip { print }
    /gaia:maintainer-only:end/   { skip = 0 }
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
  mkdir -p "$ADOPTER/app"
  echo "export const x = 1;" > "$ADOPTER/app/x.ts"
  git -C "$ADOPTER" add app/x.ts
  git -C "$ADOPTER" commit --quiet -m "feat: x"

  # Provision the adopter shape (all UNTRACKED, so they never join the diff):
  #  1. scrub the maintainer-only block from the roster config, and
  #  2. scrub it from the resolver's builtin_roster fallback too, and
  #  3. omit resolve-audit-spawn.sh (genuinely unshipped), and
  #  4. omit the two maintainer agent definitions.
  scrub_maintainer_only "$THIS_DIR/../../audit-ci.yml" > "$ADOPTER/.gaia/audit-ci.yml"
  scrub_maintainer_only "$RESOLVER" > "$ADOPTER/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$ADOPTER/.gaia/scripts/resolve-audit-members.sh"
  cp "$WRITER" "$ADOPTER/.gaia/scripts/audit-write-clearance.sh"
  chmod +x "$ADOPTER/.gaia/scripts/audit-write-clearance.sh"

  # The writer copy resolves its digest lib relative to ITSELF
  # ($ADOPTER/.claude/hooks/lib/), and the resolver copy resolves its
  # ownership classifier the same way, so provision both there. The scrubbed
  # .gaia/audit-ci.yml (written above) still drives the single-member roster;
  # the lib's builtin fallback is consulted only when the config has no
  # auditors block, which it does.
  _lib_src="$(dirname "$READER")"
  mkdir -p "$ADOPTER/.claude/hooks/lib"
  cp "$_lib_src/audit-scope.sh" "$ADOPTER/.claude/hooks/lib/audit-scope.sh"
  cp "$_lib_src/audit-machinery.sh" "$ADOPTER/.claude/hooks/lib/audit-machinery.sh"
  cp "$_lib_src/audit-clearance.sh" "$ADOPTER/.claude/hooks/lib/audit-clearance.sh"
  cp "$DIGEST_LIB" "$ADOPTER/.claude/hooks/lib/audit-digest.sh"

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
  out="$( cd "$ADOPTER" && bash .gaia/scripts/audit-write-clearance.sh \
    --root "$ADOPTER" --member code-audit-frontend --provenance earned )"
  adopter_digest="$(member_digest "$ADOPTER" code-audit-frontend)"
  [ "$out" = "$ADOPTER/.gaia/local/audit/${adopter_digest}.ok" ]
  [ -f "$out" ]
  [ "$(jq -r .schema "$out")" = "3" ]
  [ "$(jq -r .digest "$out")" = "$adopter_digest" ]
  [ "$(jq -r .member "$out")" = "code-audit-frontend" ]
}
