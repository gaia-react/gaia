#!/usr/bin/env bash
# audit-member-digest.sh: CLI entrypoint over the per-member content digest, for
# non-sourcing callers (CI, the clearance writer). Prints the 64-hex digest for
# a member on stdout and exits 0; on ANY fail-closed condition (missing sha256
# tool, unloadable classifier/machinery lib, failing git ls-tree, absent member)
# it prints nothing and exits NON-ZERO. CI and the merge gate rely on a non-zero
# exit meaning "could not derive, fail closed" -- it is never swallowed into 0.
#
# Bash 3.2 compatible. Never `cd` (outside the source-time lib resolution).
set -uo pipefail

# Source the digest lib from THIS script's own on-disk location, never cwd:
# .gaia/scripts -> ../../.claude/hooks/lib.
_self_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_self_lib_dir:-}" ] && [ -f "$_self_lib_dir/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_lib_dir/audit-digest.sh"
fi

usage() {
  cat >&2 <<'EOF'
usage: audit-member-digest.sh --root <path> --member <name> [--ref <ref>] [--help|-h]
EOF
}

root=""
member=""
ref="HEAD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      root="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --member)
      member="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --ref)
      ref="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      printf 'audit-member-digest.sh: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$root" ]; then
  printf 'audit-member-digest.sh: --root is required\n' >&2
  usage
  exit 2
fi
if [ -z "$member" ]; then
  printf 'audit-member-digest.sh: --member is required\n' >&2
  usage
  exit 2
fi

if ! command -v audit_member_digest >/dev/null 2>&1; then
  printf 'audit-member-digest.sh: digest library unavailable\n' >&2
  exit 1
fi

# Fail closed: propagate the digest's non-zero exit verbatim (never swallow).
digest="$(audit_member_digest "$root" "$member" "$ref")" || exit 1
if [ -z "$digest" ]; then
  exit 1
fi
printf '%s\n' "$digest"
exit 0
