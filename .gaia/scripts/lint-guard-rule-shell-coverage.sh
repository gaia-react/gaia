#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-guard-rule-shell-coverage.sh: flag every tracked shell file that the
# guard and diagnostic rules do not reach. Exit 0 when every one of them is
# governed by both rules, 1 with a per-file report on any gap, 2 on the check's
# own failure, and 130 or 143 when a SIGINT or SIGTERM interrupts it (see the
# trap arms in main). Run it from anywhere:
# `bash .gaia/scripts/lint-guard-rule-shell-coverage.sh [<repo_root>]`.
#
# Two rules govern how shell is written in this repository:
#
#   .claude/rules/guards-must-fail.md        -- a guard must be able to go red
#   .claude/rules/partial-cause-reporting.md -- a message names every cause
#
# Each binds itself to the surfaces it governs with a `paths:` list, and a
# `paths:` glob loads the file carrying it and nothing else. So a shell family
# no glob names is a family whose author never sees either rule, and the absence
# is invisible from both sides: nothing in the directory names a rule, and
# neither rule names the surface it is missing.
#
# The third rule below is the maintainer-only pointer, which carries both rules
# to the release-excluded surfaces their own `paths:` cannot name (its own
# header states why those globs live there rather than in the shipped rules).
# It extends both, so a file it reaches is governed for the purposes of this
# check whichever of the two is being asked about.
#
# Why this exists as a gate rather than as care. The `paths:` lists were
# hand-kept, and a hand-kept list is itself the arming stage guards-must-fail.md
# warns about: it goes stale the moment a new shell directory appears, silently,
# and the staleness surfaces only when someone audits a script written without
# either rule in front of them. Issue #1701 is that failure observed twice over
# -- .specify/extensions/gaia/lib/ and .gaia/statusline/ had both sat outside
# both lists since they were created. This check is what makes the next such
# directory red on the pull request that adds it instead of on an audit round
# some months later.
#
# What was decided, and deliberately not decided, when this landed. The lists
# stay EXPLICIT globs rather than becoming a derived "every shipped shell
# surface" set. Derivation would collapse a distinction that is real and
# load-bearing: the shipped rules may only name paths an adopter's clone
# actually has, while the maintainer-only surfaces are named from the
# release-excluded pointer rule, and one derived list cannot be both. Keeping
# the globs explicit and ARMING them with this check gets the property the
# derivation was wanted for -- a new directory cannot go unnoticed -- without
# giving up the split.
#
# Scope is the tracked SHELL set, and shell is not the same question as the
# `.sh` extension. `.husky/pre-commit` is hand-written shell with no extension
# and no shebang, and it is a guard in exactly this rule's sense: its
# change-detection arms decide whether the Quality Gate floor runs at all, so
# its green is read as evidence. A discovery keyed on `*.sh` alone reports clean
# over a set that excludes it, which is the same false clean this check exists
# to end, one file type over. So discovery is `'*.sh'` plus `'.husky/*'`, the
# same two pathspecs .gaia/tests/shell-lint.sh already discovers through, rather
# than a second spelling of the same set.
#
# It is not every surface the two rules name. They also bind `**/*.bats`,
# `.playwright/**/*.ts` and `.github/workflows/**/*.yml`; `**/*.bats` reaches
# every tracked suite by construction, and the other two are a different
# question from the one #1701 asked. Widening this check to another file type
# means widening the `code:` filter in .github/workflows/audit-ci-tests.yml to
# match, for the reason that filter's own comments give: a filter narrower than
# the surface it arms greens a check that scanned nothing. That filter carries
# `**/*.sh` for this check today, and `.husky/**` for its own older reasons.
#
# There is no exclusion table, because as of this writing every tracked shell
# file is governed and an empty exclusion list is an escape hatch nobody needed
# yet. A future shell file that genuinely should not be governed by either rule
# is a decision worth writing down when it exists: add the exclusion here then,
# with its reason, the way .gaia/tests/whole-tree-invariants.sh records its own
# deliberate non-members.
#
# Fail-closed by construction, at each stage guards-must-fail.md names:
#   discovery -- an empty tracked shell set exits 2, never 0
#   arming    -- a rule file that is missing, or yields no globs, exits 2
#   match     -- a glob using syntax glob_to_ere does not model exits 2, naming
#                the construct, rather than quietly matching nothing
#
# Bash 3.2 compatible. Never `cd` (outside the argument-free root resolution).

set -uo pipefail

readonly PROG="lint-guard-rule-shell-coverage"

# The tracked-shell listing is staged through this file (see the discovery block
# in main). It is script-scoped, not local to main, so the EXIT arm installed
# beside the mktemp can still name it: that arm runs after a signal arm exits,
# with main's locals already out of reach, which would otherwise leave the file
# behind on exactly the interrupt the arms exist for.
LIST_FILE=''

# The rule set. GUARD_RULE and DIAGNOSTIC_RULE are the two shipped rules, each
# asked about independently; POINTER_RULE extends both.
readonly GUARD_RULE=".claude/rules/guards-must-fail.md"
readonly DIAGNOSTIC_RULE=".claude/rules/partial-cause-reporting.md"
readonly POINTER_RULE=".claude/rules/maintainers/guard-and-diagnostic-surfaces.md"

# read_paths_globs <repo_root> <rule-relative-path>
#
# Print the rule's `paths:` frontmatter globs, one per line. The grammar read
# here is the one the rule files actually use: a leading `---`, a `paths:` key,
# then one `  - '<glob>'` entry per line, terminated by the closing `---`.
# Anything else in the block is ignored rather than guessed at; a block that
# yields nothing is caught by the caller's arming check.
read_paths_globs() {
  local root="$1" rule="$2"
  awk '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---"  { exit }
    /^paths:[[:space:]]*$/ { in_paths = 1; next }
    in_paths && /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^["'\'']|["'\'']$/, "", line)
      if (line != "") print line
      next
    }
    in_paths && /^[^[:space:]]/ { in_paths = 0 }
  ' "$root/$rule"
}

# glob_to_ere <glob>
#
# Print the ERE matching the same paths as <glob>, anchored by the caller.
# Models exactly three wildcards -- `**/`, `*`, `?` -- and treats every other
# glob metacharacter as unmodeled. Unmodeled is an ERROR rather than a literal:
# a `{ts,tsx}` brace read as literal text matches nothing, which reads on this
# check's output as "every file in that surface is uncovered" if it fails loud
# and as "that surface is fine" if it fails quiet. Neither is a verdict worth
# printing, so the check refuses instead.
glob_to_ere() {
  local glob="$1"
  local out='' i=0 n=${#glob} c
  while [ "$i" -lt "$n" ]; do
    c=${glob:$i:1}
    case "$c" in
      '*')
        if [ "${glob:$((i + 1)):1}" = '*' ]; then
          # Only the `**/` form is modeled: it stands for zero or more leading
          # directory components, which is how every entry in the three rule
          # files uses it. A bare `**` not followed by `/` has no such reading.
          if [ "${glob:$((i + 2)):1}" = '/' ]; then
            out="$out(.*/)?"
            i=$((i + 3))
            continue
          fi
          printf '%s: unmodeled glob syntax in %s: "**" not followed by "/"\n' "$PROG" "$glob" >&2
          return 2
        fi
        out="${out}[^/]*"
        i=$((i + 1))
        ;;
      '?')
        out="${out}[^/]"
        i=$((i + 1))
        ;;
      '.')
        out="$out\\."
        i=$((i + 1))
        ;;
      '{' | '}' | '[' | ']' | '(' | ')' | '|' | '+' | '^' | '$' | \\ | '!')
        printf '%s: unmodeled glob syntax in %s: "%s". Teach glob_to_ere this construct rather than leaving it to match nothing.\n' \
          "$PROG" "$glob" "$c" >&2
        return 2
        ;;
      *)
        out="$out$c"
        i=$((i + 1))
        ;;
    esac
  done
  printf '%s' "$out"
}

# rule_ere <repo_root> <rule-relative-path>...
#
# Print one anchored ERE matching any path any of the named rules' globs match.
# Exits 2 through its caller when a rule is missing, yields no globs, or carries
# a glob glob_to_ere cannot model.
rule_ere() {
  local root="$1"
  shift
  local rule glob part alt='' count
  for rule in "$@"; do
    if [ ! -f "$root/$rule" ]; then
      printf '%s: rule file not found: %s\n' "$PROG" "$rule" >&2
      return 2
    fi
    count=0
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      part="$(glob_to_ere "$glob")" || return 2
      if [ -z "$alt" ]; then
        alt="$part"
      else
        alt="$alt|$part"
      fi
      count=$((count + 1))
    done <<EOF
$(read_paths_globs "$root" "$rule")
EOF
    # Arming, and counted PER RULE rather than over the union. A rule whose
    # frontmatter parsed to nothing would make every file it governs report as
    # uncovered, which reads as a finding and is really a broken parser against
    # a changed frontmatter grammar. Counting over the union would let a
    # partner rule's globs mask exactly that, since every union here pairs a
    # shipped rule with the pointer rule.
    if [ "$count" -eq 0 ]; then
      printf '%s: no paths globs parsed from: %s\n' "$PROG" "$rule" >&2
      return 2
    fi
  done
  printf '^(%s)$' "$alt"
}

main() {
  local root
  if [ "$#" -gt 1 ]; then
    printf '%s: too many arguments\n' "$PROG" >&2
    printf 'usage: bash .gaia/scripts/%s.sh [<repo_root>]\n' "$PROG" >&2
    return 2
  fi
  if [ "$#" -eq 1 ]; then
    root="$1"
    if [ ! -d "$root" ]; then
      printf '%s: not a directory: %s\n' "$PROG" "$root" >&2
      return 2
    fi
  else
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=''
    if [ -z "$root" ]; then
      printf '%s: not inside a git repository and no <repo_root> given\n' "$PROG" >&2
      return 2
    fi
  fi

  local guard_ere diagnostic_ere
  guard_ere="$(rule_ere "$root" "$GUARD_RULE" "$POINTER_RULE")" || return 2
  diagnostic_ere="$(rule_ere "$root" "$DIAGNOSTIC_RULE" "$POINTER_RULE")" || return 2

  # Discovery, NUL-delimited and staged through a file rather than a variable.
  # `-z` is what keeps a non-ASCII path readable: under git's default
  # core.quotePath a bare `ls-files` C-quotes one, and the quoted spelling would
  # match no rule glob and report as a finding. The file is what keeps git's own
  # exit status distinguishable from an empty result, which a pipeline or a
  # process substitution would merge into one unreadable answer -- a listing
  # that failed and a tree holding no shell are different conditions owed
  # different messages. The two pathspecs are the header's tracked-shell set.
  LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/$PROG.XXXXXX")" || {
    printf '%s: could not create a temporary file for the tracked shell listing\n' "$PROG" >&2
    return 2
  }
  # Three arms, not one shared arm. Bash resumes at the point of interruption
  # once a trapped signal handler returns, so a single `EXIT INT TERM` arm that
  # only unlinks the file leaves Ctrl-C removing the temp file and the check
  # running on to print its verdict as if uninterrupted, which is strictly worse
  # than the default disposition it replaced. The signal arms exit, and the EXIT
  # arm they fall into owns the removal.
  trap 'rm -f "$LIST_FILE"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! git -C "$root" ls-files -z -- '*.sh' '.husky/*' >"$LIST_FILE"; then
    printf '%s: could not list tracked shell in %s\n' "$PROG" "$root" >&2
    return 2
  fi
  # An empty set is never a clean tree here: this repository's shell is what the
  # check exists to cover, and a discovery that finds none of it would report
  # every rule fully armed having compared nothing.
  if [ ! -s "$LIST_FILE" ]; then
    printf '%s: discovery found no tracked shell under %s\n' "$PROG" "$root" >&2
    return 2
  fi

  local path missing findings=0
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    missing=''
    [[ $path =~ $guard_ere ]] || missing="$GUARD_RULE"
    if ! [[ $path =~ $diagnostic_ere ]]; then
      if [ -n "$missing" ]; then
        missing="$missing, $DIAGNOSTIC_RULE"
      else
        missing="$DIAGNOSTIC_RULE"
      fi
    fi
    [ -n "$missing" ] || continue
    if [ "$findings" -eq 0 ]; then
      printf '%s: tracked shell files no guard/diagnostic rule reaches:\n' "$PROG" >&2
    fi
    printf '  %s\n    unreached by: %s\n' "$path" "$missing" >&2
    findings=$((findings + 1))
  done <"$LIST_FILE"

  if [ "$findings" -gt 0 ]; then
    printf '\n%s: %d file(s) above are governed by neither author nor rule.\n' "$PROG" "$findings" >&2
    printf 'Add a glob covering them to the rule(s) named, or, for a release-excluded\n' >&2
    printf 'surface, to %s.\n' "$POINTER_RULE" >&2
    return 1
  fi
  printf '%s: clean\n' "$PROG"
  return 0
}

main "$@"
