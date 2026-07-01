#!/usr/bin/env bash
# handle-already-triaged.sh: UAT-006 idempotency early-exit.
#
# Logs a `::notice::` line and exits 0. No comment, no label, no PR.
# Called when the workflow finds the `gaia-triaged` label already on the
# issue (e.g. due to UAT-011's concurrency-queued re-fire after a label
# add/remove).
#
# Usage:
#   handle-already-triaged.sh <issue-num>
#
# Contract: UAT-006.

set -euo pipefail

usage() {
  echo "usage: handle-already-triaged.sh <issue-num>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
issue_num="$1"

printf '::notice::issue #%s already triaged; skipping\n' "$issue_num"

exit 0
