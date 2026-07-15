#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-write-clearance.sh, the ONE shared writer for
# every Code Audit Team clearance artifact, and its acceptance by the shared
# reader .claude/hooks/lib/audit-clearance.sh.
#
# The writer takes the audited working root as a REQUIRED argument, resolves
# the tree from it (never from CWD), writes atomically, and records a versioned
# schema-2 body with a `provenance` field. It is NOT evidence-gated: it takes
# no --report, calls no detector, and its body carries no evidence block. An
# earned clearance strictly dominates a carried one; a carried clearance is
# create-only.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS's system bash 3.2
# does not fail a @test on a false bare `[[ ]]` that is not the last command,
# so non-final checks use POSIX `[ ]`, `grep -q`, or an explicit `return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  WRITER="$THIS_DIR/../audit-write-clearance.sh"
  READER="$THIS_DIR/../../../.claude/hooks/lib/audit-clearance.sh"
  RESOLVER="$THIS_DIR/../resolve-audit-members.sh"
  MERGE_GATE="$THIS_DIR/../../../.claude/hooks/pr-merge-audit-check.sh"
  [ -x "$WRITER" ] || skip "audit-write-clearance.sh not executable"
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

# -----------------------------------------------------------------------------
# UAT-020: required --root, tree resolved from the root, atomic write, body
# -----------------------------------------------------------------------------

@test "UAT-020: omitting --root exits 2 with a usage message on stderr" {
  run bash "$WRITER" --member code-audit-frontend --provenance earned
  [ "$status" -eq 2 ]
  # bats `run` captures only stdout; the usage text is on stderr.
  err="$(bash "$WRITER" --member code-audit-frontend --provenance earned 2>&1 1>/dev/null || true)"
  grep -qF "usage" <<<"$err"
  grep -qF "root is required" <<<"$err"
}

@test "UAT-020: resolves the tree from --root, never the caller's CWD" {
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  git -C "$other" init --quiet --initial-branch=main
  git -C "$other" config user.email "test@example.com"
  git -C "$other" config user.name "Test"
  git -C "$other" config commit.gpgsign false
  echo "different content entirely" > "$other/x.txt"
  git -C "$other" add x.txt
  git -C "$other" commit --quiet -m "other"
  other_tree="$(git -C "$other" rev-parse "HEAD^{tree}")"
  [ "$other_tree" != "$TREE" ]

  # Run with CWD inside `other`, but --root pointing at ROOT.
  out="$( cd "$other" && bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned )"
  [ "$out" = "$AUDIT_DIR/${TREE}.ok" ]
  [ -f "$AUDIT_DIR/${TREE}.ok" ]
  # The CWD's tree was NOT used as the key.
  [ ! -f "$AUDIT_DIR/${other_tree}.ok" ]
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

@test "UAT-020: earned body records the schema-2 fields, no evidence key, no second sidecar pointer" {
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned >/dev/null
  marker="$AUDIT_DIR/${TREE}.ok"
  [ "$(jq -r .version "$marker")" = "1.6.1" ]
  [ "$(jq -r .schema "$marker")" = "2" ]
  [ "$(jq -r .member "$marker")" = "code-audit-frontend" ]
  [ "$(jq -r .provenance "$marker")" = "earned" ]
  [ "$(jq -r .sha "$marker")" = "$HEAD_SHA" ]
  [ "$(jq -r .tree "$marker")" = "$TREE" ]
  [ "$(jq -r .sidecar "$marker")" = "true" ]
  grep -qE '"audited_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$marker"
  # No evidence block; the sidecar path derives from `sha`, so no second pointer.
  [ "$(jq -r 'has("evidence")' "$marker")" = "false" ]
  [ "$(jq -r 'has("sidecar_path")' "$marker")" = "false" ]
  [ "$(jq -r 'has("report")' "$marker")" = "false" ]
}

@test "UAT-020: a specialized member's earned sidecar flag is false" {
  bash "$WRITER" --root "$ROOT" --member code-audit-maintainer-shell --provenance earned >/dev/null
  [ "$(jq -r .sidecar "$AUDIT_DIR/${TREE}.code-audit-maintainer-shell.ok")" = "false" ]
}

# -----------------------------------------------------------------------------
# Clean, zero-finding earned write lands for ALL THREE members (the deadlock
# the dropped evidence gate would have caused). No report, no detector.
# -----------------------------------------------------------------------------

@test "clean zero-finding earned write lands for all three members, no detector involved" {
  for m in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    out="$(bash "$WRITER" --root "$ROOT" --member "$m" --provenance earned)"
    if [ "$m" = "code-audit-frontend" ]; then
      expect="$AUDIT_DIR/${TREE}.ok"
    else
      expect="$AUDIT_DIR/${TREE}.${m}.ok"
    fi
    [ "$out" = "$expect" ]
    [ -f "$expect" ]
    [ "$(jq -r .member "$expect")" = "$m" ]
    [ "$(jq -r .provenance "$expect")" = "earned" ]
  done
}

@test "structural: the writer never references audit-noop-detect.sh and carries no evidence key" {
  grep -qF "audit-noop-detect" "$WRITER" && return 1
  # The JSON evidence key (quoted) never appears in the produced body.
  grep -qF '"evidence"' "$WRITER" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# UAT-007: earned strictly dominates carried; carried is create-only
# -----------------------------------------------------------------------------

@test "UAT-007a: an earned write removes an existing carried artifact (no guard suppresses it)" {
  m="code-audit-maintainer-node"
  bash "$WRITER" --root "$ROOT" --member "$m" --provenance carried --anchor-tree "$TREE" >/dev/null
  [ -f "$AUDIT_DIR/${TREE}.${m}.carried" ]

  out="$(bash "$WRITER" --root "$ROOT" --member "$m" --provenance earned)"
  [ "$out" = "$AUDIT_DIR/${TREE}.${m}.ok" ]
  [ -f "$AUDIT_DIR/${TREE}.${m}.ok" ]
  # The carried artifact is gone.
  [ ! -f "$AUDIT_DIR/${TREE}.${m}.carried" ]
}

@test "UAT-007b: carried is create-only, refused when an earned marker exists, earned untouched" {
  m="code-audit-frontend"
  bash "$WRITER" --root "$ROOT" --member "$m" --provenance earned >/dev/null
  marker="$AUDIT_DIR/${TREE}.ok"
  before_prov="$(jq -r .provenance "$marker")"
  before_at="$(jq -r .audited_at "$marker")"

  out="$(bash "$WRITER" --root "$ROOT" --member "$m" --provenance carried --anchor-tree "$TREE")"
  [ "$out" = "declined: earned-clearance-exists" ]
  # No carried artifact was created.
  [ ! -f "$AUDIT_DIR/${TREE}.carried" ]
  # The earned marker is unchanged.
  [ "$(jq -r .provenance "$marker")" = "$before_prov" ]
  [ "$(jq -r .audited_at "$marker")" = "$before_at" ]
}

@test "UAT-007c: an earned write replaces a legacy-bodied marker at the same path" {
  m="code-audit-frontend"
  mkdir -p "$AUDIT_DIR"
  printf '{"sha":"old","tree":"%s","audited_at":"1999-01-01T00:00:00Z"}\n' "$TREE" > "$AUDIT_DIR/${TREE}.ok"

  out="$(bash "$WRITER" --root "$ROOT" --member "$m" --provenance earned)"
  [ "$out" = "$AUDIT_DIR/${TREE}.ok" ]
  [ "$(jq -r .provenance "$AUDIT_DIR/${TREE}.ok")" = "earned" ]
  [ "$(jq -r .schema "$AUDIT_DIR/${TREE}.ok")" = "2" ]
}

# -----------------------------------------------------------------------------
# Refusals: a first-class, tree-keyed artifact; not evidence-gated
# -----------------------------------------------------------------------------

@test "refusal: --provenance refused lands at the .refused filename, provenance refused, no report needed" {
  m="code-audit-maintainer-shell"
  out="$(bash "$WRITER" --root "$ROOT" --member "$m" --provenance refused)"
  [ "$out" = "$AUDIT_DIR/${TREE}.${m}.refused" ]
  [ "$(jq -r .provenance "$out")" = "refused" ]
  [ "$(jq -r .member "$out")" = "$m" ]
  [ "$(jq -r .tree "$out")" = "$TREE" ]

  # The default member's refusal carries no member infix.
  out2="$(bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance refused)"
  [ "$out2" = "$AUDIT_DIR/${TREE}.refused" ]
}

@test "usage: --provenance carried without --anchor-tree exits 2" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance carried
  [ "$status" -eq 2 ]
}

@test "usage: an invalid --provenance exits 2" {
  run bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance bogus
  [ "$status" -eq 2 ]
}

# -----------------------------------------------------------------------------
# Acceptance, end to end: the reader accepts writer-produced markers only
# -----------------------------------------------------------------------------

@test "acceptance: a writer-produced earned marker satisfies clearance_acceptable; legacy and key-mismatch do not" {
  # shellcheck source=/dev/null
  . "$READER"
  bash "$WRITER" --root "$ROOT" --member code-audit-frontend --provenance earned >/dev/null
  marker="$AUDIT_DIR/${TREE}.ok"

  clearance_acceptable "$marker" code-audit-frontend "$TREE"

  # A hand-written legacy body at the same path does NOT satisfy the reader.
  printf '{"sha":"x","tree":"%s","audited_at":"z"}\n' "$TREE" > "$AUDIT_DIR/legacy.ok"
  clearance_acceptable "$AUDIT_DIR/legacy.ok" code-audit-frontend "$TREE" && return 1

  # A writer-produced marker whose filename key disagrees with its body tree
  # (checked against the wrong key) does NOT satisfy the reader.
  cp "$marker" "$AUDIT_DIR/ffffffffffffffffffffffffffffffffffffffff.ok"
  clearance_acceptable "$AUDIT_DIR/ffffffffffffffffffffffffffffffffffffffff.ok" \
    code-audit-frontend "ffffffffffffffffffffffffffffffffffffffff" && return 1

  return 0
}

# -----------------------------------------------------------------------------
# UAT-021: the adopter shape. The release scrub strips the maintainer-only
# blocks; the roster collapses to the single default member, and the shipped
# writer + shipped merge gate complete a merge with no maintainer member.
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

@test "UAT-021: adopter shape collapses the roster and completes a merge via the shipped writer + gate" {
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

  # The resolver copy resolves its libs relative to ITSELF
  # ($ADOPTER/.claude/hooks/lib/), so provision the shared ownership
  # classifier alongside it. The scrubbed .gaia/audit-ci.yml (written above)
  # still drives the single-member roster; the lib's builtin fallback is
  # consulted only when the config has no auditors block, which it does.
  _lib_src="$(dirname "$READER")"
  mkdir -p "$ADOPTER/.claude/hooks/lib"
  cp "$_lib_src/audit-scope.sh" "$ADOPTER/.claude/hooks/lib/audit-scope.sh"
  cp "$_lib_src/audit-machinery.sh" "$ADOPTER/.claude/hooks/lib/audit-machinery.sh"
  cp "$_lib_src/audit-clearance.sh" "$ADOPTER/.claude/hooks/lib/audit-clearance.sh"

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

  # The shipped writer writes the default member's marker.
  out="$( cd "$ADOPTER" && bash .gaia/scripts/audit-write-clearance.sh \
    --root "$ADOPTER" --member code-audit-frontend --provenance earned )"
  adopter_tree="$(git -C "$ADOPTER" rev-parse "HEAD^{tree}")"
  [ "$out" = "$ADOPTER/.gaia/local/audit/${adopter_tree}.ok" ]
  [ -f "$out" ]

  # The shipped merge gate allows the merge (no maintainer member is demanded).
  input="$(jq -nc '{tool_name:"Bash",tool_input:{command:"gh pr merge 1 --squash"}}')"
  run bash -c "cd '$ADOPTER' && printf '%s' '$input' | bash '$MERGE_GATE'"
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}
