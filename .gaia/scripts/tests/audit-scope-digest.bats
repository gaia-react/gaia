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

# The SPENT-capture arm. A round that REFUSES does not advance the audit key, so
# without this the next round inherits the refused round's capture and the
# earned write refuses "review scope superseded" on every re-dispatch, forever.
# The discriminator is a published conclusion, not age: these tests and the
# "a second --capture returns the first value" test above are a matched pair
# over the SAME rotation, differing only in whether a conclusion exists.

publish_conclusion() {
  # $1 digest, $2 suffix (.ok|.refused), $3 optional member infix
  mkdir -p "$ROOT/.gaia/local/audit"
  : >"$ROOT/.gaia/local/audit/${1}${3:-}${2}"
}

@test "spent: a capture with a published REFUSAL is replaced on the next round" {
  first="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  publish_conclusion "$first" .refused
  rotate_in_scope

  second="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$second" != "$first" ]

  stored="$("$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$stored" = "$second" ]
}

@test "spent: a published MARKER spends the capture too, not only a refusal" {
  first="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  publish_conclusion "$first" .ok
  rotate_in_scope

  second="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$second" != "$first" ]
}

# For a SPECIALIST the digest is a poor probe: rotate_in_scope commits under
# app/, which no specialist's digest covers, so the value cannot move whether
# the capture was replaced or kept. The scope file's recorded `head` is the
# probe that answers directly, and it works for either outcome.
stored_head_for() {
  local sf
  sf="$(ls "$ROOT"/.gaia/local/audit/*."${1}".scope.json 2>/dev/null | head -1)"
  [ -n "$sf" ] || return 1
  jq -r '.head // empty' "$sf"
}

@test "spent: a specialist's conclusion is found under its own member infix" {
  local m="code-audit-github-workflows"
  first="$("$SCRIPT" --capture --root "$ROOT" --member "$m" --base "$BASE")"
  before_head="$(stored_head_for "$m")"
  publish_conclusion "$first" .refused ".${m}"
  rotate_in_scope

  "$SCRIPT" --capture --root "$ROOT" --member "$m" --base "$BASE" >/dev/null
  after_head="$(stored_head_for "$m")"
  [ "$after_head" != "$before_head" ]
  [ "$after_head" = "$(git -C "$ROOT" rev-parse HEAD)" ]
}

@test "spent: ANOTHER member's conclusion does not spend this member's capture" {
  # The infix is what keys the lookup to this member. Written bare, a
  # specialist would read a different member's conclusion as its own.
  local m="code-audit-github-workflows"
  first="$("$SCRIPT" --capture --root "$ROOT" --member "$m" --base "$BASE")"
  before_head="$(stored_head_for "$m")"
  publish_conclusion "$first" .refused ".code-audit-maintainer-node"
  rotate_in_scope

  second="$("$SCRIPT" --capture --root "$ROOT" --member "$m" --base "$BASE")"
  [ "$second" = "$first" ]
  # The decisive half: the file was not rewritten, so the capture was KEPT
  # rather than coincidentally re-deriving the same digest.
  [ "$(stored_head_for "$m")" = "$before_head" ]
}

@test "the spent lookup and the writer agree on the default member's bare infix" {
  # audit-scope-digest.sh builds the conclusion filename itself, so its notion of
  # "which member gets no infix" must equal audit-write-clearance.sh's. A drift
  # here makes the lookup miss every conclusion for one member, silently.
  writer="$THIS_DIR/../audit-write-clearance.sh"
  [ -f "$writer" ] || skip "audit-write-clearance.sh not present"

  scope_default="$(grep -oE '^SCOPE_DEFAULT_MEMBER="[^"]+"' "$SCRIPT" | head -1 | sed 's/.*="//;s/"$//')"
  writer_default="$(grep -oE '^DEFAULT_MEMBER="[^"]+"' "$writer" | head -1 | sed 's/.*="//;s/"$//')"

  [ -n "$scope_default" ]
  [ -n "$writer_default" ]
  [ "$scope_default" = "$writer_default" ]
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

@test "END TO END: a REFUSED round does not strand the round that repairs it" {
  # The C1 regression test, at the level the defect actually lived. Round N
  # refuses; the repair rotates the member digest; round N+1 re-dispatches at
  # the SAME audit key, because only a clean round advances the key's base. The
  # unit tests above cover the spent lookup; this proves the whole loop, through
  # the real writer, ends in a marker instead of a permanent refusal.
  writer="$THIS_DIR/../audit-write-clearance.sh"
  [ -x "$writer" ] || skip "audit-write-clearance.sh not executable"

  # --- round N: capture, find something, refuse ---
  captured="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  run "$writer" --root "$ROOT" --member "$MEMBER" --provenance refused \
    --base "$BASE" --scope-digest "$captured"
  [ "$status" -eq 0 ]
  [ -n "$(find "$ROOT/.gaia/local/audit" -name '*.refused' 2>/dev/null)" ]

  # --- the repair that answers the refusal, which rotates the digest ---
  rotate_in_scope

  # --- round N+1: same key, because the refusal advanced nothing ---
  recaptured="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$recaptured" != "$captured" ]

  carried="$("$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$carried" = "$recaptured" ]

  run "$writer" --root "$ROOT" --member "$MEMBER" --provenance earned \
    --base "$BASE" --scope-digest "$carried"
  [ "$status" -eq 0 ]
  [ -n "$(find "$ROOT/.gaia/local/audit" -name '*.ok' 2>/dev/null)" ]
}

# rotate_machinery: commit a change EVERY member's digest covers, specialists
# included. rotate_in_scope above commits under app/, which only the default
# member's digest reaches, so it cannot move a specialist's value and any
# specialist assertion resting on it would pass vacuously.
rotate_machinery() {
  mkdir -p "$ROOT/.gaia"
  printf '%s\n' "$RANDOM$RANDOM" >>"$ROOT/.gaia/VERSION"
  git -C "$ROOT" add .gaia/VERSION
  git -C "$ROOT" commit --quiet -m "rotate machinery every member digest covers"
}

# The C1 regression block. The tests above cover a round that ends by PUBLISHING
# something; these cover the third case the spent test cannot see -- a round that
# ends having published nothing at all (the dirty-tree withhold, a forfeiture, a
# crash). Its capture survives it, and without the writer's release arm the next
# round refuses on the stale value and publishes nothing either, which strands
# every round after it. The escape is in audit-write-clearance.sh, so these drive
# the REAL writer rather than the lookup alone.

@test "END TO END: a round that publishes NOTHING does not strand the round after it" {
  writer="$THIS_DIR/../audit-write-clearance.sh"
  [ -x "$writer" ] || skip "audit-write-clearance.sh not executable"

  # --- round A: captures, then ends having published nothing ---
  captured="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ -z "$(find "$ROOT/.gaia/local/audit" -name '*.ok' -o -name '*.refused' 2>/dev/null)" ]

  # --- the operator commits, which is what the withhold prose asks for ---
  rotate_in_scope

  # --- round B: inherits the stale capture, so its earned write forfeits ---
  inherited="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$inherited" = "$captured" ]
  run "$writer" --root "$ROOT" --member "$MEMBER" --provenance earned \
    --base "$BASE" --scope-digest "$inherited"
  [ "$status" -eq 2 ]
  [ -z "$(find "$ROOT/.gaia/local/audit" -name '*.ok' 2>/dev/null)" ]

  # The forfeiture released the capture. Without this the next round inherits
  # the same stale value and refuses identically, forever.
  [ ! -f "$(scope_file_for "$ROOT" "$BASE" "$MEMBER")" ]

  # --- round C: captures fresh and clears ---
  fresh="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  [ "$fresh" != "$captured" ]
  run "$writer" --root "$ROOT" --member "$MEMBER" --provenance earned \
    --base "$BASE" --scope-digest "$fresh"
  [ "$status" -eq 0 ]
  [ -n "$(find "$ROOT/.gaia/local/audit" -name '*.ok' 2>/dev/null)" ]
}

@test "END TO END: the same recovery holds for a SPECIALIST member" {
  writer="$THIS_DIR/../audit-write-clearance.sh"
  [ -x "$writer" ] || skip "audit-write-clearance.sh not executable"
  local m="code-audit-maintainer-shell"

  captured="$("$SCRIPT" --capture --root "$ROOT" --member "$m" --base "$BASE")"
  # Machinery, not app/: a specialist's digest does not reach app/, so
  # rotate_in_scope would leave `captured` valid and the forfeiture below would
  # never fire -- the test would pass without exercising anything.
  rotate_machinery
  [ "$("$SCRIPT" --read --root "$ROOT" --member "$m" --base "$BASE")" = "$captured" ]

  run "$writer" --root "$ROOT" --member "$m" --provenance earned \
    --base "$BASE" --scope-digest "$captured"
  [ "$status" -eq 2 ]
  [ ! -f "$(scope_file_for "$ROOT" "$BASE" "$m")" ]

  fresh="$("$SCRIPT" --capture --root "$ROOT" --member "$m" --base "$BASE")"
  [ "$fresh" != "$captured" ]
  run "$writer" --root "$ROOT" --member "$m" --provenance earned \
    --base "$BASE" --scope-digest "$fresh"
  [ "$status" -eq 0 ]
  [ -f "$ROOT/.gaia/local/audit/${fresh}.${m}.ok" ]
}

@test "the release is specific to a forfeiture: a running review keeps its capture" {
  # The guarantee the keep arm exists for. A member re-runs the scope fence on
  # every handshake Bash call; if the release were unconditional rather than
  # bound to the superseded refusal, that re-run would hand the writer the
  # write-time digest and it would compare a value against itself.
  captured="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  rotate_in_scope
  "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE" >/dev/null
  [ -f "$(scope_file_for "$ROOT" "$BASE" "$MEMBER")" ]
  [ "$("$SCRIPT" --read --root "$ROOT" --member "$MEMBER" --base "$BASE")" = "$captured" ]
}

@test "the release is bound to the superseded arm: a not-supplied refusal keeps the capture" {
  # Placement pin. The gate has three failing arms and only ONE of them means
  # "this round reviewed content that has since moved". A member that simply
  # omitted --scope-digest has told us nothing about whether its review ended,
  # so discarding its capture there would throw away a running review's fence
  # value on a caller error.
  writer="$THIS_DIR/../audit-write-clearance.sh"
  [ -x "$writer" ] || skip "audit-write-clearance.sh not executable"

  "$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE" >/dev/null
  rotate_in_scope
  run "$writer" --root "$ROOT" --member "$MEMBER" --provenance earned --base "$BASE"
  [ "$status" -eq 2 ]
  [ -f "$(scope_file_for "$ROOT" "$BASE" "$MEMBER")" ]
}

@test "the release is bound to the EARNED path: a refusal write keeps the capture" {
  # Refusals are exempt from the staleness gate entirely, so they must not
  # reach the release either. A refusal lands at the WRITE-TIME digest, which
  # never spends the captured one, so releasing here would discard the capture
  # of a member that is still mid-round.
  writer="$THIS_DIR/../audit-write-clearance.sh"
  [ -x "$writer" ] || skip "audit-write-clearance.sh not executable"

  captured="$("$SCRIPT" --capture --root "$ROOT" --member "$MEMBER" --base "$BASE")"
  rotate_in_scope
  run "$writer" --root "$ROOT" --member "$MEMBER" --provenance refused \
    --base "$BASE" --scope-digest "$captured"
  [ "$status" -eq 0 ]
  [ -f "$(scope_file_for "$ROOT" "$BASE" "$MEMBER")" ]
}
