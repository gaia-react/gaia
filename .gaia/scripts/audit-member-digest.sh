#!/usr/bin/env bash
# audit-member-digest.sh: CLI entrypoint over the per-member branch-own digest,
# for non-sourcing callers (CI, the clearance writer, the light-review steps).
# Prints the member's line of the digest library's local-base listing, the
# 64-hex digest, on stdout and exits 0. The digest is measured against the local
# base reference, and `--ref` names the tree-ish whose patch is digested (HEAD by
# default; a bare tree id works because the merge base is always derived from
# HEAD). On ANY fail-closed condition (missing sha256 tool, unloadable library,
# no local base reference, a merge base that is not unique, absent member) it
# prints nothing and exits NON-ZERO. CI and the merge gate rely on a non-zero
# exit meaning "could not derive, fail closed" -- it is never swallowed into 0.
#
# Bash 3.2 compatible. Never `cd` (outside the source-time lib resolution).
set -uo pipefail

# Source the digest lib from THIS script's own on-disk location, never cwd:
# .gaia/scripts -> ../../.claude/hooks/lib.
_self_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_self_library_directory:-}" ] && [ -f "$_self_library_directory/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_library_directory/audit-digest.sh"
fi

usage() {
  cat >&2 <<'EOF'
usage: audit-member-digest.sh --root <path> --member <name> [--ref <tree-ish>] [--help|-h]
EOF
}

root=""
member=""
git_reference="HEAD"
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
      git_reference="${2:-}"
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

if ! command -v audit_branch_digests_local >/dev/null 2>&1; then
  printf 'audit-member-digest.sh: digest library unavailable\n' >&2
  exit 1
fi

# Fail closed: propagate the digest listing's non-zero exit verbatim (never swallow).
digest_lines="$(audit_branch_digests_local "$root" "$git_reference")" || exit 1
digest=""
tab="$(printf '\t')"
while IFS= read -r digest_line; do
  if [ "${digest_line%%"$tab"*}" = "$member" ]; then
    digest="${digest_line#*"$tab"}"
    break
  fi
done <<<"$digest_lines"
if [ -z "$digest" ]; then
  exit 1
fi
printf '%s\n' "$digest"
exit 0
