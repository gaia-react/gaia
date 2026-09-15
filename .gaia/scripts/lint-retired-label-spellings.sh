#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-retired-label-spellings.sh: fail when a label spelling the registry
# records as retired still occurs in the tracked tree. Exit 1 with a
# `file:line` report on any hit, exit 0 when clean, exit 2 on an environment
# error. Run it from the repository root:
# `bash .gaia/scripts/lint-retired-label-spellings.sh [<repo_root>]`.
#
# # What this replaces, and why a roster could not do it
#
# `.claude/skills/file-tech-debt/SKILL.md` ("Contract-preserve note") carries a
# bullet list of the files that read a GAIA label spelling, to be worked in
# lockstep with any rename. A list is the wrong shape for that job: the next
# consumer written against a label spelling is added to the tree, not to the
# list, and nothing reds. Its sibling paragraph, the key-format contract, had
# already moved to a search for the same reason.
#
# A derived roster was the obvious repair and it does not survive contact with
# the corpus. Deriving carriers by grepping the tree for each registry spelling
# returns ~200 files, because the spellings are ordinary vocabulary too:
# `tech-debt`, `in-progress` and `gaia-ci` each appear in scores of files that
# merely discuss the concept. Narrowing to the grammar
# `.gaia/cli/src/labels/check.ts` uses instead (a `--label` flag inside a `gh`
# invocation, plus three pinned forms) returns a set too narrow: it reaches
# neither `.gaia/cli/src/labels/registry.ts`'s bare namespace-prefix array nor
# a `>`-quoted command in a runbook, two of the four carriers that were
# verifiably missing from the list. A roster built from either derivation would
# assert a completeness it does not have, which is the defect being fixed.
#
# So this gate arms the RENAME rather than the carrier set. The invariant needs
# no roster and no grammar: once the registry records a spelling in
# `renamedFrom`, that spelling must not occur anywhere in tracked source
# outside the historical and test surfaces below. It reaches carriers no
# extractor can enumerate, prose included, and it cannot go stale, because it
# reads the registry and the tree rather than a hand-kept list. The bullet list
# stays as annotation, saying which consumer breaks first and which fails open.
#
# The honest limit, stated rather than discovered later: a rename that never
# records `renamedFrom` is invisible here. That omission is already
# self-punishing, since `gaia labels sync` reads the same field to issue
# `gh label edit <old> --name <new>` and without it creates a second label
# instead of renaming the first.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-retired-label-spellings.bats, which the `Audit CI
# Tests` job runs, and run on every pull request as a member of
# .gaia/tests/whole-tree-invariants.sh. Also runnable directly:
# `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-retired-label-spellings.bats`.
# gaia:maintainer-only:end

set -euo pipefail

ROOT="${1:-}"

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel)"
fi

REGISTRY="$ROOT/.gaia/labels.json"

if [ ! -f "$REGISTRY" ]; then
  echo "lint-retired-label-spellings: ERROR: $REGISTRY not found" >&2
  exit 2
fi

# Every path whose job is to name a spelling after it stops being live. Each
# one is a deliberate record of the rename, not a carrier that was missed:
#
#   CHANGELOG.md            append-only; its old entries name the old spelling
#                           correctly, and the action-required note telling an
#                           adopter to migrate has to quote it.
#   wiki/log.md, wiki/hot.md, wiki/meta/
#                           the wiki's historical and audit surfaces, already
#                           exempt from the sibling prose audits.
#   .gaia/labels.json       the registry itself; `renamedFrom` IS the record.
#   .gaia/cli/gaia*         generated bundles whose literals are the source
#                           files' literals, already scanned.
#   tests                   a rename's own migration test drives the old
#                           spelling through the sync path on purpose.
#
# `CHANGELOG.md`, `wiki/log.md`, `wiki/hot.md`, `wiki/meta/` and the two bundles
# are the same entries `SCAN_EXCLUDED` carries in .gaia/cli/src/labels/check.ts,
# so the two label scans agree on what counts as a historical surface. The
# registry and the test entries are this scan's own; `SCAN_EXCLUDED`'s remaining
# entry, `.gaia/local/`, has no counterpart here because `git grep` walks only
# tracked paths and that tree is gitignored, so an entry for it could never
# change an outcome and no fixture could exercise it.
EXCLUDED_PATHSPECS=(
  ':!CHANGELOG.md'
  ':!wiki/log.md'
  ':!wiki/hot.md'
  ':!wiki/meta/'
  ':!.gaia/labels.json'
  ':!.gaia/cli/gaia'
  ':!.gaia/cli/gaia-maintainer'
  ':!*.bats'
  ':!*.test.ts'
  ':!*/__tests__/*'
  ':!.gaia/tests/'
  ':!.gaia/scripts/tests/'
)

if ! command -v jq >/dev/null 2>&1; then
  echo "lint-retired-label-spellings: ERROR: jq not found on PATH" >&2
  exit 2
fi

# The two derivations below land in files rather than in variables, because the
# framing byte is NUL and a command substitution cannot carry one: bash drops
# it, which is precisely the byte the framing depends on.
PAIRS_FILE="$(mktemp)"
PREFIXES_FILE="$(mktemp)"
trap 'rm -f "$PAIRS_FILE" "$PREFIXES_FILE"' EXIT

# Retired full spellings, as NUL-delimited `<old>` then `<new>` records. A name
# may be renamed more than once, so `renamedFrom` is flattened per entry rather
# than taken as a scalar.
#
# NUL rather than a tab or a line, and that is load-bearing rather than
# fastidious: jq's `@tsv` escapes a backslash, a tab and a newline, so a
# spelling carrying any of them would reach the scan LONGER than it left the
# registry, match no carrier, and let the run report clean on a rename that
# never completed. A NUL is the one byte a label name cannot contain, so the
# framing needs no escaping and nothing can be lengthened by it. This is the
# same fail-open direction the awk note further down describes, reached by a
# different route.
#
# The status is read explicitly rather than left to errexit: a malformed
# registry would otherwise abort carrying jq's own exit code, which a caller
# reads as neither a finding nor a clean run.
if ! jq -j '.labels[] | . as $entry | .renamedFrom[]? | ., "\u0000", $entry.name, "\u0000"' \
  "$REGISTRY" >"$PAIRS_FILE" 2>&1; then
  echo "lint-retired-label-spellings: ERROR: cannot read $REGISTRY:" >&2
  cat "$PAIRS_FILE" >&2
  exit 2
fi

# Retired NAMESPACE prefixes: a prefix that some retired spelling carried and
# no live name does. This is the arm a full-spelling scan cannot cover, because
# a prefix carrier holds the prefix alone: `.gaia/cli/src/labels/registry.ts`
# spells each governed namespace as a bare `<prefix>:`, which no search for a
# full name under that namespace reaches.
#
# A prefix that is still live is deliberately never searched, and the registry
# already carries that shape: a retirement can move one name out of a namespace
# while sibling names keep the namespace in service, and scanning for the
# prefix then would flag every live carrier.
#
# No retired spelling is written out in this file's own comments, deliberately.
# This gate reads the whole tree including itself, so an illustrative example
# naming a real one would be a finding, and self-exemption would leave the
# guard blind to instances of its own class. Describing the shape is what the
# sibling key-format contract in .claude/skills/file-tech-debt/SKILL.md
# prescribes for the same reason.
#
# Guarded on the same terms as the call above, and not merely for symmetry: an
# entry carrying a `renamedFrom` but no `name` parses fine, clears that call,
# and aborts this one, so the unguarded form would exit with jq's own code
# rather than the documented environment status.
if ! jq -j '
    ([.labels[].name | select(contains(":")) | sub(":.*$"; ":")] | unique) as $live
    | [.labels[] | .renamedFrom[]? | select(contains(":")) | sub(":.*$"; ":")]
    | unique
    | map(select(IN($live[]) | not))
    | .[]
    | ., "\u0000"
  ' "$REGISTRY" >"$PREFIXES_FILE" 2>&1; then
  echo "lint-retired-label-spellings: ERROR: cannot read $REGISTRY:" >&2
  cat "$PREFIXES_FILE" >&2
  exit 2
fi

if [ ! -s "$PAIRS_FILE" ] && [ ! -s "$PREFIXES_FILE" ]; then
  echo "lint-retired-label-spellings: no retired spellings recorded in .gaia/labels.json; nothing to scan" >&2
  exit 0
fi

# scan_term <term> <prefix-mode> <why>: print one `file:line: message` per
# occurrence of <term> that is a whole label spelling rather than a fragment of
# a longer one.
#
# The boundary test exists because a rename can leave the old spelling as a
# PREFIX of the new one -- retiring `in-progress` in favour of
# `in-progress-now` would otherwise make every live carrier a finding and the
# gate un-greenable. Membership is tested with awk's index() against a literal
# character set rather than with a regex, for the reason the sibling
# lint-shipped-issue-refs.sh states at length: a label name carries no
# guaranteed charset (GitHub permits spaces, and `good first issue` is in this
# registry), so building a pattern from one would need escaping that varies by
# awk implementation between a macOS checkout and the runner that gates the
# merge.
#
# <prefix-mode> `1` suppresses the RIGHT boundary test only. A namespace prefix
# is by definition followed by the rest of a name, so requiring a non-name
# character after it would match nothing.
scan_term() {
  local term="$1" prefix_mode="$2" why="$3"
  local files=() f

  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(git -C "$ROOT" grep -F -l -- "$term" \
    -- ${EXCLUDED_PATHSPECS[@]+"${EXCLUDED_PATHSPECS[@]}"} || true)

  if [ "${#files[@]}" -eq 0 ]; then
    return 0
  fi

  for f in ${files[@]+"${files[@]}"}; do
    # Every string that came from the registry or from git reaches awk through
    # the environment rather than through `-v`, which escape-processes its
    # value: `-v term='a\bc'` yields a 2-character term for a 3-character
    # spelling, `git grep -F` still returns the carrier file, and the awk pass
    # then matches nothing and the run reports clean. That is the fail-open
    # direction, and it is the same reason the boundary test below uses index()
    # against a literal set rather than a pattern built from the term.
    AWK_FILE="$f" AWK_TERM="$term" AWK_WHY="$why" \
    awk -v prefix_mode="$prefix_mode" '
      BEGIN {
        NAMECHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:._-"
        file = ENVIRON["AWK_FILE"]
        term = ENVIRON["AWK_TERM"]
        why  = ENVIRON["AWK_WHY"]
        tlen = length(term)
      }
      {
        pos = 1
        while (1) {
          k = index(substr($0, pos), term)
          if (k == 0) break
          start = pos + k - 1
          end = start + tlen - 1
          before = (start == 1) ? "" : substr($0, start - 1, 1)
          after  = (end >= length($0)) ? "" : substr($0, end + 1, 1)
          left_ok  = (before == "" || index(NAMECHARS, before) == 0)
          right_ok = (prefix_mode == "1" || after == "" || index(NAMECHARS, after) == 0)
          if (left_ok && right_ok) {
            printf "%s:%d: %s: %s\n", file, FNR, term, why
            break
          }
          pos = end + 1
        }
      }
    ' "$ROOT/$f"
  done
}

report=""

while IFS= read -r -d '' old && IFS= read -r -d '' new; do
  [ -n "$old" ] || continue
  hits="$(scan_term "$old" 0 "retired label spelling, renamed to \`$new\` in .gaia/labels.json; migrate this carrier")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done <"$PAIRS_FILE"

while IFS= read -r -d '' prefix; do
  [ -n "$prefix" ] || continue
  hits="$(scan_term "$prefix" 1 "retired label namespace prefix; no live entry in .gaia/labels.json carries it")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done <"$PREFIXES_FILE"

if [ -n "$report" ]; then
  printf '%s' "$report"
  echo "A rename is only complete once every carrier moves. See .claude/skills/file-tech-debt/SKILL.md (## Contract-preserve note) for which consumer breaks first." >&2
  exit 1
fi

echo "lint-retired-label-spellings: clean" >&2
exit 0
