#!/usr/bin/env bash
# audit-write-clearance.sh: the ONE shared writer for every Code Audit Team
# clearance artifact. Replaces the byte-identical inline `printf` each of the
# three agent definitions used to carry.
#
# Usage:
#   audit-write-clearance.sh --root <path> --member <name> \
#                            --provenance earned|refused \
#                            [--help|-h]
#
#   --root         REQUIRED. The audited working root. The member's content
#                  digest is derived from it (never from the caller's CWD)
#                  via the digest engine (.claude/hooks/lib/audit-digest.sh),
#                  which bounds a worktree run from stamping a marker keyed to
#                  another worktree's content.
#   --member       REQUIRED. The Code Audit Team member writing the clearance.
#   --provenance   REQUIRED. earned | refused.
#
# Behavior (all contract):
#   - Creates <root>/.gaia/local/audit/ if absent.
#   - Writes ATOMICALLY: a temp file in the target directory, then `mv`.
#   - Every write lands unconditionally: it overwrites a stale body at the
#     same path. There is no create-only guard and no carried family to
#     dominate; provenance is earned or refused only.
#   - Exit 0 on write; stdout is the marker path. Exit 2 on a usage error, or
#     when the member's content digest cannot be derived (message on
#     stderr) -- never a marker written keyed to an empty or partial digest.
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
                                [--help|-h]
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

printf '{"version":"%s","schema":3,"member":"%s","provenance":"%s","digest":"%s","tree":"%s","sha":"%s","audited_at":"%s","sidecar":%s}\n' \
  "$version" "$MEMBER" "$PROVENANCE" "$digest" "$tree" "$sha" "$audited_at" "$sidecar" \
  > "$tmp"

mv -f "$tmp" "$target" || {
  rm -f "$tmp"
  err "cannot publish marker to '$target'"
  exit 2
}

printf '%s\n' "$target"
exit 0
