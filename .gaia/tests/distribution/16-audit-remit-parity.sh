#!/usr/bin/env bash
# 16-audit-remit-parity.sh
#
# Proves the roster-derived remit invariant and its repair hold on the
# release-scrubbed ADOPTER shape, not only on the maintainer tree. Runs
# after task-docs-and-wiring's .gaia/release-exclude and wiki marker-pair
# edits are already committed (Phase 5), so the staging build it reads
# from the working copy reflects them.
#
# Assertions, in order:
#   1. The bundle carries the writer (.gaia/scripts/write-audit-remits.sh).
#   2. The writer is not release-excluded (source .gaia/release-exclude).
#   3. The writer's manifest class equals the check's (staged manifest).
#   4. The check exits 0 on the scrubbed, marker-stripped tree.
#   5. The staged roster is the adopter shape: exactly two members, neither
#      maintainer-only, and no code-audit-maintainer-*.md ships.
#   6. No shipped region names a glob belonging to a stripped member
#      (UAT-010).
#   7. The bundled writer repairs a drifted shipped definition byte-exact
#      (UAT-012).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd jq "jq required for manifest parsing"
require_cmd rsync "rsync required for staging build"
require_cmd shasum "shasum required for the byte-exact repair check"

CLI="$PROJECT_ROOT/.gaia/cli/gaia-maintainer"
if [ ! -x "$CLI" ]; then
  fail "maintainer CLI binary missing or not executable: $CLI (run 'pnpm -C .gaia/cli bundle')"
  exit 1
fi

STAGING="$(mktemp -d -t gaia-dist-remit-parity-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

CHECK="$STAGING/.gaia/scripts/verify-audit-roster.sh"
ROSTER="$STAGING/.gaia/audit-ci.yml"
WRITER="$STAGING/.gaia/scripts/write-audit-remits.sh"

# region_globs FILE
# Prints the glob value of every remit-region bullet in FILE, one per line.
# Exact whole-line marker match, matching the two authoritative readers
# (verify-audit-roster.sh's _verify_roster_read_regions and
# write-audit-remits.sh's rewrite awk): an unanchored /regex/ match would
# also fire on the marker appearing mid-line or as a quoted example, which
# neither reader treats as a real marker.
region_globs() {
  awk '
    $0 == "<!-- gaia:audit-remit:start -->" { flag=1; next }
    $0 == "<!-- gaia:audit-remit:end -->" { flag=0 }
    flag && /^- `/ { print }
  ' "$1" | sed -e 's/^- `//' -e 's/`$//'
}

# --- Assertion 1: the bundle carries the writer -----------------------
[ -f "$WRITER" ] || { fail "writer missing from staging tree: .gaia/scripts/write-audit-remits.sh"; exit 1; }

# --- Assertion 2: the writer is not release-excluded -------------------
if grep -qxF ".gaia/scripts/write-audit-remits.sh" "$PROJECT_ROOT/.gaia/release-exclude"; then
  fail "writer literally excluded: .gaia/scripts/write-audit-remits.sh appears in .gaia/release-exclude"
  exit 1
fi
if grep -qxF ".gaia/scripts" "$PROJECT_ROOT/.gaia/release-exclude"; then
  fail "writer masked: .gaia/scripts appears as a bare directory entry in .gaia/release-exclude"
  exit 1
fi

# --- Assertion 3: the writer's manifest class equals the check's -------
w=$(jq -r '.files[".gaia/scripts/write-audit-remits.sh"] // empty' "$STAGING/.gaia/manifest.json")
c=$(jq -r '.files[".gaia/scripts/verify-audit-roster.sh"] // empty' "$STAGING/.gaia/manifest.json")
if [ -z "$w" ]; then
  fail "writer unanswered in staged manifest.json (.gaia/scripts/write-audit-remits.sh has no class)"
  exit 1
fi
if [ "$w" != "$c" ]; then
  fail "manifest class mismatch: writer=$w check=$c (want equal per UAT-012)"
  exit 1
fi

# --- Assertion 4: the check exits 0 on the scrubbed tree ---------------
# The staged copy is marker-stripped (the maintainer-only fallback-lockstep
# block is gone) and resolves .claude/hooks/lib/audit-scope.sh from the
# staged tree, the real path verify-audit-roster.sh:151 computes. If that
# classifier library is absent from the bundle, this is a real distribution
# finding, not a harness bug.
CHECK_OUT=""
CHECK_RC=0
CHECK_OUT="$(bash "$CHECK" --root "$STAGING" --config "$ROSTER" 2>&1)" || CHECK_RC=$?
if [ "$CHECK_RC" -ne 0 ]; then
  log "verify-audit-roster.sh failed on scrubbed tree, full output:"
  printf '%s\n' "$CHECK_OUT" >&2
  fail "roster check exited $CHECK_RC on scrubbed adopter tree, expected 0"
  exit 1
fi

# --- Assertion 5: the staged roster is the adopter shape ---------------
staged_members="$(bash "$CHECK" --emit-roster --root "$STAGING" --config "$ROSTER" \
  | awk -F'\t' '$1=="MEMBER"{print $2}')"
staged_member_count="$(printf '%s\n' "$staged_members" | grep -c . || true)"
if [ "$staged_member_count" -ne 2 ]; then
  log "staged roster members:"
  printf '%s\n' "$staged_members" >&2
  fail "staged roster has $staged_member_count member(s), expected 2 (adopter shape)"
  exit 1
fi
if printf '%s\n' "$staged_members" | grep -q '^code-audit-maintainer-'; then
  fail "staged roster still declares a code-audit-maintainer-* member, scrub did not strip it"
  exit 1
fi
shopt -s nullglob
staged_maintainer_defs=("$STAGING"/.claude/agents/code-audit-maintainer-*.md)
shopt -u nullglob
if [ "${#staged_maintainer_defs[@]}" -gt 0 ]; then
  fail "staged .claude/agents/ still ships ${#staged_maintainer_defs[@]} code-audit-maintainer-*.md file(s): ${staged_maintainer_defs[*]}"
  exit 1
fi

# --- Assertion 6: no shipped region names a stripped member's glob -----
src_globs="$(bash "$PROJECT_ROOT/.gaia/scripts/verify-audit-roster.sh" --emit-roster \
  --root "$PROJECT_ROOT" --config "$PROJECT_ROOT/.gaia/audit-ci.yml" \
  | awk -F'\t' '$1=="RAW"{print $3}' | sort -u)"
staged_globs="$(bash "$CHECK" --emit-roster --root "$STAGING" --config "$ROSTER" \
  | awk -F'\t' '$1=="RAW"{print $3}' | sort -u)"
stripped_globs="$(comm -23 <(printf '%s\n' "$src_globs") <(printf '%s\n' "$staged_globs"))"

# Guard against a vacuous pass: if the scrub stripped no globs, the
# comparison below proves nothing.
if [ -z "$stripped_globs" ]; then
  fail "stripped_globs is empty; the scrub removed no maintainer-only globs (would make assertion 6 vacuous)"
  exit 1
fi

shopt -s nullglob
staged_agent_defs=("$STAGING"/.claude/agents/code-audit-*.md)
shopt -u nullglob
# A bare "${staged_agent_defs[@]}" expansion of an empty array aborts under
# `set -u` on bash 3.2 (stock macOS /bin/bash). An empty array here would
# also mean assertion 6 scans nothing, so failing explicitly is correct on
# both counts, not just a portability guard.
if [ "${#staged_agent_defs[@]}" -eq 0 ]; then
  fail "no .claude/agents/code-audit-*.md shipped in the staged tree; assertion 6 has nothing to scan"
  exit 1
fi
LEAKED_GLOBS=()
for def in "${staged_agent_defs[@]}"; do
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    if printf '%s\n' "$stripped_globs" | grep -qxF "$g"; then
      LEAKED_GLOBS+=("$(basename "$def"): $g")
    fi
  done < <(region_globs "$def")
done
if [ "${#LEAKED_GLOBS[@]}" -gt 0 ]; then
  log "Shipped regions naming a stripped member's glob:"
  for entry in "${LEAKED_GLOBS[@]}"; do log "  $entry"; done
  fail "${#LEAKED_GLOBS[@]} shipped region(s) name a glob belonging to a stripped maintainer-only member"
  exit 1
fi

# --- Assertion 7: the bundled writer repairs a drifted shipped definition
TARGET="$STAGING/.claude/agents/code-audit-github-workflows.md"
[ -f "$TARGET" ] || { fail "expected shipped definition missing: .claude/agents/code-audit-github-workflows.md"; exit 1; }
orig_sha="$(shasum -a 256 "$TARGET" | awk '{print $1}')"

# Delete the first bullet line inside the remit region.
DRIFTED="$(mktemp)"
awk '
  $0 == "<!-- gaia:audit-remit:start -->" { flag=1; print; next }
  $0 == "<!-- gaia:audit-remit:end -->" { flag=0 }
  flag && /^- `/ && !deleted { deleted=1; next }
  { print }
' "$TARGET" > "$DRIFTED"
mv "$DRIFTED" "$TARGET"

DRIFT_OUT=""
DRIFT_RC=0
DRIFT_OUT="$(bash "$CHECK" --root "$STAGING" --config "$ROSTER" 2>&1)" || DRIFT_RC=$?
if [ "$DRIFT_RC" -ne 1 ]; then
  log "drifted-check output:"
  printf '%s\n' "$DRIFT_OUT" >&2
  fail "roster check exited $DRIFT_RC against a drifted region, expected 1"
  exit 1
fi
for needle in "remit-glob-missing" "code-audit-github-workflows" "bash .gaia/scripts/write-audit-remits.sh"; do
  if ! printf '%s\n' "$DRIFT_OUT" | grep -qF "$needle"; then
    log "drifted-check output:"
    printf '%s\n' "$DRIFT_OUT" >&2
    fail "drifted-check output missing expected substring: $needle"
    exit 1
  fi
done

WRITER_RC=0
bash "$WRITER" --root "$STAGING" --config "$ROSTER" >/dev/null 2>&1 || WRITER_RC=$?
if [ "$WRITER_RC" -ne 0 ]; then
  fail "bundled writer exited $WRITER_RC repairing the drifted region, expected 0"
  exit 1
fi

REPAIRED_RC=0
REPAIRED_OUT=""
REPAIRED_OUT="$(bash "$CHECK" --root "$STAGING" --config "$ROSTER" 2>&1)" || REPAIRED_RC=$?
if [ "$REPAIRED_RC" -ne 0 ]; then
  log "post-repair check output:"
  printf '%s\n' "$REPAIRED_OUT" >&2
  fail "roster check exited $REPAIRED_RC after the bundled writer repaired the region, expected 0"
  exit 1
fi

repaired_sha="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
if [ "$repaired_sha" != "$orig_sha" ]; then
  fail "repaired definition bytes ($repaired_sha) do not match pre-drift snapshot ($orig_sha)"
  exit 1
fi

pass "remit invariant, roster shape, and writer repair all hold on the scrubbed adopter tree"
