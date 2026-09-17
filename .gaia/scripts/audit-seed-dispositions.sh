#!/usr/bin/env bash
# shellcheck shell=bash
#
# Seeds the default member's disposition-ledger sidecar forward from the prior
# frontend digest's sidecar, by running disposition_seed_forward
# (.claude/hooks/lib/audit-dispositions.sh) as one plain command.
#
# Why a script: the function is only reachable by sourcing its library. A
# member's Bash call starts with nothing sourced, so a bare call fails with
# `command not found`, and a source-then-call block is a multi-command shape a
# member dispatched into a linked worktree has no evidence it may run. A script
# invoked by its literal path is the shape that runs there. The library stays
# sourced-only, since both merge gates source it.
#
# Usage:
#   <root>/.gaia/scripts/audit-seed-dispositions.sh --root <root>
#       --prev-digest <digest> --new-digest <digest>
#
#   --root         The working root whose .gaia/local/audit/ holds both
#                  sidecars. Must resolve, physically, to the tree this script
#                  sits in.
#   --prev-digest  The prior frontend digest audit-member-digest.sh printed at
#                  the incremental base. Empty is a no-op: no resolvable base,
#                  or a digest engine that failed, leaves nothing to seed from.
#   --new-digest   The frontend digest the marker and the new sidecar key to.
#
# Both digests must be 64 lowercase hex characters (a non-empty prior one
# included), because each becomes a file name under the audit directory and
# nothing else may.
#
# Exit status:
#   0  seeded, or a no-op: an empty prior digest, an absent or unparseable
#      prior sidecar, or no jq. The last three are disposition_seed_forward's
#      own fail-safe contract, which a still-open receipt costs nothing to
#      honour: the prior sidecar stays on disk.
#   2  usage error, a digest that is not 64 lowercase hex, a missing library,
#      or a --root this script refuses.

_asd_usage() {
  printf 'usage: audit-seed-dispositions.sh --root <root> --prev-digest <digest> --new-digest <digest>\n' >&2
}

root_arg=""
root_given=0
prev=""
prev_given=0
new=""
new_given=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { _asd_usage; exit 2; }
      root_arg="$2"; root_given=1; shift 2 ;;
    --prev-digest)
      [ "$#" -ge 2 ] || { _asd_usage; exit 2; }
      prev="$2"; prev_given=1; shift 2 ;;
    --new-digest)
      [ "$#" -ge 2 ] || { _asd_usage; exit 2; }
      new="$2"; new_given=1; shift 2 ;;
    -h|--help)
      _asd_usage; exit 0 ;;
    *)
      printf 'audit-seed-dispositions: unknown argument: %s\n' "$1" >&2
      _asd_usage; exit 2 ;;
  esac
done

if [ "$root_given" -eq 0 ] || [ "$prev_given" -eq 0 ] || [ "$new_given" -eq 0 ]; then
  _asd_usage
  exit 2
fi

# An empty --root is refused before the cd below: `cd ""` returns 0 on bash
# 3.2 (macOS /bin/bash) and would resolve the ambient directory.
if [ -z "$root_arg" ]; then
  printf 'audit-seed-dispositions: --root is empty; refusing rather than resolving the ambient directory\n' >&2
  exit 2
fi

self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)"
root="$(cd "$root_arg" 2>/dev/null && pwd -P)"
if [ -z "$self_root" ] || [ -z "$root" ]; then
  printf "audit-seed-dispositions: --root '%s' does not resolve to a directory\n" "$root_arg" >&2
  exit 2
fi
if [ "$root" != "$self_root" ]; then
  printf "audit-seed-dispositions: --root '%s' resolves to %s, not to %s, the tree this script belongs to; run the copy under the root you are auditing\n" \
    "$root_arg" "$root" "$self_root" >&2
  exit 2
fi

_asd_is_digest() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

if ! _asd_is_digest "$new"; then
  printf "audit-seed-dispositions: --new-digest '%s' is not 64 lowercase hex\n" "$new" >&2
  exit 2
fi
[ -n "$prev" ] || exit 0
if ! _asd_is_digest "$prev"; then
  printf "audit-seed-dispositions: --prev-digest '%s' is not 64 lowercase hex\n" "$prev" >&2
  exit 2
fi

lib="$root/.claude/hooks/lib/audit-dispositions.sh"
if [ ! -f "$lib" ]; then
  printf 'audit-seed-dispositions: disposition library missing at %s\n' "$lib" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$lib"

disposition_seed_forward \
  "$root/.gaia/local/audit/${prev}.dispositions.json" \
  "$root/.gaia/local/audit/${new}.dispositions.json"
exit 0
