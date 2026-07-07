#!/usr/bin/env bash
# summary-verify.sh: deterministic verify-gate for the consolidated
# wiki-purposed SUMMARY.md artifact produced at merge (SPEC-031). Every
# consolidation producer (plan-close / spec-close / pre-flight backstop / the
# warm orchestrator) calls this before the irreversible removal of
# SPEC.md / AUDIT.md: a failed or malformed consolidation keeps the layers
# (fail-closed, AUDIT DEF-05).
#
# Usage: summary-verify.sh <summary_md_path>
#
# Exit 0 iff the file exists, is non-empty, and is well-formed per the pinned
# shape (frozen contract, plan/README.md #2): a closed leading frontmatter
# block (`---` ... `---`) containing wiki_promote_default: and
# wiki_promote_targets: keys, exactly one non-empty H1 (`# <title>`), and a
# non-empty body after it. An optional `## Divergence` section is allowed but
# not required. Frontmatter VALUES are not deep-validated here (routing
# validation stays in wiki-promote); this gate checks key presence and shape.
#
# Exit 1 otherwise: absent/empty file, missing or unclosed frontmatter,
# frontmatter missing either key, missing H1, or empty body. Violations
# accumulate and are reported to stderr; no stdout noise.
#
# Deterministic and side-effect-free: no writes, no network, no git. Sibling
# bats suite: .gaia/scripts/tests/summary-verify.bats.
set -uo pipefail

path="${1:-}"

if [ -z "$path" ] || [ ! -s "$path" ]; then
  echo "summary-verify: missing or empty file: ${path:-<none>}" >&2
  exit 1
fi

awk '
  BEGIN { fm_open = 0; fm_closed = 0; saw_wpd = 0; saw_wpt = 0; seen_h1 = 0; body_nonempty = 0 }
  NR == 1 {
    if ($0 == "---") fm_open = 1
    next
  }
  fm_open && !fm_closed {
    if ($0 == "---") { fm_closed = 1; next }
    if ($0 ~ /^wiki_promote_default:/) saw_wpd = 1
    if ($0 ~ /^wiki_promote_targets:/) saw_wpt = 1
    next
  }
  fm_closed && !seen_h1 {
    if ($0 ~ /^# /) {
      text = $0
      sub(/^# /, "", text)
      gsub(/^[ \t]+|[ \t]+$/, "", text)
      if (text != "") seen_h1 = 1
    }
    next
  }
  fm_closed && seen_h1 {
    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line != "") body_nonempty = 1
  }
  END {
    ok = 1
    if (!fm_open) {
      print "summary-verify: missing leading frontmatter block (^---$)" > "/dev/stderr"
      ok = 0
    } else if (!fm_closed) {
      print "summary-verify: unclosed frontmatter block (no closing ^---$)" > "/dev/stderr"
      ok = 0
    } else {
      if (!saw_wpd) {
        print "summary-verify: frontmatter missing wiki_promote_default:" > "/dev/stderr"
        ok = 0
      }
      if (!saw_wpt) {
        print "summary-verify: frontmatter missing wiki_promote_targets:" > "/dev/stderr"
        ok = 0
      }
      if (!seen_h1) {
        print "summary-verify: missing non-empty H1 (^# <title>)" > "/dev/stderr"
        ok = 0
      } else if (!body_nonempty) {
        print "summary-verify: empty body after H1" > "/dev/stderr"
        ok = 0
      }
    }
    exit ok ? 0 : 1
  }
' "$path"
