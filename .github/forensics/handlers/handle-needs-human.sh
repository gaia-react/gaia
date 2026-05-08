#!/usr/bin/env bash
# handle-needs-human.sh — UAT-003 / UAT-005 / UAT-007 / UAT-014 action handler.
#
# Labels a forensics-triaged issue as `needs-human` and posts a comment
# that mentions the maintainer (@stevensacks), names the reason-code, and
# includes the classifier (or gate / scope-checker / parser) reasoning.
# Issue stays open. The final mutation is `gaia-triaged` (idempotency key).
#
# Usage:
#   handle-needs-human.sh <issue-num> <reasoning-file> <reason-code>
#
# <reason-code> ∈ { out-of-scope, ambiguous-verdict, malformed-body, gate-failure, internal-error }
#
# Exit code: 0 on success. Non-zero on bad usage, missing file, or unknown
# reason-code. gh-level failures propagate.
#
# Contract: SPEC-002 UAT-003 / UAT-005 / UAT-007 / UAT-014.

set -euo pipefail

MAINTAINER="@stevensacks"

usage() {
  echo "usage: handle-needs-human.sh <issue-num> <reasoning-file> <reason-code>" >&2
  echo "  <reason-code> ∈ {out-of-scope, ambiguous-verdict, malformed-body, gate-failure, internal-error}" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
issue_num="$1"
reasoning_file="$2"
reason_code="$3"

[ -f "$reasoning_file" ] || { echo "handle-needs-human.sh: reasoning file not found: $reasoning_file" >&2; exit 2; }

# Map reason-code → one-line UAT summary. The summary names which UAT
# branch fired so the maintainer can locate the trigger condition fast.
case "$reason_code" in
  out-of-scope)
    summary="proposed fix touches paths outside the auto-fix allowlist (UAT-007 / UAT-014)."
    ;;
  ambiguous-verdict)
    summary="classifier verdict was missing or self-conflicting (UAT-003 case b)."
    ;;
  malformed-body)
    summary="issue body is missing or malformed against the SPEC-001 strict schema (UAT-013)."
    ;;
  gate-failure)
    summary="auto-fix branch failed the Quality Gate; branch was discarded (UAT-005)."
    ;;
  internal-error)
    summary="a forensics primitive emitted internal-error JSON; the workflow could not proceed deterministically."
    ;;
  *)
    echo "handle-needs-human.sh: unknown reason-code: $reason_code" >&2
    usage
    ;;
esac

work_dir=$(mktemp -d 2>/dev/null) || { echo "handle-needs-human.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work_dir"' EXIT

# Compose the comment body: maintainer mention + verdict header +
# reason-code summary + reasoning passthrough.
comment_file="$work_dir/comment.md"
{
  printf '%s — needs-human triage.\n\n' "$MAINTAINER"
  printf 'reason: `%s`\n\n' "$reason_code"
  printf '%s\n\n' "$summary"
  printf -- '---\n\n'
  cat "$reasoning_file"
} > "$comment_file"

# Order:
#   1. Apply `needs-human` (the classification label).
#   2. Post the comment.
#   3. Apply `gaia-triaged` LAST (idempotency key).
# The issue is NOT closed (UAT-003 / UAT-005 / UAT-007 / UAT-014 all
# specify "issue stays open").
gh issue edit "$issue_num" --add-label "needs-human"
gh issue comment "$issue_num" --body-file "$comment_file"
gh issue edit "$issue_num" --add-label "gaia-triaged"

exit 0
