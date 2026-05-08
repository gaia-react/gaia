#!/usr/bin/env bash
# handle-malformed-body.sh — UAT-013 short-circuit handler.
#
# The body parser flagged the issue as `valid:false`. Without invoking
# the LLM (UAT-013 forbids LLM fallback for parse failures), label the
# issue `needs-human` and post a comment naming the missing/malformed
# sections. Issue stays open. No fix attempt.
#
# Usage:
#   handle-malformed-body.sh <issue-num> <parser-output-file>
#
# <parser-output-file> path to the captured JSON output of
# `.github/forensics/parse-issue-body.sh`. Schema:
#   {
#     "valid": false,
#     "error": "<error-code>",
#     "missing": ["symptom", ...],
#     "malformed": ["frontmatter", ...]
#   }
#
# Exit code: 0 on success. 2 on bad usage / missing input. gh-level
# failures propagate.
#
# Contract: SPEC-002 UAT-013. Idempotency key (`gaia-triaged`) is the
# final mutation.

set -euo pipefail

usage() {
  echo "usage: handle-malformed-body.sh <issue-num> <parser-output-file>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
issue_num="$1"
parser_output_file="$2"

[ -f "$parser_output_file" ] || { echo "handle-malformed-body.sh: parser output file not found: $parser_output_file" >&2; exit 2; }

# Extract error code + missing[] + malformed[] from the parser JSON. jq
# is available in GitHub Actions runners and is already used by sibling
# helpers (bootstrap-labels.sh).
error_code="$(jq -r '.error // "unknown"' "$parser_output_file")"
missing_csv="$(jq -r '(.missing // []) | join(", ")' "$parser_output_file")"
malformed_csv="$(jq -r '(.malformed // []) | join(", ")' "$parser_output_file")"

work_dir=$(mktemp -d 2>/dev/null) || { echo "handle-malformed-body.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work_dir"' EXIT

comment_file="$work_dir/comment.md"
{
  printf 'verdict: needs-human (malformed body — UAT-013).\n\n'
  printf 'The forensics issue body did not match the SPEC-001 strict schema, so triage stopped before classification (no LLM fallback per UAT-013).\n\n'
  printf 'parser error: `%s`\n\n' "$error_code"
  if [ -n "$missing_csv" ]; then
    printf 'missing sections: `%s`\n\n' "$missing_csv"
  fi
  if [ -n "$malformed_csv" ]; then
    printf 'malformed sections: `%s`\n\n' "$malformed_csv"
  fi
  printf 'Required schema: `## Symptom`, `## Classification`, `## Capture`, `## Reproduction context` plus YAML frontmatter (`class`, `gaia_version`, `created`).\n'
} > "$comment_file"

# Order:
#   1. `needs-human` (classification label).
#   2. Comment.
#   3. `gaia-triaged` LAST (idempotency key).
gh issue edit "$issue_num" --add-label "needs-human"
gh issue comment "$issue_num" --body-file "$comment_file"
gh issue edit "$issue_num" --add-label "gaia-triaged"

exit 0
