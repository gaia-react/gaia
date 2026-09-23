#!/usr/bin/env bash
# shellcheck shell=bash
#
# knowledge-audit-clean.sh: decide whether a /gaia-audit Stage 1 report may
# take the zero-action auto-apply path, the one path that skips the Apply /
# Discuss / Decline gate.
#
# Usage: knowledge-audit-clean.sh <report_path>
#
# Exit 0 and print `clean`: the report may auto-apply. Exit 1 and print
# `gate`, with one reason per line on stderr: route it to the decision gate.
# Exit 2: usage error. The caller in .claude/skills/gaia/references/audit.md
# treats every non-zero exit as `gate`, so a failure here fails toward a human.
#
# Why this exists: Stage 1 is one free-form research pass, and a pass that
# stops before walking every store writes a report that reads exactly like a
# clean one. Its own totals cannot vouch for it, so this re-runs Step 1's
# inventory independently and holds the report's `## Coverage` record to it.
#
# Contract with audit.md: each `find` line in store_files() is byte-identical
# to one in audit.md's Step 1 block, and the store ids are the ones its report
# template's Coverage table names. The sibling suite pins both from audit.md.
#
# Honest limits. It compares counts, not identities, so a report that
# classified the right number of the wrong files passes. A file added or
# removed between Stage 1 and this check reads as a mismatch and routes to the
# gate, the safe direction.
# gaia:maintainer-only:start
#
# Sibling bats suite: .gaia/scripts/tests/knowledge-audit-clean.bats.
# gaia:maintainer-only:end
set -uo pipefail

readonly PROG="knowledge-audit-clean"

# Every store Step 1 inventories, and the subset Step 2 classifies entry by
# entry (memory entries and rules files). wiki is what Step 2 compares
# against, and CLAUDE.md files are Step 3's budget, so neither has a
# classified count to hold.
readonly STORES="memory agent-memory project-agent-memory rules wiki claude-md"
readonly CLASSIFIED_STORES="memory agent-memory project-agent-memory rules"

usage() {
  echo "usage: $PROG <report_path>" >&2
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  usage
  exit 2
fi
report="$1"
if [ ! -f "$report" ]; then
  echo "$PROG: no report at $report" >&2
  exit 2
fi

# Same resolution formula as audit.md's `### Path resolution`, kept textually
# identical to it rather than rewritten as a parameter expansion.
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# shellcheck disable=SC2001
MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"

store_files() {
  case "$1" in
    memory) find "$MEMORY_DIR" -type f -name "*.md" 2>/dev/null ;;
    agent-memory) find "$AGENT_MEMORY_DIR" -type f -name "*.md" 2>/dev/null ;;
    project-agent-memory) find "$PROJECT_ROOT/.claude/agent-memory" -type f -name "*.md" 2>/dev/null ;;
    rules) find "$PROJECT_ROOT/.claude/rules" -type f -name "*.md" ;;
    wiki) find "$PROJECT_ROOT/wiki" -type f -name "*.md" ;;
    claude-md) find "$PROJECT_ROOT" -maxdepth 3 -name CLAUDE.md -not -path '*/node_modules/*' ;;
  esac
}

# A store directory that does not exist is an empty store, not an error, so
# find's own complaint on the rules and wiki lines is discarded here rather
# than in the lines audit.md owns.
live_count() {
  store_files "$1" 2>/dev/null | wc -l | tr -d ' '
}

# One tab-separated record per fact the report states: frontmatter roots,
# Summary lines, Coverage rows, and one `act` per action checkbox. Action
# blocks are counted wherever they sit, so a zero Summary line cannot hide a
# block it disagrees with.
parsed="$(awk '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  NR == 1 && $0 == "---" { fm = 1; next }
  fm && $0 == "---" { fm = 0; next }
  fm {
    i = index($0, ":")
    if (i == 0) next
    k = substr($0, 1, i - 1)
    v = trim(substr($0, i + 1))
    gsub(/^"|"$/, "", v)
    if (k == "project_root" || k == "memory_dir" || k == "agent_memory_dir") print "fm\t" k "\t" v
    next
  }
  /^## / { sec = trim($0); next }
  sec == "## Summary" && /^- Actions proposed:/ { v = $0; sub(/^- Actions proposed:/, "", v); print "sum\tactions\t" trim(v) }
  sec == "## Summary" && /^- Applied scope:/ { v = $0; sub(/^- Applied scope:/, "", v); print "sum\tscope\t" trim(v) }
  sec == "## Coverage" && /^\|/ {
    split($0, c, "|")
    s = trim(c[2])
    if (s == "" || s == "Store" || s ~ /^:?-+:?$/) next
    print "cov\t" s "\t" trim(c[3]) "\t" trim(c[4])
  }
  /^- \[[ x~!]\] `(delete-entry|delete|promote|shrink)-[0-9]+`/ { print "act" }
' "$report")"

reasons=""
fail() { reasons="${reasons}${PROG}: $1"$'\n'; }

field() { printf '%s\n' "$parsed" | awk -F'\t' -v k="$1" -v n="$2" '$1 == k && $2 == n { print $3; exit }'; }
is_count() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; return 0; }

for pair in "project_root:$PROJECT_ROOT" "memory_dir:$MEMORY_DIR" "agent_memory_dir:$AGENT_MEMORY_DIR"; do
  key="${pair%%:*}"
  want="${pair#*:}"
  got="$(field fm "$key")"
  [ "$got" = "$want" ] || fail "frontmatter $key is '${got}', resolved '${want}'"
done

scope="$(field sum scope)"
[ "$scope" = "full" ] || fail "Applied scope is '${scope:-<missing>}', not full; a narrowed run says nothing about the stores it skipped"

actions="$(field sum actions)"
[ "$actions" = "0" ] || fail "Actions proposed is '${actions:-<missing>}', not 0"
blocks="$(printf '%s\n' "$parsed" | grep -c '^act$')"
[ "$blocks" -eq 0 ] || fail "report carries $blocks action block(s)"

for store in $STORES; do
  rows="$(printf '%s\n' "$parsed" | awk -F'\t' -v s="$store" '$1 == "cov" && $2 == s')"
  nrows="$(printf '%s' "$rows" | grep -c .)"
  if [ "$nrows" -eq 0 ]; then
    fail "no Coverage row for store $store"
    continue
  fi
  if [ "$nrows" -gt 1 ]; then
    fail "more than one Coverage row for store $store"
    continue
  fi
  live="$(live_count "$store")"
  inventoried="$(printf '%s\n' "$rows" | cut -f3)"
  if ! is_count "$inventoried" || [ "$inventoried" -ne "$live" ]; then
    fail "store $store: Inventoried '${inventoried}' but Step 1 finds $live"
  fi
  case " $CLASSIFIED_STORES " in
    *" $store "*)
      classified="$(printf '%s\n' "$rows" | cut -f4)"
      if ! is_count "$classified" || [ "$classified" -ne "$live" ]; then
        fail "store $store: Classified '${classified}' but Step 1 finds $live"
      fi
      ;;
  esac
done

if [ -n "$reasons" ]; then
  printf '%s' "$reasons" >&2
  echo gate
  exit 1
fi
echo clean
exit 0
