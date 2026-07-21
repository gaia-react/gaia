#!/usr/bin/env bash
# audit-write-clearance.sh: the ONE shared writer for every Code Audit Team
# clearance artifact. Replaces the byte-identical inline `printf` each of the
# three agent definitions used to carry.
#
# Usage:
#   audit-write-clearance.sh --root <path> --member <name> \
#                            --provenance earned|refused \
#                            [--supersede-refusal <reason>] \
#                            [--help|-h]
#
#   --root         REQUIRED. The audited working root. The member's content
#                  digest is derived from it (never from the caller's CWD)
#                  via the digest engine (.claude/hooks/lib/audit-digest.sh),
#                  which bounds a worktree run from stamping a marker keyed to
#                  another worktree's content.
#   --member       REQUIRED. The Code Audit Team member writing the clearance.
#   --provenance   REQUIRED. earned | refused.
#   --supersede-refusal <reason>
#                  OPTIONAL, valid ONLY with --provenance earned (a usage error
#                  with refused, or with an empty/whitespace reason). A member's
#                  explicit, reasoned reversal of its OWN prior same-digest
#                  refusal: when set and a sibling <digest>[.<member>].refused
#                  exists, the earned body records a `supersedes` block naming
#                  the reason, and the writer removes that sibling refusal AFTER
#                  the earned .ok is atomically published. This is the only
#                  legitimate refused->earned path on identical content (an
#                  operator acknowledges an unaddressed Important with a stated
#                  reason, so the digest does not move). Absent the flag, an
#                  earned write NEVER touches a sibling refusal, that strict
#                  precedence is the anti-gaming control (a bare re-run must not
#                  clear a refusal; only an authored, reasoned supersede may).
#
# Behavior (all contract):
#   - Creates <root>/.gaia/local/audit/ if absent.
#   - Writes ATOMICALLY: a temp file in the target directory, then `mv`.
#   - Every write lands unconditionally: it overwrites a stale body at the
#     same path. There is no create-only guard and no carried family to
#     dominate; provenance is earned or refused only.
#   - Exit 0 on write; stdout is the marker path. Exit 2 on a usage error, when
#     the member's content digest cannot be derived, or when the body cannot be
#     built (message on stderr) -- never a marker written keyed to an empty or
#     partial digest, and never an empty or partial body published.
#   - jq is REQUIRED: it builds the body, so every value is escaped by
#     construction. Absent jq the writer fails closed rather than emitting a
#     hand-assembled body. The gate's reader requires jq for the same reason.
#
# This writer is NOT evidence-gated: it takes no --report, calls no detector,
# and its body carries no evidence block. It raises the forgery bar (a forged
# marker must now be writer-shaped) but does not close the pool's
# write-integrity weakness; that remains its own separate concern.
#
# Bash 3.2 compatible (macOS-default bash). Never `cd`.

set -uo pipefail

# The default member owns the infix-free filename family.
DEFAULT_MEMBER="code-audit-frontend"

usage() {
  cat <<'EOF' >&2
usage: audit-write-clearance.sh --root <path> --member <name>
                                --provenance earned|refused
                                [--supersede-refusal <reason>]
                                [--help|-h]

  --supersede-refusal <reason>  valid only with --provenance earned; records a
                                reasoned reversal of this member's own prior
                                same-digest refusal and removes it.
EOF
}

err() {
  printf 'audit-write-clearance: %s\n' "$1" >&2
}

# Resolve the digest engine from THIS file's own on-disk location, never cwd,
# never $ROOT: .gaia/scripts -> ../../.claude/hooks/lib.
_write_clearance_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_write_clearance_lib_dir:-}" ] && [ -f "$_write_clearance_lib_dir/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_lib_dir/audit-digest.sh"
fi

ROOT=""
MEMBER=""
PROVENANCE=""
# SUPERSEDE_SEEN records that the flag was passed at all, kept separate from
# SUPERSEDE_REASON so that an empty reason (flag present, value blank) is a
# usage error while an absent flag is the ordinary no-supersede path.
SUPERSEDE_SEEN=0
SUPERSEDE_REASON=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --member)
      MEMBER="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --provenance)
      PROVENANCE="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --supersede-refusal)
      SUPERSEDE_SEEN=1
      SUPERSEDE_REASON="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --help|-h)
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
case "$PROVENANCE" in
  earned|refused) ;;
  "")
    err "--provenance is required"
    usage
    exit 2
    ;;
  *)
    err "invalid --provenance '$PROVENANCE' (want earned|refused)"
    usage
    exit 2
    ;;
esac

# --supersede-refusal is a reasoned reversal of an EARNED write only. Reject it
# on a refusal (a refusal supersedes nothing) and reject an empty/whitespace
# reason (supersession must be auditable, so it must carry a stated reason).
if [ "$SUPERSEDE_SEEN" -eq 1 ]; then
  if [ "$PROVENANCE" != "earned" ]; then
    err "--supersede-refusal is valid only with --provenance earned"
    usage
    exit 2
  fi
  _supersede_trimmed="${SUPERSEDE_REASON#"${SUPERSEDE_REASON%%[![:space:]]*}"}"
  _supersede_trimmed="${_supersede_trimmed%"${_supersede_trimmed##*[![:space:]]}"}"
  if [ -z "$_supersede_trimmed" ]; then
    err "--supersede-refusal requires a non-empty reason"
    usage
    exit 2
  fi
fi

# The member's content digest is the marker's validity key. Fail closed: never
# write a marker keyed to an empty or partial digest.
command -v audit_member_digest >/dev/null 2>&1 || {
  err "cannot load the digest engine (.claude/hooks/lib/audit-digest.sh)"
  exit 2
}
digest="$(audit_member_digest "$ROOT" "$MEMBER" 2>/dev/null || true)"
if [ -z "$digest" ]; then
  err "cannot derive a content digest for member '$MEMBER' at --root '$ROOT'"
  exit 2
fi

# jq builds the body. Fail closed here rather than at the write, so a missing
# jq never leaves a half-provisioned audit dir behind.
command -v jq >/dev/null 2>&1 || {
  err "jq is required to write a clearance marker"
  exit 2
}

# Resolve the real HEAD tree and commit sha from the root, never from CWD.
# Plain data fields on the body now, not the filename key.
tree="$(git -C "$ROOT" rev-parse "HEAD^{tree}" 2>/dev/null || true)"
if [ -z "$tree" ]; then
  err "cannot resolve HEAD tree for --root '$ROOT'"
  exit 2
fi
sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

# Version is the .gaia/VERSION literal under the root. Advisory data, never a
# merge-gate contract.
version=""
version_file="${ROOT}/.gaia/VERSION"
if [ -f "$version_file" ]; then
  version="$(tr -d '\r' < "$version_file" | awk 'NF{print; exit}')"
  version="${version#"${version%%[![:space:]]*}"}"
  version="${version%"${version##*[![:space:]]}"}"
fi

# sidecar is true only for the default member (the only member that files a
# disposition sidecar). Derived from the member name; no CLI flag for it.
if [ "$MEMBER" = "$DEFAULT_MEMBER" ]; then
  sidecar="true"
else
  sidecar="false"
fi

audited_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

audit_dir="${ROOT}/.gaia/local/audit"

# Filename family for this member/provenance: keyed to the member's content
# digest, not the tree.
if [ "$MEMBER" = "$DEFAULT_MEMBER" ]; then
  infix=""
else
  infix=".${MEMBER}"
fi
earned_path="${audit_dir}/${digest}${infix}.ok"
refused_path="${audit_dir}/${digest}${infix}.refused"

case "$PROVENANCE" in
  earned)  target="$earned_path" ;;
  refused) target="$refused_path" ;;
esac

# Supersession is an EARNED-only, explicit act. It records the reversal in the
# body and removes the sibling refusal only when the flag was passed AND a
# same-digest refusal is actually on disk. Absent the flag, do_supersede stays
# false and the sibling refusal is never touched: an earned write can only clear
# a refusal that its author explicitly, reasonedly reverses, never a bare re-run
# (the anti-gaming invariant). With the flag but no sibling refusal, the earned
# write is a plain idempotent write, no supersedes block, no error.
do_supersede=false
if [ "$PROVENANCE" = "earned" ] && [ "$SUPERSEDE_SEEN" -eq 1 ] && [ -f "$refused_path" ]; then
  do_supersede=true
fi

mkdir -p "$audit_dir" || {
  err "cannot create audit directory '$audit_dir'"
  exit 2
}

# Atomic write: temp file in the SAME directory as the target, then mv. A torn
# marker would clear the existence-testing merge gate while failing the
# reader's stricter body check, so the publish must be a single rename.
tmp="$(mktemp "${audit_dir}/.audit-write-clearance.XXXXXX" 2>/dev/null || true)"
if [ -z "$tmp" ]; then
  err "cannot create temp file in '$audit_dir'"
  exit 2
fi

# Body built by `jq -n`, never a hand-assembled template: every value is
# escaped by construction, so a field carrying a `"` or `\` can never emit
# malformed JSON. `-c` keeps the compact single-line shape the marker's
# consumers read. A jq failure must not publish an empty or partial marker.
jq -cn \
  --arg version "$version" \
  --argjson schema 3 \
  --arg member "$MEMBER" \
  --arg provenance "$PROVENANCE" \
  --arg digest "$digest" \
  --arg tree "$tree" \
  --arg sha "$sha" \
  --arg audited_at "$audited_at" \
  --argjson sidecar "$sidecar" \
  --argjson do_supersede "$do_supersede" \
  --arg supersede_reason "$SUPERSEDE_REASON" \
  '{version: $version, schema: $schema, member: $member,
    provenance: $provenance, digest: $digest, tree: $tree, sha: $sha,
    audited_at: $audited_at, sidecar: $sidecar}
   + (if $do_supersede
      then {supersedes: {provenance: "refused", reason: $supersede_reason,
                         superseded_at: $audited_at}}
      else {} end)' \
  > "$tmp" || {
  rm -f "$tmp"
  err "cannot build the marker body"
  exit 2
}

mv -f "$tmp" "$target" || {
  rm -f "$tmp"
  err "cannot publish marker to '$target'"
  exit 2
}

# Order is load-bearing: the earned .ok is published above FIRST, the sibling
# refusal is removed here SECOND. A crash between the two leaves BOTH markers on
# disk, and the merge gate checks the refusal family first, so it stays shut
# (fail-safe). Removing the refusal first would open a window where neither an
# earned nor a refused marker exists. If the removal itself fails, the earned
# marker is already durably published, so warn and still exit 0 rather than
# reporting a false failure; the stale refusal keeps the gate shut until the
# next supersede attempt, never falsely opens it. This runs inside the writer
# subprocess, not as a Claude Bash tool call, so the destructive-command guard
# does not intercept it.
if [ "$do_supersede" = "true" ]; then
  rm -f "$refused_path" || err "warning: superseded but could not remove '$refused_path'"
fi

printf '%s\n' "$target"
exit 0
