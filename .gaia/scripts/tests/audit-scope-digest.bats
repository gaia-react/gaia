#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/audit-scope-digest.sh: the carry for a
# Code Audit Team member's own content digest between scope resolution
# (--capture) and clearance write (--read). See the script's own header for
# the full contract; this suite proves it.
#
# Most tests run the SCRIPT directly against a minimal git fixture (ROOT).
# A handful build a full standalone SANDBOX -- a fixture that additionally
# carries its own copy of the script and its libs at the real repo's
# relative layout -- because they manipulate the script's own on-disk
# neighborhood (an absent sibling lib) rather than just --root's content.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/audit-scope-digest.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$THIS_DIR/../audit-scope-digest.sh"
  KEY_LIB="$THIS_DIR/../audit-key-lib.sh"
  RESPAWN_LIB="$THIS_DIR/../audit-respawn-lib.sh"
  DIGEST_LIB="$THIS_DIR/../../../.claude/hooks/lib/audit-digest.sh"
  SCOPE_LIB="$THIS_DIR/../../../.claude/hooks/lib/audit-scope.sh"
  MACHINERY_LIB="$THIS_DIR/../../../.claude/hooks/lib/audit-machinery.sh"
  [ -x "$SCRIPT" ] || skip "audit-scope-digest.sh not executable"
  [ -f "$KEY_LIB" ] || skip "audit-key-lib.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT"
  git -C "$ROOT" init --quiet --initial-branch=main
  git -C "$ROOT" config user.email "test@example.com"
  git -C "$ROOT" config user.name "Test"
  git -C "$ROOT" config commit.gpgsign false
  echo "# readme" >"$ROOT/README.md"
  git -C "$ROOT" add README.md
  git -C "$ROOT" commit --quiet -m "init"

  BASE="$(git -C "$ROOT" rev-parse HEAD)"
  MEMBER="code-audit-frontend"
  AUDIT_DIR="$ROOT/.gaia/local/audit"
}

# require_non_root: skip (or hard-fail on CI) when running as root, where a
# chmod-restricted file/dir stays accessible and the fixture would skip to
# green. Mirrors .gaia/tests/lib/audit-ci-shards.bats's helper of the same name.
require_non_root() {
  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "running as root on a CI runner, where a chmod-restricted path stays accessible, so this fixture would skip to green. This job is expected to run unprivileged." >&2
    return 1
  fi
  skip "running as root; a chmod-restricted path stays accessible"
}

# audit_key_for <base> <root>: gaia_audit_key computed the same way the
# script computes it, for building the expected scope-file path by hand.
audit_key_for() {
  bash -c '. "$1"; gaia_audit_key "$2" "$3"' _ "$KEY_LIB" "$1" "$2"
}

# scope_file_for <root> <base> <member>: the exact path the script reads and
# writes.
scope_file_for() {
  local root="$1" base="$2" member="$3" key
  key="$(audit_key_for "$base" "$root")"
  printf '%s/.gaia/local/audit/%s.%s.scope.json' "$root" "$key" "$member"
}

# build_sandbox <dir> [--no-respawn-lib]: a standalone fixture carrying its
# OWN copy of the script and its libs at the real repo's relative layout, so
# a test can remove one sibling lib without touching the real repo. Git repo
# rooted at <dir>.
build_sandbox() {
  local sb="$1" with_respawn="yes"
  [ "${2:-}" = "--no-respawn-lib" ] && with_respawn="no"
  mkdir -p "$sb/.gaia/scripts" "$sb/.claude/hooks/lib"
  cp "$SCRIPT" "$sb/.gaia/scripts/audit-scope-digest.sh"
  chmod +x "$sb/.gaia/scripts/audit-scope-digest.sh"
  cp "$KEY_LIB" "$sb/.gaia/scripts/audit-key-lib.sh"
  [ "$with_respawn" = "yes" ] && cp "$RESPAWN_LIB" "$sb/.gaia/scripts/audit-respawn-lib.sh"
  cp "$DIGEST_LIB" "$sb/.claude/hooks/lib/audit-digest.sh"
  cp "$SCOPE_LIB" "$sb/.claude/hooks/lib/audit-scope.sh"
  cp "$MACHINERY_LIB" "$sb/.claude/hooks/lib/audit-machinery.sh"
  git -C "$sb" init --quiet --initial-branch=main
  git -C "$sb" config user.email "test@example.com"
  git -C "$sb" config user.name "Test"
  git -C "$sb" config commit.gpgsign false
  echo "# readme" >"$sb/README.md"
  git -C "$sb" add -A
  git -C "$sb" commit --quiet -m "init"
}

# ========== usage / arity ==========

@test "--help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  grep -qF "usage: audit-scope-digest.sh" <<<"$output" || return 1
}

@test "neither --capture nor --read exits non-zero with a stderr diagnostic" {
  run "$SCRIPT" --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -ne 0 ]
  grep -qF "one of --capture or --read" <<<"$output" || return 1
}

@test "a missing --root, --member, or --base each exits non-zero" {
  run "$SCRIPT" --capture --member "$MEMBER" --base "$BASE"
  [ "$status" -ne 0 ]
  run "$SCRIPT" --capture --root "$ROOT" --base "$BASE"
  [ "$status" -ne 0 ]
  run "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER"
  [ "$status" -ne 0 ]
}

@test "an unrecognized argument exits non-zero" {
  run "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE" --bogus
  [ "$status" -ne 0 ]
}

# ========== UAT-014: --capture writes, prints, records ==========

@test "UAT-014: --capture in a writable fixture root writes the scope file, prints the 64-hex digest, exits 0" {
  run "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -eq 0 ]
  digest="$output"
  [ "${#digest}" -eq 64 ]
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac

  sf="$(scope_file_for "$ROOT" "$BASE" "$MEMBER")"
  [ -f "$sf" ]
  jq -e . "$sf" >/dev/null
  [ "$(jq -r '.scope_digest' "$sf")" = "$digest" ]
  [ "$(jq -r '.member' "$sf")" = "$MEMBER" ]
  [ "$(jq -r '.schema' "$sf")" = "1" ]
}

@test "UAT-014: --capture appends exactly one kind:scope schema-2 record carrying member, branch, head, merge base, and scope digest" {
  ledger="$ROOT/.gaia/local/telemetry/audit-respawn.jsonl"
  [ ! -e "$ledger" ]
  run "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -eq 0 ]
  digest="$output"

  [ -f "$ledger" ]
  [ "$(wc -l <"$ledger" | tr -d ' ')" = "1" ]
  line="$(head -n1 "$ledger")"
  jq -e . <<<"$line" >/dev/null
  [ "$(jq -r '.schema' <<<"$line")" = "2" ]
  [ "$(jq -r '.kind' <<<"$line")" = "scope" ]
  [ "$(jq -r '.member' <<<"$line")" = "$MEMBER" ]
  [ "$(jq -r '.branch' <<<"$line")" = "main" ]
  [ "$(jq -r '.head' <<<"$line")" = "$BASE" ]
  [ "$(jq -r '.merge_base' <<<"$line")" = "$BASE" ]
  [ "$(jq -r '.scope_digest' <<<"$line")" = "$digest" ]
}

# ========== --read round-trip ==========

@test "--read returns exactly what --capture wrote, byte for byte" {
  captured="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  run "$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "$captured" ]
}

@test "--read with no prior capture prints nothing and exits non-zero" {
  run "$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "--read over a truncated / non-JSON scope file prints nothing and exits non-zero" {
  sf="$(scope_file_for "$ROOT" "$BASE" "$MEMBER")"
  mkdir -p "$(dirname "$sf")"
  printf 'not json {' >"$sf"
  run "$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "--read over a non-64-hex scope_digest prints nothing and exits non-zero" {
  sf="$(scope_file_for "$ROOT" "$BASE" "$MEMBER")"
  mkdir -p "$(dirname "$sf")"
  jq -cn '{schema:1, member:"x", scope_digest:"short", head:"h", captured_at:"t"}' >"$sf"
  run "$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ========== read-only telemetry directory ==========

@test "a read-only telemetry directory does not change --capture's stdout, stderr, or exit status" {
  require_non_root

  status_baseline=0
  digest_baseline="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE" 2>/dev/null)" || status_baseline=$?
  rm -rf "$AUDIT_DIR"

  ro_root="$BATS_TEST_TMPDIR/ro-root"
  mkdir -p "$ro_root"
  git -C "$ro_root" init --quiet --initial-branch=main
  git -C "$ro_root" config user.email "test@example.com"
  git -C "$ro_root" config user.name "Test"
  git -C "$ro_root" config commit.gpgsign false
  echo "# readme" >"$ro_root/README.md"
  git -C "$ro_root" add README.md
  git -C "$ro_root" commit --quiet -m "init"
  mkdir -p "$ro_root/.gaia/local/telemetry"
  chmod 500 "$ro_root/.gaia/local/telemetry"

  run "$SCRIPT" --capture --root "$ro_root" --member "$MEMBER" --base "$BASE"
  ro_status="$status"
  ro_stdout="$output"
  chmod 755 "$ro_root/.gaia/local/telemetry"

  [ "$ro_status" -eq "$status_baseline" ]
  [ "$ro_stdout" = "$digest_baseline" ]

  sf="$(scope_file_for "$ro_root" "$BASE" "$MEMBER")"
  [ -f "$sf" ]
}

# ========== absent respawn lib (the adopter case) ==========

@test "an absent respawn lib still succeeds, still prints the digest, appends nothing" {
  sb="$BATS_TEST_TMPDIR/sb-no-respawn"
  build_sandbox "$sb" --no-respawn-lib
  sb_base="$(git -C "$sb" rev-parse HEAD)"

  run "$sb/.gaia/scripts/audit-scope-digest.sh" --capture --root "$sb" --member "$MEMBER" --base "$sb_base"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 64 ]

  sf="$(scope_file_for "$sb" "$sb_base" "$MEMBER")"
  [ -f "$sf" ]
  [ ! -e "$sb/.gaia/local/telemetry/audit-respawn.jsonl" ]
}

# ========== unwritable scope-file directory ==========

@test "an unwritable scope-file directory makes --capture exit non-zero with a stderr diagnostic and no stdout" {
  mkdir -p "$ROOT/.gaia"
  # .gaia/local is a plain FILE, so `mkdir -p .gaia/local/audit` fails outright.
  touch "$ROOT/.gaia/local"
  run "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -ne 0 ]
  grep -qF "audit-scope-digest:" <<<"$output" || return 1
  [ -z "$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE" 2>/dev/null)" ]
}

# ========== FC-2b's fence text, verbatim, against a real member run ==========

@test "FC-2b's capture fence, run verbatim, emits the record and the printed digest" {
  # Mirrors the plan README's FC-2b/FC-2c fences exactly, substituting a
  # fixture member and AUDIT_ROOT/KEY_BASE. AUDIT_ROOT must carry the real
  # .gaia/scripts/audit-scope-digest.sh at its own relative layout, since the
  # fence invokes "$AUDIT_ROOT/.gaia/scripts/audit-scope-digest.sh" literally
  # -- so this drives a full sandbox, not the bare git fixture ROOT.
  sb="$BATS_TEST_TMPDIR/sb-fence"
  build_sandbox "$sb"
  AUDIT_ROOT="$sb"
  KEY_BASE="$(git -C "$sb" rev-parse HEAD)"

  D_SCOPE="$("$AUDIT_ROOT/.gaia/scripts/audit-scope-digest.sh" --capture --root "$AUDIT_ROOT" --member "$MEMBER" --base "$KEY_BASE")"
  [ -n "$D_SCOPE" ] || printf 'could not capture a scope digest; the earned clearance write will refuse\n' >&2

  [ -n "$D_SCOPE" ]
  [ "${#D_SCOPE}" -eq 64 ]

  ledger="$sb/.gaia/local/telemetry/audit-respawn.jsonl"
  [ -f "$ledger" ]
  [ "$(jq -r '.scope_digest' "$ledger")" = "$D_SCOPE" ]

  D_SCOPE_READ="$("$AUDIT_ROOT/.gaia/scripts/audit-scope-digest.sh" --read --root "$AUDIT_ROOT" --member "$MEMBER" --base "$KEY_BASE")"
  [ "$D_SCOPE_READ" = "$D_SCOPE" ]
}

# ========== capture idempotence, and the end-to-end staleness proof ==========
# rotate_in_scope: commit a change the MEMBER's own digest actually covers.
# README.md is outside code-audit-frontend's globs (app/**, test/**, ...), so
# committing to it rotates nothing and every assertion below it would pass
# vacuously. The non-vacuity test in this block exists to keep that honest.
rotate_in_scope() {
  mkdir -p "$ROOT/app"
  printf 'export const x = %s;\n' "$RANDOM$RANDOM" >>"$ROOT/app/rotate.ts"
  git -C "$ROOT" add app/rotate.ts
  git -C "$ROOT" commit --quiet -m "rotate content the member digest covers"
}

# These cover the defect that made the staleness gate inert on the reading the
# member definitions mandate: the scope-resolution fence a member re-runs on
# every handshake Bash call carries the --capture call, so a re-run that
# replaced the stored value would leave the writer comparing the write-time
# digest against itself. The guarantee is in the script, not in prose, so it is
# proven here against the real writer rather than asserted about a document.

@test "a second --capture returns the first value and does not replace it" {
  first="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "${#first}" -eq 64 ]

  rotate_in_scope

  second="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$second" = "$first" ]

  stored="$("$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$stored" = "$first" ]
}

@test "non-vacuity: the rotation this suite commits really does move the member digest" {
  before="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  rotate_in_scope
  after="$("$SCRIPT" --capture --recapture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$after" != "$before" ]
}

@test "--recapture replaces the stored capture" {
  first="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  rotate_in_scope

  forced="$("$SCRIPT" --capture --recapture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$forced" != "$first" ]
  stored="$("$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$stored" = "$forced" ]
}

@test "--recapture is rejected on --read" {
  run "$SCRIPT" --read --recapture --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF -- "--recapture is valid only with --capture"
}

@test "a --base carrying a path separator is rejected, not left to fail at the write" {
  run "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "origin/main"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF -- "must be a key base sha"
  # and nothing was published anywhere under the audit dir
  [ -z "$(find "$ROOT/.gaia/local" -name '*.scope.json' 2>/dev/null)" ]
}

@test "a detached HEAD resolves no key, and GAIA_AUDIT_KEY_BRANCH supplies the missing half" {
  git -C "$ROOT" checkout --quiet --detach HEAD

  run env -u GAIA_AUDIT_KEY_BRANCH "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "cannot resolve the audit key"

  run env GAIA_AUDIT_KEY_BRANCH=gaia-audit-ci "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 64 ]

  run env GAIA_AUDIT_KEY_BRANCH=gaia-audit-ci "$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 64 ]
}

@test "END TO END: a rotation between capture and write makes the earned write refuse" {
  writer="$THIS_DIR/../audit-write-clearance.sh"
  [ -x "$writer" ] || skip "audit-write-clearance.sh not executable"

  captured="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "${#captured}" -eq 64 ]

  rotate_in_scope

  # The fence re-run happens here, exactly as a member's marker-write Bash call
  # would do it, and must not launder the stale value into a fresh one.
  "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE" >/dev/null
  carried="$("$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$carried" = "$captured" ]

  run "$writer" --root "$ROOT" --member "$MEMBER" --provenance earned \
    --base "$BASE" --scope-digest "$carried"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF "review scope superseded"
  [ -z "$(find "$ROOT/.gaia/local/audit" -name '*.ok' 2>/dev/null)" ]
}

@test "END TO END control: with no rotation the same earned write succeeds" {
  writer="$THIS_DIR/../audit-write-clearance.sh"
  [ -x "$writer" ] || skip "audit-write-clearance.sh not executable"

  captured="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  carried="$("$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$carried" = "$captured" ]

  run "$writer" --root "$ROOT" --member "$MEMBER" --provenance earned \
    --base "$BASE" --scope-digest "$carried"
  [ "$status" -eq 0 ]
  [ -n "$(find "$ROOT/.gaia/local/audit" -name '*.ok' 2>/dev/null)" ]
}
