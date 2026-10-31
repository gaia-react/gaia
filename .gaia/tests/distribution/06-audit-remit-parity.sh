#!/usr/bin/env bash
# 06-audit-remit-parity.sh
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
#   4. The staged tree carries no .bats file (an adopter starts with no shell
#      suites), and the check exits 0 on the scrubbed, marker-stripped tree
#      once it is indexed, with no invariant skipped. That exit 0 includes
#      the zero-match invariant: every glob of the shell member matches
#      something even with no adopter shell present.
#   4b. Guard can fail: a scratch roster copy with a misspelled glob added to
#      the frontend member makes the same check fail, naming that glob.
#   5. The staged roster is the adopter shape: its members are exactly the
#      source roster's non-maintainer members, which include the frontend,
#      workflow and shell members, none maintainer-only, and no
#      code-audit-maintainer-*.md ships.
#   6. No shipped region names a glob belonging to a stripped member
#      (UAT-010).
#   7. The bundled writer repairs a drifted shipped definition byte-exact
#      (UAT-012).
#   8. The shell member's staged remit region and staged roster entry both
#      claim .claude/settings.json, and a scratch roster copy without that
#      glob in the shell entry makes the roster check fail (guard can fail).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command jq "jq required for manifest parsing"
require_command rsync "rsync required for staging build"
require_command shasum "shasum required for the byte-exact repair check"

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
writer_class=$(jq -r '.files[".gaia/scripts/write-audit-remits.sh"] // empty' "$STAGING/.gaia/manifest.json")
check_class=$(jq -r '.files[".gaia/scripts/verify-audit-roster.sh"] // empty' "$STAGING/.gaia/manifest.json")
if [ -z "$writer_class" ]; then
  fail "writer unanswered in staged manifest.json (.gaia/scripts/write-audit-remits.sh has no class)"
  exit 1
fi
if [ "$writer_class" != "$check_class" ]; then
  fail "manifest class mismatch: writer=$writer_class check=$check_class (want equal per UAT-012)"
  exit 1
fi

# --- Assertion 4: the check exits 0 on the scrubbed tree ---------------
# The staged copy is marker-stripped (the maintainer-only fallback-lockstep
# block is gone) and resolves .claude/hooks/lib/audit-scope.sh from the
# staged tree. If that classifier library is absent from the bundle, this is
# a real distribution finding, not a harness bug.
#
# The staged tree is indexed first, the state an adopter's first commit
# leaves it in: the coverage and zero-match invariants read `git ls-files`
# and skip on a tree that is not a repository root, so without the index this
# assertion would pass with both of them never run. An index is enough; no
# commit is needed for `ls-files` to see the tree.
staged_bats_files="$(find "$STAGING" -name '*.bats' -not -path '*/node_modules/*' -print)"
if [ -n "$staged_bats_files" ]; then
  log "staged .bats files:"
  printf '%s\n' "$staged_bats_files" >&2
  fail "the staged tree ships a .bats file, so the no-adopter-shell premise of the zero-match check does not hold"
  exit 1
fi
git -C "$STAGING" init -q || { fail "git init of the staged tree failed"; exit 1; }
git -C "$STAGING" add -A || { fail "git add of the staged tree failed"; exit 1; }
CHECK_OUTPUT=""
CHECK_EXIT_STATUS=0
CHECK_OUTPUT="$(bash "$CHECK" --root "$STAGING" --config "$ROSTER" 2>&1)" || CHECK_EXIT_STATUS=$?
if [ "$CHECK_EXIT_STATUS" -ne 0 ]; then
  log "verify-audit-roster.sh failed on scrubbed tree, full output:"
  printf '%s\n' "$CHECK_OUTPUT" >&2
  fail "roster check exited $CHECK_EXIT_STATUS on scrubbed adopter tree, expected 0"
  exit 1
fi
if grep -qF "SKIPPED" <<<"$CHECK_OUTPUT"; then
  log "verify-audit-roster.sh output on scrubbed tree:"
  printf '%s\n' "$CHECK_OUTPUT" >&2
  fail "roster check skipped an invariant on the indexed staged tree, so its exit 0 proves nothing"
  exit 1
fi

# --- Assertion 4b: the zero-match invariant can fail ---------------------
MISSPELLED_ROSTER="$STAGING/.gaia/audit-ci-misspelled.yml"
sed 's|^      - "frontend/app/\*\*"$|&\
      - "frontend/apps/**"|' "$ROSTER" > "$MISSPELLED_ROSTER"
if cmp -s "$ROSTER" "$MISSPELLED_ROSTER"; then
  fail "could not plant a misspelled glob in the roster copy"
  exit 1
fi
MISSPELLED_EXIT_STATUS=0
MISSPELLED_OUTPUT="$(bash "$CHECK" --root "$STAGING" --config "$MISSPELLED_ROSTER" 2>&1)" || MISSPELLED_EXIT_STATUS=$?
rm -f "$MISSPELLED_ROSTER"
if [ "$MISSPELLED_EXIT_STATUS" -eq 0 ]; then
  fail "guard-can-fail: the roster check accepted a glob (frontend/apps/**) that matches no file"
  exit 1
fi
if ! grep -qF "frontend/apps/**" <<<"$MISSPELLED_OUTPUT"; then
  printf '%s\n' "$MISSPELLED_OUTPUT" >&2
  fail "guard-can-fail: the roster check failed without naming the misspelled glob"
  exit 1
fi

# --- Assertion 5: the staged roster is the adopter shape ---------------
staged_members="$(bash "$CHECK" --emit-roster --root "$STAGING" --config "$ROSTER" \
  | awk -F'\t' '$1=="MEMBER"{print $2}')"
expected_members="$(bash "$PROJECT_ROOT/.gaia/scripts/verify-audit-roster.sh" --emit-roster \
  --root "$PROJECT_ROOT" --config "$PROJECT_ROOT/.gaia/audit-ci.yml" \
  | awk -F'\t' '$1=="MEMBER"{print $2}' | grep -v '^code-audit-maintainer-' | sort)"
if [ -z "$expected_members" ] || [ "$(printf '%s\n' "$staged_members" | sort)" != "$expected_members" ]; then
  log "staged roster members:"
  printf '%s\n' "$staged_members" >&2
  log "expected (source roster's non-maintainer members):"
  printf '%s\n' "$expected_members" >&2
  fail "staged roster is not exactly the source roster's non-maintainer members (adopter shape)"
  exit 1
fi
for adopter_member in code-audit-frontend code-audit-github-workflows code-audit-shell; do
  grep -qxF "$adopter_member" <<<"$staged_members" \
    || { fail "staged roster lacks the adopter member $adopter_member"; exit 1; }
done
if grep -q '^code-audit-maintainer-' <<<"$staged_members"; then
  fail "staged roster still declares a code-audit-maintainer-* member, scrub did not strip it"
  exit 1
fi
shopt -s nullglob
staged_maintainer_definitions=("$STAGING"/.claude/agents/code-audit-maintainer-*.md)
shopt -u nullglob
if [ "${#staged_maintainer_definitions[@]}" -gt 0 ]; then
  fail "staged .claude/agents/ still ships ${#staged_maintainer_definitions[@]} code-audit-maintainer-*.md file(s): ${staged_maintainer_definitions[*]}"
  exit 1
fi

# --- Assertion 6: no shipped region names a stripped member's glob -----
source_globs="$(bash "$PROJECT_ROOT/.gaia/scripts/verify-audit-roster.sh" --emit-roster \
  --root "$PROJECT_ROOT" --config "$PROJECT_ROOT/.gaia/audit-ci.yml" \
  | awk -F'\t' '$1=="RAW"{print $3}' | sort -u)"
staged_globs="$(bash "$CHECK" --emit-roster --root "$STAGING" --config "$ROSTER" \
  | awk -F'\t' '$1=="RAW"{print $3}' | sort -u)"
stripped_globs="$(comm -23 <(printf '%s\n' "$source_globs") <(printf '%s\n' "$staged_globs"))"

# Guard against a vacuous pass: if the scrub stripped no globs, the
# comparison below proves nothing.
if [ -z "$stripped_globs" ]; then
  fail "stripped_globs is empty; the scrub removed no maintainer-only globs (would make assertion 6 vacuous)"
  exit 1
fi

shopt -s nullglob
staged_agent_definitions=("$STAGING"/.claude/agents/code-audit-*.md)
shopt -u nullglob
# A bare "${staged_agent_definitions[@]}" expansion of an empty array aborts under
# `set -u` on bash 3.2 (stock macOS /bin/bash). An empty array here would
# also mean assertion 6 scans nothing, so failing explicitly is correct on
# both counts, not just a portability guard.
if [ "${#staged_agent_definitions[@]}" -eq 0 ]; then
  fail "no .claude/agents/code-audit-*.md shipped in the staged tree; assertion 6 has nothing to scan"
  exit 1
fi
LEAKED_GLOBS=()
for agent_definition in ${staged_agent_definitions[@]+"${staged_agent_definitions[@]}"}; do
  while IFS= read -r glob; do
    [ -z "$glob" ] && continue
    if grep -qxF "$glob" <<<"$stripped_globs"; then
      LEAKED_GLOBS+=("$(basename "$agent_definition"): $glob")
    fi
  done < <(region_globs "$agent_definition")
done
if [ "${#LEAKED_GLOBS[@]}" -gt 0 ]; then
  log "Shipped regions naming a stripped member's glob:"
  for entry in ${LEAKED_GLOBS[@]+"${LEAKED_GLOBS[@]}"}; do log "  $entry"; done
  fail "${#LEAKED_GLOBS[@]} shipped region(s) name a glob belonging to a stripped maintainer-only member"
  exit 1
fi

# --- Assertion 7: the bundled writer repairs a drifted shipped definition
TARGET="$STAGING/.claude/agents/code-audit-github-workflows.md"
[ -f "$TARGET" ] || { fail "expected shipped definition missing: .claude/agents/code-audit-github-workflows.md"; exit 1; }
original_sha="$(shasum -a 256 "$TARGET" | awk '{print $1}')"

# Delete the first bullet line inside the remit region.
DRIFTED="$(mktemp)"
awk '
  $0 == "<!-- gaia:audit-remit:start -->" { flag=1; print; next }
  $0 == "<!-- gaia:audit-remit:end -->" { flag=0 }
  flag && /^- `/ && !deleted { deleted=1; next }
  { print }
' "$TARGET" > "$DRIFTED"
mv "$DRIFTED" "$TARGET"

DRIFT_OUTPUT=""
DRIFT_EXIT_STATUS=0
DRIFT_OUTPUT="$(bash "$CHECK" --root "$STAGING" --config "$ROSTER" 2>&1)" || DRIFT_EXIT_STATUS=$?
if [ "$DRIFT_EXIT_STATUS" -ne 1 ]; then
  log "drifted-check output:"
  printf '%s\n' "$DRIFT_OUTPUT" >&2
  fail "roster check exited $DRIFT_EXIT_STATUS against a drifted region, expected 1"
  exit 1
fi
for needle in "remit-glob-missing" "code-audit-github-workflows" "bash .gaia/scripts/write-audit-remits.sh"; do
  if ! grep -qF "$needle" <<<"$DRIFT_OUTPUT"; then
    log "drifted-check output:"
    printf '%s\n' "$DRIFT_OUTPUT" >&2
    fail "drifted-check output missing expected substring: $needle"
    exit 1
  fi
done

WRITER_EXIT_STATUS=0
bash "$WRITER" --root "$STAGING" --config "$ROSTER" >/dev/null 2>&1 || WRITER_EXIT_STATUS=$?
if [ "$WRITER_EXIT_STATUS" -ne 0 ]; then
  fail "bundled writer exited $WRITER_EXIT_STATUS repairing the drifted region, expected 0"
  exit 1
fi

REPAIRED_EXIT_STATUS=0
REPAIRED_OUTPUT=""
REPAIRED_OUTPUT="$(bash "$CHECK" --root "$STAGING" --config "$ROSTER" 2>&1)" || REPAIRED_EXIT_STATUS=$?
if [ "$REPAIRED_EXIT_STATUS" -ne 0 ]; then
  log "post-repair check output:"
  printf '%s\n' "$REPAIRED_OUTPUT" >&2
  fail "roster check exited $REPAIRED_EXIT_STATUS after the bundled writer repaired the region, expected 0"
  exit 1
fi

repaired_sha="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
if [ "$repaired_sha" != "$original_sha" ]; then
  fail "repaired definition bytes ($repaired_sha) do not match pre-drift snapshot ($original_sha)"
  exit 1
fi

# --- Assertion 8: the shell member owns the Claude settings file ---------
SHELL_DEFINITION="$STAGING/.claude/agents/code-audit-shell.md"
shell_entry_globs() {
  awk '
    /^  - name: code-audit-shell$/ { inside = 1; next }
    inside && /^  - name:/ { exit }
    inside && /^    globs:$/ { in_globs = 1; next }
    inside && in_globs && /^    [a-z_]+:/ { exit }
    inside && in_globs { print }
  ' "$1"
}
region_globs "$SHELL_DEFINITION" | grep -qxF ".claude/settings.json" \
  || { fail "the staged shell member's remit region does not name .claude/settings.json"; exit 1; }
shell_entry_globs "$ROSTER" | grep -qF '".claude/settings.json"' \
  || { fail "the staged roster's code-audit-shell entry does not grant .claude/settings.json"; exit 1; }

UNGRANTED_ROSTER="$STAGING/.gaia/audit-ci-ungranted.yml"
awk '
  /^  - name: code-audit-shell$/ { inside = 1 }
  inside && /^  - name:/ && !/code-audit-shell/ { inside = 0 }
  inside && $0 == "      - \".claude/settings.json\"" { next }
  { print }
' "$ROSTER" > "$UNGRANTED_ROSTER"
if cmp -s "$ROSTER" "$UNGRANTED_ROSTER"; then
  rm -f "$UNGRANTED_ROSTER"
  fail "could not remove the settings glob from the roster copy"
  exit 1
fi
UNGRANTED_EXIT_STATUS=0
bash "$CHECK" --root "$STAGING" --config "$UNGRANTED_ROSTER" >/dev/null 2>&1 || UNGRANTED_EXIT_STATUS=$?
rm -f "$UNGRANTED_ROSTER"
if [ "$UNGRANTED_EXIT_STATUS" -eq 0 ]; then
  fail "guard-can-fail: the roster check accepted a remit region naming .claude/settings.json the roster no longer grants"
  exit 1
fi

pass "remit invariant, roster shape, and writer repair all hold on the scrubbed adopter tree"
