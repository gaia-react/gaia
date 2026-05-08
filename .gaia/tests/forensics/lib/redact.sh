#!/usr/bin/env bash
# Shell implementation of the redaction algorithm defined in
# .claude/skills/gaia/references/forensics/redaction.md
#
# This file is a copy of the canonical regex set from that fragment.
# Drift between this file and the fragment is a maintenance debt accepted
# in v1.0.0. The fragment is the source of truth; this file must be kept
# in sync manually.
#
# BSD sed (macOS) compatibility notes:
#   - \b word boundaries are NOT supported; prefix patterns are distinctive
#     enough without them (gho_, sk-ant-, glpat-, xox[baprs]-, etc.).
#   - Alternation (A|B) inside groups is not always reliable in BSD sed;
#     patterns that need it are split into separate passes.
#   - The /i flag for case-insensitive matching is not supported; patterns
#     that need case-insensitivity use character classes.
#
# Usage:
#   redact_body "$ROOT" "$body"   -> prints redacted body to stdout
#
# Arguments:
#   ROOT  - absolute project root (output of git rev-parse --show-toplevel)
#   body  - the assembled report body (post-frontmatter) to redact
#
# Order of operations (mirrors redaction.md § Order of operations):
#   1. Path conversion — Rule A (project-root strip), then Rule B (machine-leak fallback)
#   2. Token regex set — patterns 1–7 in declared order
#   3. Env-var value scrub
#   4. Sanity recheck — re-run patterns 1–6; survivor = redaction bug

set -euo pipefail

redact_body() {
  local root="$1"
  local body="$2"
  local out="$body"

  # -------------------------------------------------------------------------
  # Step 1: Path conversion
  # -------------------------------------------------------------------------

  # Rule A — under project root: strip leading $root/ to make repo-relative.
  # Escape special regex characters in root path.
  local escaped_root
  escaped_root="$(printf '%s' "$root" | sed 's|[[\.*^$()+?{|]|\\&|g')"
  out="$(printf '%s' "$out" | sed "s|${escaped_root}/||g")"

  # Rule B — outside project root: collapse /Users/<name>/... or /home/<name>/...
  # to just the trailing filename component.
  # Run two separate passes (one for /Users/, one for /home/) — BSD sed does not
  # reliably support alternation (A|B) inside groups.
  # Pattern (per pass): /Users/<name>(/component)*/filename  -> filename
  out="$(printf '%s' "$out" | \
    sed -E 's|/Users/[^/[:space:]]+(/[^/[:space:]]+)*/([^/[:space:]]+)|\2|g')"
  out="$(printf '%s' "$out" | \
    sed -E 's|/home/[^/[:space:]]+(/[^/[:space:]]+)*/([^/[:space:]]+)|\2|g')"

  # -------------------------------------------------------------------------
  # Step 2: Token regex set (patterns 1–7 in declared order)
  # Note: BSD sed does not support \b word boundaries.
  # Token prefixes (gho_, sk-ant-, etc.) are sufficiently distinctive.
  # -------------------------------------------------------------------------

  # Pattern 1: GitHub tokens — gho_, ghp_, ghs_, ghr_, ghu_ followed by 20+ alphanum
  # Split into separate passes to avoid BSD sed alternation issues.
  out="$(printf '%s' "$out" | sed -E 's/gho_[A-Za-z0-9]{20,}/<redacted>/g')"
  out="$(printf '%s' "$out" | sed -E 's/ghp_[A-Za-z0-9]{20,}/<redacted>/g')"
  out="$(printf '%s' "$out" | sed -E 's/ghs_[A-Za-z0-9]{20,}/<redacted>/g')"
  out="$(printf '%s' "$out" | sed -E 's/ghr_[A-Za-z0-9]{20,}/<redacted>/g')"
  out="$(printf '%s' "$out" | sed -E 's/ghu_[A-Za-z0-9]{20,}/<redacted>/g')"

  # Pattern 2: Anthropic API key — sk-ant- followed by 20+ alphanum/dash/underscore
  # Must precede pattern 3 (sk-) because sk-ant- starts with sk-
  out="$(printf '%s' "$out" | sed -E 's/sk-ant-[A-Za-z0-9_-]{20,}/<redacted>/g')"

  # Pattern 3: OpenAI API key — sk- followed by 20+ alphanum
  # (sk-ant- already consumed by pattern 2 above)
  out="$(printf '%s' "$out" | sed -E 's/sk-[A-Za-z0-9]{20,}/<redacted>/g')"

  # Pattern 4: GitLab personal access token — glpat- followed by 20+ alphanum/dash/underscore
  out="$(printf '%s' "$out" | sed -E 's/glpat-[A-Za-z0-9_-]{20,}/<redacted>/g')"

  # Pattern 5: Slack token — xoxb/xoxa/xoxp/xoxr/xoxs followed by 10+ alphanum/dash
  out="$(printf '%s' "$out" | sed -E 's/xoxb-[A-Za-z0-9-]{10,}/<redacted>/g')"
  out="$(printf '%s' "$out" | sed -E 's/xoxa-[A-Za-z0-9-]{10,}/<redacted>/g')"
  out="$(printf '%s' "$out" | sed -E 's/xoxp-[A-Za-z0-9-]{10,}/<redacted>/g')"
  out="$(printf '%s' "$out" | sed -E 's/xoxr-[A-Za-z0-9-]{10,}/<redacted>/g')"
  out="$(printf '%s' "$out" | sed -E 's/xoxs-[A-Za-z0-9-]{10,}/<redacted>/g')"

  # Pattern 6: AWS access key ID — 4 uppercase letters + 16 uppercase alphanum (20 total)
  # No \b; the structural prefix (AKIA, ASIA, AROA, etc.) anchors the match.
  out="$(printf '%s' "$out" | sed -E 's/[A-Z]{4}[0-9A-Z]{16}/<redacted>/g')"

  # Pattern 7: Generic high-entropy fallback (token|key|secret + 40+ chars)
  # Preserve the label; replace only the value.
  # Three separate passes — BSD sed alternation in groups is not reliable.
  out="$(printf '%s' "$out" | \
    sed -E "s/([Tt][Oo][Kk][Ee][Nn])[[:space:]=:]+[\"']?[A-Za-z0-9+\/=_-]{40,}[\"']?/\1=<redacted>/g")"
  out="$(printf '%s' "$out" | \
    sed -E "s/([Kk][Ee][Yy])[[:space:]=:]+[\"']?[A-Za-z0-9+\/=_-]{40,}[\"']?/\1=<redacted>/g")"
  out="$(printf '%s' "$out" | \
    sed -E "s/([Ss][Ee][Cc][Rr][Ee][Tt])[[:space:]=:]+[\"']?[A-Za-z0-9+\/=_-]{40,}[\"']?/\1=<redacted>/g")"

  # -------------------------------------------------------------------------
  # Step 3: Env-var value scrub (belt-and-suspenders)
  # Pattern: ^([A-Za-z_][A-Za-z0-9_]*)=(.+)$  (per-line, multiline)
  # Replace: \1=<redacted>
  # -------------------------------------------------------------------------
  out="$(printf '%s' "$out" | \
    sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.+$/\1=<redacted>/g')"

  # -------------------------------------------------------------------------
  # Step 4: Sanity recheck — re-run patterns 1–6
  # If any credential-shaped value survived, that is a redaction bug.
  # Report and exit non-zero rather than emitting a partially-redacted body.
  # grep -E supports \b on some systems, but to be portable we use the same
  # prefix-only approach as the sed passes above.
  # -------------------------------------------------------------------------
  local recheck="$out"

  # Recheck pattern 1: GitHub tokens
  if printf '%s' "$recheck" | grep -qE '(gho|ghp|ghs|ghr|ghu)_[A-Za-z0-9]{20,}'; then
    printf 'REDACTION BUG: GitHub token survived sanity recheck\n' >&2
    return 1
  fi

  # Recheck pattern 2: Anthropic API key
  if printf '%s' "$recheck" | grep -qE 'sk-ant-[A-Za-z0-9_-]{20,}'; then
    printf 'REDACTION BUG: Anthropic API key survived sanity recheck\n' >&2
    return 1
  fi

  # Recheck pattern 3: OpenAI API key (but not sk-ant- which is already above)
  if printf '%s' "$recheck" | grep -qE 'sk-[A-Za-z0-9]{20,}'; then
    printf 'REDACTION BUG: OpenAI API key survived sanity recheck\n' >&2
    return 1
  fi

  # Recheck pattern 4: GitLab PAT
  if printf '%s' "$recheck" | grep -qE 'glpat-[A-Za-z0-9_-]{20,}'; then
    printf 'REDACTION BUG: GitLab PAT survived sanity recheck\n' >&2
    return 1
  fi

  # Recheck pattern 5: Slack token
  if printf '%s' "$recheck" | grep -qE 'xox[baprs]-[A-Za-z0-9-]{10,}'; then
    printf 'REDACTION BUG: Slack token survived sanity recheck\n' >&2
    return 1
  fi

  # Recheck pattern 6: AWS access key
  if printf '%s' "$recheck" | grep -qE '[A-Z]{4}[0-9A-Z]{16}'; then
    printf 'REDACTION BUG: AWS access key survived sanity recheck\n' >&2
    return 1
  fi

  printf '%s' "$out"
}
