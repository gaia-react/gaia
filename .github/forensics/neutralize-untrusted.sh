#!/usr/bin/env bash
# neutralize-untrusted.sh: defang attacker-controlled issue-section text
# before it is substituted into an LLM prompt (SEC-2, forensics-audit-fixes).
#
# Usage:
#   safe="$(neutralize-untrusted.sh "$untrusted_value")"
#
# Reads one untrusted value from argv, writes the neutralized value to
# stdout (trailing newline). The workflow calls this on each untrusted
# issue section (`$symptom`, `$classification`, `$capture`, `$repro`) before
# passing it to `render-prompt.sh`, so the renderer's literal-substitution
# contract stays untouched (README contract 9) while the substituted values
# can no longer break out of their prompt data region.
#
# This is a separate, bats-testable primitive for the same reason
# `render-prompt.sh` is: shell logic buried inside a workflow `run:` block
# cannot be exercised by bats, and a security control MUST be tested.
#
# Two neutralizations, applied ONLY to untrusted data (never to the
# template's own control markers or to the trusted allow/deny lists):
#
#   1. Backticks. Every `` ` `` becomes `'`. A ``` fence inside untrusted
#      data therefore can never close a code fence in the surrounding
#      prompt. Defense-in-depth: the untrusted sections are ALSO wrapped in
#      a per-run random sentinel, so a fence breakout would not help an
#      attacker even if one backtick survived.
#   2. Machine-readable control markers. `GAIA-VERDICT` and `GAIA-FIX-ABORT`
#      get a `_NEUTRALIZED` break inserted after the token name. An injected
#      copy can then never masquerade as the model's own verdict/abort
#      output: `parse-verdict.sh` anchors on `^[[:space:]]*GAIA-VERDICT:`
#      and the workflow greps `^[[:space:]]*GAIA-FIX-ABORT:`; neither regex
#      matches `GAIA-VERDICT_NEUTRALIZED:` / `GAIA-FIX-ABORT_NEUTRALIZED:`.
#
# Bash 3.2 compatible (macOS default; parameter-expansion substitution only,
# no regex, no external tools). Exit 0 on success, 2 on bad usage.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "neutralize-untrusted.sh: usage: neutralize-untrusted.sh <value>" >&2
  exit 2
fi

value="$1"

# Special characters held in variables: a bare backtick or apostrophe inside
# a `${var//pat/repl}` expansion trips the shell parser.
backtick='`'
apostrophe="'"

value="${value//$backtick/$apostrophe}"
value="${value//GAIA-VERDICT/GAIA-VERDICT_NEUTRALIZED}"
value="${value//GAIA-FIX-ABORT/GAIA-FIX-ABORT_NEUTRALIZED}"

printf '%s\n' "$value"
