#!/usr/bin/env bash
# audit-write-clearance.sh: the ONE shared writer for every Code Audit Team
# clearance artifact. Replaces the byte-identical inline `printf` each of the
# three agent definitions used to carry.
#
# Usage:
#   audit-write-clearance.sh --root <path> --member <name> \
#                            --provenance earned|carried|refused \
#                            [--anchor-tree <sha>]   # REQUIRED when carried
#                            [--help|-h]
#
#   --root         REQUIRED. The audited working root. The tree is resolved
#                  with `git -C <root> rev-parse HEAD^{tree}`, never from the
#                  caller's CWD, which bounds a worktree run from stamping a
#                  marker keyed to another tree.
#   --member       REQUIRED. The Code Audit Team member writing the clearance.
#   --provenance   REQUIRED. earned | carried | refused.
#   --anchor-tree  REQUIRED for --provenance carried; the tree the carried
#                  clearance was carried forward FROM.
#
# Behavior (all contract):
#   - Creates <root>/.gaia/local/audit/ if absent.
#   - Writes ATOMICALLY: a temp file in the target directory, then `mv`.
#   - Earned strictly dominates carried. An `earned` write lands
#     unconditionally: it overwrites a legacy-bodied marker at the same path
#     and removes the member's carried artifact for that tree if one exists.
#     There is NO `[ ! -f "$marker" ]` guard.
#   - A `carried` write is create-only: it never overwrites an EARNED marker,
#     and declines (`declined: earned-clearance-exists`) when one exists.
#   - Exit 0 on any decided outcome; stdout is the marker path on a write, or
#     `declined: earned-clearance-exists` when a carried write is blocked.
#     Exit 2 on a usage error (message on stderr).
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
                                --provenance earned|carried|refused
                                [--anchor-tree <sha>]  # required when carried
                                [--help|-h]
EOF
}

err() {
  printf 'audit-write-clearance: %s\n' "$1" >&2
}

ROOT=""
MEMBER=""
PROVENANCE=""
ANCHOR_TREE=""

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
    --anchor-tree)
      ANCHOR_TREE="${2:-}"
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
  earned|carried|refused) ;;
  "")
    err "--provenance is required"
    usage
    exit 2
    ;;
  *)
    err "invalid --provenance '$PROVENANCE' (want earned|carried|refused)"
    usage
    exit 2
    ;;
esac
if [ "$PROVENANCE" = "carried" ] && [ -z "$ANCHOR_TREE" ]; then
  err "--anchor-tree is required when --provenance is carried"
  usage
  exit 2
fi

# Resolve the audited tree and HEAD commit from the root, never from CWD.
tree="$(git -C "$ROOT" rev-parse "HEAD^{tree}" 2>/dev/null || true)"
if [ -z "$tree" ]; then
  err "cannot resolve HEAD tree for --root '$ROOT'"
  exit 2
fi
sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

# Version is the .gaia/VERSION literal under the root. Advisory to
# carry-forward, never a merge-gate contract.
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

# Filename family for this member/provenance.
if [ "$MEMBER" = "$DEFAULT_MEMBER" ]; then
  infix=""
else
  infix=".${MEMBER}"
fi
earned_path="${audit_dir}/${tree}${infix}.ok"
carried_path="${audit_dir}/${tree}${infix}.carried"
refused_path="${audit_dir}/${tree}${infix}.refused"

case "$PROVENANCE" in
  earned)  target="$earned_path" ;;
  carried) target="$carried_path" ;;
  refused) target="$refused_path" ;;
esac

# Carried is create-only: it never overwrites an earned marker.
if [ "$PROVENANCE" = "carried" ] && [ -f "$earned_path" ]; then
  printf 'declined: earned-clearance-exists\n'
  exit 0
fi

mkdir -p "$audit_dir" || {
  err "cannot create audit directory '$audit_dir'"
  exit 2
}

# Earned strictly dominates carried: remove any carried artifact for this
# tree/member before landing the earned marker.
if [ "$PROVENANCE" = "earned" ]; then
  rm -f "$carried_path"
fi

# Atomic write: temp file in the SAME directory as the target, then mv. A torn
# marker would clear the existence-testing merge gate while failing
# carry-forward's stricter body check, so the publish must be a single rename.
tmp="$(mktemp "${audit_dir}/.audit-write-clearance.XXXXXX" 2>/dev/null || true)"
if [ -z "$tmp" ]; then
  err "cannot create temp file in '$audit_dir'"
  exit 2
fi

if [ "$PROVENANCE" = "carried" ]; then
  printf '{"version":"%s","schema":2,"member":"%s","provenance":"%s","sha":"%s","tree":"%s","audited_at":"%s","sidecar":%s,"anchor_tree":"%s"}\n' \
    "$version" "$MEMBER" "$PROVENANCE" "$sha" "$tree" "$audited_at" "$sidecar" "$ANCHOR_TREE" \
    > "$tmp"
else
  printf '{"version":"%s","schema":2,"member":"%s","provenance":"%s","sha":"%s","tree":"%s","audited_at":"%s","sidecar":%s}\n' \
    "$version" "$MEMBER" "$PROVENANCE" "$sha" "$tree" "$audited_at" "$sidecar" \
    > "$tmp"
fi

mv -f "$tmp" "$target" || {
  rm -f "$tmp"
  err "cannot publish marker to '$target'"
  exit 2
}

printf '%s\n' "$target"
exit 0
