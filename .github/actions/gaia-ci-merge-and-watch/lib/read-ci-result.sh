#!/usr/bin/env bash
# Runs wait-for-ci.sh and hands the caller a payload it can filter without
# bracketing every read. Emits one line of JSON, always parseable, and exits
# with wait-for-ci.sh's own status so the caller still branches on it.
#
# On a readable payload this forwards it byte-for-byte, so every conclusion the
# poller documents reaches the caller unchanged. On an unreadable one it
# substitutes:
#   {"conclusion":"unknown","run_url":"","error":"wait-for-ci.sh exited <n> without emitting readable JSON"}
#
# Why the substitution is worth a process of its own: the caller's reads are jq
# filters over this value, so an unparseable payload fails the first one and
# kills the caller under `set -e` before its error annotation runs, handing the
# operator a jq parse error in place of the diagnosis. The guard therefore has
# to sit OUTSIDE the program that might emit the unreadable bytes -- a trap
# inside wait-for-ci.sh cannot cover being killed mid-write, and cannot unsay
# a partial line already on stdout. This wrapper is that outside: its only
# long-running child is the poller, and it outlives that child by construction.
#
# It exists as a file rather than as a copy inside each caller because it had
# been the latter, in two `run:` bodies of the composite action, where no `*.sh`
# glob reached it: the parseability guard above was itself a repair that had to
# be applied by hand to both copies, and nothing in the repository would have
# gone red had it landed on one (gaia-react/gaia#1704). Living here it is one
# copy, and one shellcheck reaches.
# gaia:maintainer-only:start
# .gaia/scripts/tests/read-ci-result.bats holds it to the contract above.
# gaia:maintainer-only:end
#
# Args:
#   $1: commit SHA to query, forwarded to wait-for-ci.sh.
# Env: wait-for-ci.sh's own; this wrapper reads none of its own.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `rc=0` then `|| rc=$?`, never a bare assignment followed by `rc=$?`: an
# assignment takes its command substitution's status, so under `set -e` the
# poller's two non-terminal conclusions would kill this script on the assignment
# line with the JSON that says which one still unread inside the variable.
rc=0
result_json="$("$HERE/wait-for-ci.sh" "$@")" || rc=$?

# Parseability, not emptiness: `jq -e .` rejects the empty string too, so it
# subsumes an emptiness check rather than sitting beside one.
if ! jq -e . >/dev/null 2>&1 <<<"$result_json"; then
  result_json="$(jq -c -n --arg rc "$rc" '{conclusion: "unknown", run_url: "", error: ("wait-for-ci.sh exited " + $rc + " without emitting readable JSON")}')"
fi

printf '%s\n' "$result_json"
exit "$rc"
