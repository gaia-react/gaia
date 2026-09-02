#!/usr/bin/env bash
# audit-scope-digest.sh: the carry for a Code Audit Team member's own content
# digest between the two moments that must agree -- scope resolution and
# clearance write -- on the two different Bash calls a member makes for them.
#
# The clearance writer (.gaia/scripts/audit-write-clearance.sh) refuses an
# earned write whose `--scope-digest` does not match the digest it derives at
# write time. For that comparison to ever be unequal, the scope-time value
# has to survive from the member's scope-resolution Bash call to its
# marker-write Bash call, hundreds of lines later in the definition. Shell
# state does not persist between a member's Bash calls, so a variable cannot
# carry it, and RE-DERIVING it at write time would make the value
# byte-identical to the writer's own internal derive by construction -- the
# guard would be inert. The carry has to be a file; this script is the one
# reader and writer of it.
#
# Usage:
#   audit-scope-digest.sh --capture --root <path> --member <name> --base <key-base> [--help|-h]
#   audit-scope-digest.sh --read    --root <path> --member <name> --base <key-base>
#
#   --capture  Derives the member's content digest, writes the scope file,
#              appends one scope-resolution telemetry record (best-effort,
#              see below), prints the 64-hex digest on stdout, exits 0. On an
#              underivable digest or an unwritable scope file: prints nothing
#              on stdout, a diagnostic on stderr, exits non-zero. Fail loud
#              here -- the member must learn at capture time, not at write
#              time, that its clearance will refuse.
#   --read     Prints the stored 64-hex digest and exits 0. Absent,
#              unreadable, unparseable, or non-64-hex: prints nothing, exits
#              non-zero. Fails closed to empty rather than to a placeholder,
#              so a caller that feeds this straight into
#              `--scope-digest "$(...)"` gets an empty flag value. For an
#              ordinary member the writer refuses on that, the correct outcome
#              for a member that never captured. For the one contractually
#              never-blocking member it degrades to the advisory arm instead,
#              because a member that can never block a merge must not be able
#              to strand one either.
#
# Scope file: <root>/.gaia/local/audit/<audit-key>.<member>.scope.json, where
# <audit-key> is `gaia_audit_key "<key-base>" "<root>"`
# (.gaia/scripts/audit-key-lib.sh) -- base sha plus branch slug, the same
# partition the findings sidecar (<audit-key>.<member>.findings.json) and the
# re-run ledger (<audit-key>.rerun.json) already use. That partition is
# load-bearing, not decoration: .gaia/local/audit/ is registered `shared`, so
# one physical directory serves every linked worktree, and a member-only
# filename would collide across concurrent branches cut from the same base.
#
# Body: {"schema":1,"member":"...","scope_digest":"<64-hex>","head":"...",
# "captured_at":"..."}. JSON rather than a bare digest so a truncated write
# fails to parse instead of silently reading as a short digest.
#
# STALE FILES ARE NOT TOLERATED AND NOT DETECTED HERE. `--capture` is
# idempotent per audit key and member -- it returns an existing capture
# unchanged, and `--recapture` is the one deliberate override; nothing here
# checks the file's age or its recorded head against the current one. A file
# left by an earlier round is read back verbatim, the writer sees a digest
# that no longer matches the member's write-time digest, and it refuses with
# "review scope superseded" -- which is the CORRECT outcome, because the
# member's review really was scoped at the older content. Do not add a
# "helpful" freshness check here; it would silently re-derive the guard's own
# inertness.
#
# Telemetry is fail-open and adopter-safe. The scope-resolution record is
# appended through .gaia/scripts/audit-respawn-lib.sh, sourced guarded from
# this script's own on-disk location, and the append is gated on
# `command -v gaia_respawn_scope_record`. That lib is release-excluded, so on
# an adopter clone it is simply absent: the record is skipped and nothing
# else changes -- not the printed digest, not the exit status, not the scope
# file. This fail-open guard is deliberate telemetry fail-open, distinct from
# the writer's staleness check, which is fail-closed.
#
# This script SHIPS to adopters (the default member needs it), unlike the
# telemetry lib it optionally sources. It is deliberately NOT a member of
# AUDIT_MACHINERY_PATHS (.claude/hooks/lib/audit-machinery.sh) or
# GATE_MACHINERY_FILES (.gaia/scripts/audit-machinery-complete.sh): this
# script decides the value a clearance attests, which is the kind of file
# those lists exist to cover, but changing either list is out of scope here.
# The known consequence is narrower than "no member's digest": this file sits
# under `.gaia/`, which is inside the remit globs of the member that owns the
# framework shell, so an edit here DOES rotate that member's digest and does
# force it to re-review. Every OTHER member's marker stays valid across it, and
# that is the accepted gap: an edit here cannot make a member whose globs
# exclude this path re-examine what its clearance attests.
#
# Bash 3.2 compatible (macOS default). Never `cd`. Resolves every lib from
# this script's own on-disk location, never cwd, never $ROOT (the same
# discipline audit-member-digest.sh and audit-write-clearance.sh follow).

set -uo pipefail

_self_dir="$(dirname "${BASH_SOURCE[0]}")"

# The digest engine, for --capture. Sourced defensively: an unloadable lib
# must fail THIS call closed, not silently degrade, since a member that
# cannot capture must learn now rather than at write time. Resolved the same
# way audit-member-digest.sh and audit-write-clearance.sh resolve it: the
# BASH_SOURCE dirhop inline, in one assignment, rather than through the
# `_self_dir` variable below.
_scope_digest_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_scope_digest_lib_dir:-}" ] && [ -f "${_scope_digest_lib_dir}/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "${_scope_digest_lib_dir}/audit-digest.sh"
fi

# The shared key rule: base sha plus branch, the same partition the findings
# sidecar and the re-run ledger already key on.
if [ -f "${_self_dir}/audit-key-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "${_self_dir}/audit-key-lib.sh"
fi

usage() {
  cat >&2 <<'EOF'
usage: audit-scope-digest.sh --capture [--recapture] --root <path> --member <name> --base <key-base> [--help|-h]
       audit-scope-digest.sh --read    --root <path> --member <name> --base <key-base>

  --recapture  valid only with --capture; replace an existing capture for this
               audit key and member instead of returning it unchanged. For a
               caller that legitimately changed the content its review ends on
               (CI's self-heal commit), never to refresh a stale-looking value.
EOF
}

err() {
  printf 'audit-scope-digest: %s\n' "$1" >&2
}

MODE=""
ROOT=""
MEMBER=""
BASE=""
RECAPTURE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --capture)
      MODE="capture"
      shift
      ;;
    --read)
      MODE="read"
      shift
      ;;
    --recapture)
      RECAPTURE=1
      shift
      ;;
    --root)
      ROOT="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --member)
      MEMBER="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --base)
      BASE="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      err "unrecognized argument: $1"
      usage
      exit 2
      ;;
  esac
done

case "$MODE" in
  capture | read) ;;
  "")
    err "exactly one of --capture or --read is required"
    usage
    exit 2
    ;;
esac

if [ "$RECAPTURE" -eq 1 ] && [ "$MODE" != "capture" ]; then
  err "--recapture is valid only with --capture"
  usage
  exit 2
fi

if [ -z "$ROOT" ]; then
  err "--root is required"
  usage
  exit 2
fi
if [ -z "$MEMBER" ]; then
  err "--member is required"
  usage
  exit 2
fi
if [ -z "$BASE" ]; then
  err "--base is required"
  usage
  exit 2
fi
# The key is "<base>.<branch-slug>" and only the branch half is slugified, so a
# base carrying a path separator escapes into the scope-file path and the atomic
# mv below fails on a directory that was never created. Reject it here, where the
# diagnostic can name the real cause: --base takes the key BASE SHA, and a caller
# passing a ref name ("origin/main", the no-anchor answer) has a resolution bug
# upstream rather than a filesystem problem here.
case "$BASE" in
  */* | .. | . | *[!0-9A-Za-z._-]*)
    err "--base must be a key base sha, not a ref name or path: '$BASE'"
    exit 2
    ;;
esac

command -v jq >/dev/null 2>&1 || {
  err "jq is required"
  exit 1
}

command -v gaia_audit_key >/dev/null 2>&1 || {
  err "cannot load the audit key lib (.gaia/scripts/audit-key-lib.sh)"
  exit 1
}
AUDIT_KEY="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
if [ -z "$AUDIT_KEY" ]; then
  err "cannot resolve the audit key for --root '$ROOT' --base '$BASE'"
  exit 1
fi

audit_dir="${ROOT}/.gaia/local/audit"
scope_file="${audit_dir}/${AUDIT_KEY}.${MEMBER}.scope.json"

if [ "$MODE" = "read" ]; then
  [ -f "$scope_file" ] || exit 1
  digest="$(jq -r '.scope_digest // empty' "$scope_file" 2>/dev/null)" || digest=""
  # Fail closed to empty on anything but a bare 64-hex lowercase digest --
  # the same validation the digest engine itself applies to its own output.
  case "$digest" in
    *[!0-9a-f]*) digest="" ;;
  esac
  [ "${#digest}" -eq 64 ] || digest=""
  [ -n "$digest" ] || exit 1
  printf '%s\n' "$digest"
  exit 0
fi

# MODE = capture

# A capture is taken ONCE per audit key and member, at scope resolution, and a
# re-run returns that first value unchanged rather than replacing it.
#
# This is structural on purpose. The scope-resolution fence each member re-runs
# on every handshake Bash call carries this call, because shell state does not
# survive between an agent's calls and the fence is what re-derives KEY_BASE. If
# a re-run re-captured, it would overwrite the original with the WRITE-TIME
# digest, and audit-write-clearance.sh would then compare that value against
# itself: the staleness gate could never fire, and the marker it published would
# attest content the member never reviewed. Prose alone cannot prevent that,
# because the same file both mandates the re-run and forbids the re-derive, so
# the guarantee lives here instead of in an instruction a member may read
# either way.
#
# --recapture is the one deliberate override, for a caller whose review
# genuinely ends on different content than it started on.
if [ "$RECAPTURE" -ne 1 ] && [ -f "$scope_file" ]; then
  _existing="$(jq -r '.scope_digest // empty' "$scope_file" 2>/dev/null)" || _existing=""
  case "$_existing" in
    *[!0-9a-f]*) _existing="" ;;
  esac
  [ "${#_existing}" -eq 64 ] || _existing=""
  if [ -n "$_existing" ]; then
    printf '%s\n' "$_existing"
    exit 0
  fi
fi

command -v audit_member_digest >/dev/null 2>&1 || {
  err "cannot load the digest engine (.claude/hooks/lib/audit-digest.sh)"
  exit 1
}
digest="$(audit_member_digest "$ROOT" "$MEMBER" 2>/dev/null || true)"
if [ -z "$digest" ]; then
  err "cannot derive a content digest for member '$MEMBER' at --root '$ROOT'"
  exit 1
fi

mkdir -p "$audit_dir" || {
  err "cannot create audit directory '$audit_dir'"
  exit 1
}

head_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Atomic write: temp file in the SAME directory as the target, then mv. A
# torn scope file read by a concurrent member is the one shape that would
# make the writer's comparison attest a wrong digest.
tmp="$(mktemp "${audit_dir}/.audit-scope-digest.XXXXXX" 2>/dev/null || true)"
if [ -z "$tmp" ]; then
  err "cannot create temp file in '$audit_dir'"
  exit 1
fi

jq -cn \
  --argjson schema 1 \
  --arg member "$MEMBER" \
  --arg scope_digest "$digest" \
  --arg head "$head_sha" \
  --arg captured_at "$captured_at" \
  '{schema: $schema, member: $member, scope_digest: $scope_digest,
    head: $head, captured_at: $captured_at}' \
  >"$tmp" || {
  rm -f "$tmp"
  err "cannot build the scope body"
  exit 1
}

mv -f "$tmp" "$scope_file" 2>/dev/null || {
  rm -f "$tmp"
  err "cannot publish scope file to '$scope_file'"
  exit 1
}

# -----------------------------------------------------------------------------
# Scope-resolution telemetry (best-effort, fail-open, adopter-safe).
#
# This is the observation the mid-flight rotation count needs: the re-spawn
# ledger's spawn breadcrumb alone cannot see a rotation that lands WHILE a
# member is reviewing, because a member still mid-review has written no
# marker to lose. Recording the scope-time digest here, paired forward
# against the next spawn breadcrumb by the attribution query, makes that
# case countable.
#
# Sourced guarded, exactly like the digest and key libs above, but the
# consequence of an absent lib is different: this lib is release-excluded
# (an adopter clone never has it), and its absence must never fail this
# script, never change the printed digest, and never change whether the
# scope file was written. Only the telemetry append is skipped.
# -----------------------------------------------------------------------------
if [ -f "${_self_dir}/audit-respawn-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "${_self_dir}/audit-respawn-lib.sh"
fi
if command -v gaia_respawn_scope_record >/dev/null 2>&1; then
  _scope_ledger="$(gaia_respawn_ledger_path "$ROOT" 2>/dev/null || true)"
  if [ -n "$_scope_ledger" ]; then
    _scope_branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
    gaia_respawn_scope_record "$_scope_ledger" "$captured_at" "$_scope_branch" \
      "$head_sha" "$BASE" "$MEMBER" "$digest" || true
  fi
fi

printf '%s\n' "$digest"
exit 0
