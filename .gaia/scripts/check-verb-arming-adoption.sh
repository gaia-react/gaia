#!/usr/bin/env bash
# shellcheck shell=bash
#
# Adoption check for the shared verb-arming decision
# (.claude/hooks/lib/verb-arming.sh, .claude/hooks/lib/verb-arming-walk.sh).
#
# Nothing stops a twelfth hook from spelling its own start_re/sep_re pattern
# pair, or arming through a grep-based re-implementation instead of the
# shared function, or the set of adopting hooks from drifting away from the
# eleven SPEC-075 enumerates. This check makes all three machine-detectable,
# plus the two frozen contracts around the library itself: it is a singleton,
# and the one written exemption from its fail-closed default (README.md's
# `### Fail directions`) stays exactly one hook wide.
#
# Dual-mode, mirroring check-base-provenance-adoption.sh: source it for
# gaia_check_verb_arming_adoption, or run it directly as a script.
#
# gaia_check_verb_arming_adoption <repo_root>
#   Six assertions over tracked shell source (test suites excluded):
#     1. Exactly one definition each of gaia_verb_armed and
#        gaia_verb_arm_view exists.
#     2. Each enumerated hook references gaia_verb_armed.
#     3. No file outside the library defines start_re or sep_re.
#     4. No file arms through a grep invocation whose pattern operand
#        carries both a shell-separator alternation and an arming verb.
#     5. The registered hooks (.claude/settings.json) that reference
#        gaia_verb_armed equal exactly the eleven in assertion 2.
#     6. Every deny-capable hook denies when the library cannot be loaded,
#        except the one written exemption, which must still take the
#        fail-open direction and still be deny-capable elsewhere.
#   Prints one line per finding plus a verdict line per assertion. Returns 0
#   when all six hold, 1 when any does not. <repo_root> is a required
#   parameter -- this check never derives it itself, so a bats fixture can
#   drive it against a throwaway repo.

# Same anchoring discipline as check-base-provenance-adoption.sh's
# GAIA_PROVENANCE_DEF_PATTERN: the literal function name immediately followed
# by "()" (optional space before the parens), optionally preceded by
# `function`, anchored to the start of the line after optional indentation.
# That excludes a comment mention, an inline reference, a plain call, and a
# command substitution, while still matching the genuine definition.
GAIA_VERB_ARMED_DEF_PATTERN='^[[:space:]]*(function[[:space:]]+)?gaia_verb_armed[[:space:]]*\(\)'
GAIA_VERB_ARM_VIEW_DEF_PATTERN='^[[:space:]]*(function[[:space:]]+)?gaia_verb_arm_view[[:space:]]*\(\)'

# check-base-provenance-adoption.sh's own exclusions, verbatim (five
# pathspecs, not three): a canonical definition ships in source, never in a
# *.bats / tests/ / __tests__/ / *.test.* fixture built to prove this check
# fires.
GAIA_VERB_TEST_EXCLUDES=(':!*.bats' ':!*/tests/*' ':!*/__tests__/*' ':!*.test.ts' ':!*.test.tsx')

# The adopting hooks, in the order SPEC-075's plan README lists them.
GAIA_VERB_ADOPTING_HOOKS=(
  pr-merge-audit-check.sh
  worthiness-presence-check.sh
  audit-disposition-check.sh
  distribution-preflight-check.sh
  post-findings-block-on-merge.sh
  token-tally-git-op.sh
  token-tally-review.sh
  token-rollup-merge.sh
  issue-claim-release.sh
  debt-sentinel-touch.sh
  capture-gh-artifact.sh
)

# Case-sensitive, lowercase-only: the uppercase Python BLOCK_START_RE in
# .claude/hooks/block-invalid-yaml-write.sh is not a false positive.
GAIA_VERB_PRIVATE_PATTERN='^[[:space:]]*(start_re|sep_re)='
# The library itself composes start_re/sep_re as locals -- that is the one
# legitimate site, and it is excluded from assertion 3's scan rather than
# from the tracked-tree walk, so the exclusion is visible at the call site.
GAIA_VERB_LIB_FILE='.claude/hooks/lib/verb-arming.sh'

# Assertion 4's detection is a syntactic scan over a grep call's pattern
# operand, not a proof: it reads the first quoted argument on a line naming
# `grep` with an `-E` flag, and flags it when that argument's text carries
# both an arming verb (`gh` or `git`) and one of three shell-separator
# tokens (`&&`, `;`, `||`). A bare `|` is deliberately NOT one of the three:
# it is indistinguishable from ordinary ERE alternation (every anchor
# grep in this tree uses `(^|...)` or `(...|$)` for boundary matching, not
# for separator detection), and including it made this assertion false on
# the real tree (.claude/hooks/wiki-commit-nudge.sh's single-verb `git
# commit` detector). It also does not follow a pattern built in a variable
# (`grep -E "$name_re"` is invisible to it) and does not see a matcher
# spelled some other way (`[[ =~ ]]`, `awk`, `sed`). It is a tripwire for the
# obvious re-implementation of the shared library's own composed pattern,
# which needs multiple separator tokens together to mean what it means, not
# a proof that no re-implementation exists.
#
# Substring checks (awk index(), not a dynamic regexp): macOS's /usr/bin/awk
# rejects `\|\|` inside a -v-supplied ERE ("illegal primary in regular
# expression"), so the three separator tokens and two verb tokens are each
# tested with a literal index() lookup instead of one alternation pattern.
GAIA_VERB_GREP_IDIOM_VERB_1='gh'
GAIA_VERB_GREP_IDIOM_VERB_2='git'
GAIA_VERB_GREP_IDIOM_SEP_1='&&'
GAIA_VERB_GREP_IDIOM_SEP_2=';'
GAIA_VERB_GREP_IDIOM_SEP_3='||'

# The four deny-capable hooks (README.md's frozen table, "Can deny: yes"),
# and the anchors that tell fail-closed from fail-open apart. Every one of
# the three merge gates shares the same reason string, byte for byte except
# its leading label, which is why a literal substring anchors it rather than
# a per-hook one.
GAIA_VERB_DENY_CAPABLE_HOOKS=(
  pr-merge-audit-check.sh
  worthiness-presence-check.sh
  audit-disposition-check.sh
  distribution-preflight-check.sh
)
GAIA_VERB_FAIL_CLOSED_ANCHOR='cannot load the shared verb-arming decision'
GAIA_VERB_FAIL_OPEN_ANCHOR='type gaia_verb_armed >/dev/null 2>&1 || exit 0'
GAIA_VERB_DENY_SHAPE_ANCHOR='permissionDecision: "deny"'

# The one written exemption (audit finding COV-003, resolved by the
# maintainer at plan time). distribution-preflight-check.sh is deny-capable
# but exits 0 rather than denying when verb-arming.sh cannot be sourced,
# because its own header doctrine is that it fails open on every
# uncertainty and that .github/workflows/distribution-audit-pr.yml remains
# the authority -- a hook with that contract must not become the one guard
# that denies every Bash tool call on a corrupted checkout. This is the
# form check-base-provenance-adoption.sh uses for its own written
# exemptions: named here, with its reason, so a reader who greps this check
# finds the carve-out and why it exists. Any ADDITION to this array is a
# decision the SPEC has to record too, not a maintenance edit to make here
# alone.
GAIA_VERB_FAIL_OPEN_EXEMPT_HOOKS=(distribution-preflight-check.sh)

# _gaia_verb_is_exempt_fail_open <hook>: 0 iff <hook> is a written exemption.
_gaia_verb_is_exempt_fail_open() {
  local hook="$1" e
  for e in "${GAIA_VERB_FAIL_OPEN_EXEMPT_HOOKS[@]}"; do
    [ "$hook" = "$e" ] && return 0
  done
  return 1
}

# _gaia_verb_def_singleton <repo_root> <pattern> <label>: prints every
# matching definition line, then a verdict line. Returns 0 iff exactly one
# exists.
_gaia_verb_def_singleton() {
  local repo_root="$1" pattern="$2" label="$3" matches count=0
  # git grep exits 1 on zero matches, a normal outcome here (not an error),
  # so it is not run under -e and its status is discarded.
  matches="$(git -C "$repo_root" grep -nIE "$pattern" -- . "${GAIA_VERB_TEST_EXCLUDES[@]}" 2>/dev/null)"
  if [ -n "$matches" ]; then
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    printf '%s\n' "$matches"
  fi
  printf '%s definitions found: %s\n' "$label" "$count"
  [ "$count" -eq 1 ]
}

# _gaia_verb_adoption <repo_root>: assertion 2. Prints one verdict line per
# enumerated hook. Returns 0 iff every hook both exists and references
# gaia_verb_armed at least once.
_gaia_verb_adoption() {
  local repo_root="$1" hook path failed=0
  for hook in "${GAIA_VERB_ADOPTING_HOOKS[@]}"; do
    path=".claude/hooks/$hook"
    if [ ! -f "$repo_root/$path" ]; then
      printf '%s: MISSING (named consumer file not found)\n' "$path"
      failed=1
      continue
    fi
    if git -C "$repo_root" grep -qF 'gaia_verb_armed' -- "$path" 2>/dev/null; then
      printf '%s: adopted\n' "$path"
    else
      printf '%s: NOT adopted (no gaia_verb_armed reference)\n' "$path"
      failed=1
    fi
  done
  return "$failed"
}

# _gaia_verb_private_pattern_scan <repo_root>: assertion 3. Prints one line
# per offending file:line. Returns 0 iff no tracked shell file outside the
# library defines start_re or sep_re.
_gaia_verb_private_pattern_scan() {
  local repo_root="$1" matches filtered=0 line file
  matches="$(git -C "$repo_root" grep -nIE "$GAIA_VERB_PRIVATE_PATTERN" -- '*.sh' "${GAIA_VERB_TEST_EXCLUDES[@]}" 2>/dev/null)"
  [ -n "$matches" ] || { printf 'private start_re/sep_re pairs found: 0\n'; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"
    if [ "$file" = "$GAIA_VERB_LIB_FILE" ]; then
      continue
    fi
    printf '%s\n' "$line"
    filtered=1
  done <<EOF
$matches
EOF
  if [ "$filtered" -eq 1 ]; then
    printf 'private start_re/sep_re pairs found: yes (outside %s)\n' "$GAIA_VERB_LIB_FILE"
    return 1
  fi
  printf 'private start_re/sep_re pairs found: 0 (outside %s)\n' "$GAIA_VERB_LIB_FILE"
  return 0
}

# _gaia_verb_grep_idiom_hits <path>: prints "<line>:<text>" for each line in
# <path> naming grep with an -E-family flag whose first quoted argument
# carries both an arming verb and a separator-alternation token. See the
# header comment on GAIA_VERB_GREP_IDIOM_VERBS for the narrowing.
_gaia_verb_grep_idiom_hits() {
  local path="$1"
  [ -f "$path" ] || return 0
  awk \
    -v v1="$GAIA_VERB_GREP_IDIOM_VERB_1" -v v2="$GAIA_VERB_GREP_IDIOM_VERB_2" \
    -v s1="$GAIA_VERB_GREP_IDIOM_SEP_1" -v s2="$GAIA_VERB_GREP_IDIOM_SEP_2" -v s3="$GAIA_VERB_GREP_IDIOM_SEP_3" '
    function first_quoted(s,    dq, sq, rest, e) {
      dq = index(s, "\"")
      sq = index(s, "\x27")
      if (dq > 0 && (sq == 0 || dq < sq)) {
        rest = substr(s, dq + 1)
        e = index(rest, "\"")
        if (e == 0) return ""
        return substr(rest, 1, e - 1)
      } else if (sq > 0) {
        rest = substr(s, sq + 1)
        e = index(rest, "\x27")
        if (e == 0) return ""
        return substr(rest, 1, e - 1)
      }
      return ""
    }
    {
      gpos = index($0, "grep")
      if (gpos == 0) next
      after = substr($0, gpos)
      if (after !~ /-[A-Za-z]*E[A-Za-z]*/) next
      # The pattern operand is the first quoted argument AFTER the "grep"
      # token, not the first quote on the line: an earlier argument
      # (`grep -qE ... <<<"$cmd"` reversed as `printf ... | grep -qE ...`)
      # can quote something ahead of the grep invocation itself.
      q = first_quoted(after)
      if (q == "") next
      has_verb = (index(q, v1) > 0) || (index(q, v2) > 0)
      has_sep = (index(q, s1) > 0) || (index(q, s2) > 0) || (index(q, s3) > 0)
      if (has_verb && has_sep) print NR ":" $0
    }
  ' "$path"
}

# _gaia_verb_grep_idiom_scan <repo_root>: assertion 4. Prints one line per
# file carrying a hit. Returns 0 iff no tracked shell file does.
_gaia_verb_grep_idiom_scan() {
  local repo_root="$1" failed=0 file hits
  while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    hits="$(_gaia_verb_grep_idiom_hits "$repo_root/$file")"
    [ -n "$hits" ] || continue
    printf '%s:%s\n' "$file" "$hits"
    failed=1
  done < <(git -C "$repo_root" ls-files -z -- '*.sh' "${GAIA_VERB_TEST_EXCLUDES[@]}" 2>/dev/null)
  if [ "$failed" -eq 0 ]; then
    printf 'grep-based arming idiom found: 0\n'
  fi
  return "$failed"
}

# _gaia_verb_roster_drift <repo_root>: assertion 5. The registered hooks
# (.claude/settings.json) that reference gaia_verb_armed must equal exactly
# GAIA_VERB_ADOPTING_HOOKS, in both directions.
_gaia_verb_roster_drift() {
  local repo_root="$1" failed=0
  local settings="$repo_root/.claude/settings.json"
  command -v jq >/dev/null 2>&1 || { printf 'roster drift: jq not found\n'; return 1; }
  [ -f "$settings" ] || { printf 'roster drift: %s not found\n' "$settings"; return 1; }

  local registered adopting_registered='' enumerated='' h extra missing
  registered="$(jq -r '(.hooks // {}) | to_entries[]? | (.value // [])[]? | (.hooks // [])[]? | .command // empty' "$settings" 2>/dev/null \
    | grep -oE '\.claude/hooks/[A-Za-z0-9_.-]+\.sh' | LC_ALL=C sort -u)"

  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if git -C "$repo_root" grep -qF 'gaia_verb_armed' -- "$h" 2>/dev/null; then
      adopting_registered="$adopting_registered$h
"
    fi
  done <<EOF
$registered
EOF
  adopting_registered="$(printf '%s' "$adopting_registered" | LC_ALL=C sort -u)"

  for h in "${GAIA_VERB_ADOPTING_HOOKS[@]}"; do
    enumerated="$enumerated.claude/hooks/$h
"
  done
  enumerated="$(printf '%s' "$enumerated" | LC_ALL=C sort -u)"

  if [ "$adopting_registered" = "$enumerated" ]; then
    printf 'roster: registered adopters match the enumerated eleven\n'
    return 0
  fi

  extra="$(comm -23 <(printf '%s\n' "$adopting_registered") <(printf '%s\n' "$enumerated") 2>/dev/null | grep -v '^$' || true)"
  missing="$(comm -13 <(printf '%s\n' "$adopting_registered") <(printf '%s\n' "$enumerated") 2>/dev/null | grep -v '^$' || true)"
  if [ -n "$extra" ]; then
    printf 'roster: registered hook(s) adopt gaia_verb_armed but are not enumerated:\n%s\n' "$extra"
    failed=1
  fi
  if [ -n "$missing" ]; then
    printf 'roster: enumerated hook(s) no longer referenced by a registered hook:\n%s\n' "$missing"
    failed=1
  fi
  return "$failed"
}

# _gaia_verb_fail_direction <repo_root>: assertion 6. Every deny-capable
# hook denies on a missing library, except the one written exemption, which
# must still take the fail-open direction (never the deny anchor) and must
# still be deny-capable elsewhere in the file -- if it is not, the
# exemption itself is stale and this reds until a maintainer drops it.
_gaia_verb_fail_direction() {
  local repo_root="$1" failed=0 hook path
  for hook in "${GAIA_VERB_DENY_CAPABLE_HOOKS[@]}"; do
    path="$repo_root/.claude/hooks/$hook"
    if [ ! -f "$path" ]; then
      printf '%s: MISSING (named deny-capable hook not found)\n' "$hook"
      failed=1
      continue
    fi
    if _gaia_verb_is_exempt_fail_open "$hook"; then
      if ! grep -qF -- "$GAIA_VERB_FAIL_OPEN_ANCHOR" "$path"; then
        printf '%s: does not take the written fail-open exemption (expected: %s)\n' "$hook" "$GAIA_VERB_FAIL_OPEN_ANCHOR"
        failed=1
        continue
      fi
      if grep -qF -- "$GAIA_VERB_FAIL_CLOSED_ANCHOR" "$path"; then
        printf '%s: carries the fail-closed deny anchor even though it is the written fail-open exemption\n' "$hook"
        failed=1
        continue
      fi
      if ! grep -qF -- "$GAIA_VERB_DENY_SHAPE_ANCHOR" "$path"; then
        printf '%s: no longer deny-capable; the fail-open exemption is stale, drop it from GAIA_VERB_FAIL_OPEN_EXEMPT_HOOKS\n' "$hook"
        failed=1
        continue
      fi
      printf '%s: written fail-open exemption honored (still deny-capable elsewhere in the file)\n' "$hook"
    else
      if grep -qF -- "$GAIA_VERB_FAIL_CLOSED_ANCHOR" "$path"; then
        printf '%s: denies on a missing verb-arming library\n' "$hook"
      else
        printf '%s: does not deny on a missing verb-arming library, and carries no written exemption\n' "$hook"
        failed=1
      fi
    fi
  done
  return "$failed"
}

# gaia_check_verb_arming_adoption <repo_root>
gaia_check_verb_arming_adoption() {
  local repo_root="${1:?gaia_check_verb_arming_adoption requires a repo_root argument}"
  local singleton_failed=0 adoption_failed=0 pattern_failed=0
  local grepidiom_failed=0 roster_failed=0 faildir_failed=0

  printf -- '-- gaia_verb_armed singleton --\n'
  _gaia_verb_def_singleton "$repo_root" "$GAIA_VERB_ARMED_DEF_PATTERN" 'gaia_verb_armed' || singleton_failed=1

  printf -- '-- gaia_verb_arm_view singleton --\n'
  _gaia_verb_def_singleton "$repo_root" "$GAIA_VERB_ARM_VIEW_DEF_PATTERN" 'gaia_verb_arm_view' || singleton_failed=1

  printf -- '-- consumer adoption --\n'
  _gaia_verb_adoption "$repo_root" || adoption_failed=1

  printf -- '-- private pattern pair --\n'
  _gaia_verb_private_pattern_scan "$repo_root" || pattern_failed=1

  printf -- '-- grep-based arming idiom --\n'
  _gaia_verb_grep_idiom_scan "$repo_root" || grepidiom_failed=1

  printf -- '-- roster drift --\n'
  _gaia_verb_roster_drift "$repo_root" || roster_failed=1

  printf -- '-- fail direction / written exemption --\n'
  _gaia_verb_fail_direction "$repo_root" || faildir_failed=1

  [ "$singleton_failed" -eq 0 ] && [ "$adoption_failed" -eq 0 ] && [ "$pattern_failed" -eq 0 ] \
    && [ "$grepidiom_failed" -eq 0 ] && [ "$roster_failed" -eq 0 ] && [ "$faildir_failed" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-verb-arming-adoption: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_verb_arming_adoption "$repo_root"
  exit $?
fi
