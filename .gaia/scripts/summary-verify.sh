#!/usr/bin/env bash
# summary-verify.sh: deterministic verify-gate for the consolidated
# wiki-purposed SUMMARY.md artifact produced at merge. Every
# consolidation producer (plan-close / spec-close / pre-flight backstop / the
# warm orchestrator) calls this before the irreversible removal of
# SPEC.md / AUDIT.md: a failed or malformed consolidation keeps the layers
# (fail-closed).
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
# Deterministic and side-effect-free: no writes, no network, no git.
# gaia:maintainer-only:start
#
# Sibling bats suite: .gaia/scripts/tests/summary-verify.bats.
# gaia:maintainer-only:end
set -uo pipefail

path="${1:-}"

if [ -z "$path" ] || [ ! -s "$path" ]; then
  echo "summary-verify: missing or empty file: ${path:-<none>}" >&2
  exit 1
fi

awk '
  BEGIN { frontmatter_open = 0; frontmatter_closed = 0; saw_wiki_promote_default = 0; saw_wiki_promote_targets = 0; seen_h1 = 0; body_nonempty = 0 }
  NR == 1 {
    if ($0 == "---") frontmatter_open = 1
    next
  }
  frontmatter_open && !frontmatter_closed {
    if ($0 == "---") { frontmatter_closed = 1; next }
    if ($0 ~ /^wiki_promote_default:/) saw_wiki_promote_default = 1
    if ($0 ~ /^wiki_promote_targets:/) saw_wiki_promote_targets = 1
    next
  }
  frontmatter_closed && !seen_h1 {
    if ($0 ~ /^# /) {
      text = $0
      sub(/^# /, "", text)
      gsub(/^[ \t]+|[ \t]+$/, "", text)
      if (text != "") seen_h1 = 1
    }
    next
  }
  frontmatter_closed && seen_h1 {
    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line != "") body_nonempty = 1
  }
  END {
    ok = 1
    if (!frontmatter_open) {
      print "summary-verify: missing leading frontmatter block (^---$)" > "/dev/stderr"
      ok = 0
    } else if (!frontmatter_closed) {
      print "summary-verify: unclosed frontmatter block (no closing ^---$)" > "/dev/stderr"
      ok = 0
    } else {
      if (!saw_wiki_promote_default) {
        print "summary-verify: frontmatter missing wiki_promote_default:" > "/dev/stderr"
        ok = 0
      }
      if (!saw_wiki_promote_targets) {
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
