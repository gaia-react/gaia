#!/usr/bin/env bash
# shellcheck shell=bash
#
# The other spelling of check-resolver-singleton.sh's (Check A's) defect.
# Check A catches a second named DEFINITION of the resolver; this one
# catches a hand-rolled main-root DERIVATION inlined into a
# consumer that declares no resolver function at all -- the same
# wrong-identity defect this whole program exists to end, spelled without
# ever writing `gaia_resolve_main_root` or `resolveMainWorktreeRoot`.
#
# Deliberately narrow, not the full "every hand-derivation shape" repo-wide
# scan the SPEC originally wanted (analysis/registry-design.md §0). That
# scan stays undeliverable: a real derivation is multi-line at nearly every
# site, which defeats a line-scoped detector, and the committed CLI bundles
# (.gaia/cli/gaia, .gaia/cli/gaia-maintainer) are esbuild output with
# comments stripped and identifiers renamed, so a source-form marker cannot
# reach them. This check instead targets three INGREDIENTS: substrings or
# short windows that are cheap to match on one line (or a two-line window),
# and that measurement against this repo's tracked source shows carry no
# legitimate use anywhere outside the resolver itself.
#
#   1. `--git-common-dir`. The literal git flag both canonical resolvers
#      hide behind (main-root-lib.sh in shell, state-file.ts in TypeScript).
#      Every other historical use in this repo was the pre-resolver idiom
#      `dirname(absolute(git rev-parse --git-common-dir))` -- still named in
#      a stale comment in token-rollup.sh describing what it used to do
#      before it delegated to the resolver, which is exactly the shape this
#      check exists to catch if it were ever live code again.
#   2. A `${var%...worktrees...}`-style parameter-expansion trim: string
#      surgery that peels a `.claude/worktrees/<name>` or `.git/worktrees/`
#      suffix off a path to recover main by hand. No legitimate call site
#      does this anywhere in tracked source -- the resolver reads
#      `core.worktree` from git's own config, never trims a path string.
#   3. `git worktree list --porcelain` piped directly into a first-record
#      reader (`head -1`, `head -n 1`, `sed -n '1p'`, `awk 'NR==1'`, and
#      close spellings) within two lines. Assumes the first porcelain
#      record is main, which happens to be true but is not how anything
#      else in this repo answers "where is main". The two real call sites
#      (.claude/hooks/local-janitor.sh) already resolve main FIRST via the
#      shared resolver and then parse the FULL porcelain stream through an
#      awk state machine, not a first-line grab, so this shape does not
#      false-fire on them.
#
# NOT covered, and known not to be:
#
#   `--show-toplevel` chained into a `dirname` walk. `--show-toplevel` alone
#   answers "which tree is THIS", a question dozens of legitimate call sites
#   ask every day (see check-resolver-singleton.sh's own docblock on
#   current-tree resolvers); `dirname` is one of the most common path
#   operations in the tree for reasons that have nothing to do with git. A
#   window scan over that pair would match real, unrelated code constantly.
#   This is exactly the multi-line, high-ambiguity shape that made the
#   SPEC's original repo-wide gate undeliverable, and it still is. Left to
#   review and the shell/frontend audit agents.
#
#   Parsing a `.git` FILE for its `gitdir:` line (a linked worktree's `.git`
#   is a one-line file naming the real git dir, not a directory). Zero
#   occurrences exist anywhere in tracked source to design a detector
#   against, and the literal string `gitdir:` already collides with
#   unrelated prose in this repo (a bats helper is named
#   `make_separate_gitdir`, matched by a naive substring scan) -- a check
#   with no real case to prove it right and a demonstrated false positive is
#   worse than the gap it would claim to close.
#
# How far this reaches, stated so the coverage is not overread. The scan
# itself is repo-wide over tracked source, but it only RUNS when the required
# `Audit CI Tests` job runs, and that job has a paths filter. The filter
# covers the surfaces where a derivation plausibly lands (.claude/hooks/**,
# .gaia/scripts/**, .gaia/statusline/**, .gaia/cli/src/**, .claude/settings.json
# among them). It does not cover app/**, which is why a derivation inlined
# into application code is caught by review rather than by this check: adding
# app/** would run this job on every application change to guard a shape that
# has never appeared there.
#
# Dual-mode, mirroring check-resolver-singleton.sh: source it for
# gaia_check_main_root_derivation, or run it directly as a script (see
# "Executable entry" at the bottom).
#
# gaia_check_main_root_derivation <repo_root>
#   Runs all three scans over tracked source. Prints every match line, then
#   one verdict line per scan. Returns 0 when all three are clean, 1
#   otherwise. <repo_root> is a required parameter -- this check never
#   derives it itself (mirrors check-resolver-singleton.sh: a CI caller
#   passes the plain checkout root, a bats fixture passes a temp repo).

# Shared exclusion pathspec for all three scans:
#   *.md                         prose (wiki, skills, agents) mentions these
#                                 flags descriptively; not executable source.
#   *.bats, */tests/*,
#   */__tests__/*, *.test.ts,
#   *.test.tsx                   test suites: a fixture that plants the
#                                 defect on purpose (to prove a check fires)
#                                 must not trip the real-source scan, same
#                                 exclusion check-resolver-singleton.sh uses.
#   the two resolver definitions themselves (main-root-lib.sh,
#     state-file.ts) -- they ARE the legitimate derivation.
#   the two committed CLI bundles -- esbuild output containing an inlined
#     copy of the resolver, not a second one; scanning them would fail this
#     check on every release, the same reasoning check-resolver-singleton.sh
#     documents for its own TypeScript pattern.
GAIA_MAIN_ROOT_DERIVATION_EXCLUDE=(
  ':!*.md'
  ':!*.bats'
  ':!*/tests/*'
  ':!*/__tests__/*'
  ':!*.test.ts'
  ':!*.test.tsx'
  ':!.gaia/scripts/main-root-lib.sh'
  ':!.gaia/cli/src/setup/util/state-file.ts'
  ':!.gaia/cli/gaia'
  ':!.gaia/cli/gaia-maintainer'
)

# Ingredient 2's pattern: a parameter-expansion trim (`%`) whose pattern
# mentions "worktrees" -- `${dir%/.git/worktrees/*}`,
# `${common%/worktrees/*}`, and close spellings all match.
GAIA_WORKTREES_SURGERY_PATTERN='\$\{[A-Za-z_][A-Za-z0-9_]*%[^}]*worktrees[^}]*\}'

# Ingredient 3's first-record-reader tokens, checked within a two-line
# window of a `worktree list --porcelain` match.
GAIA_PORCELAIN_FIRST_LINE_PATTERN='head[[:space:]]+(-n[[:space:]]*)?-?1\b|sed[[:space:]]+-n[[:space:]]+.?1p|awk[[:space:]].*NR==1'

# _gaia_strip_comment_matches: reads `file:line:content` lines on stdin
# (git grep's -n format) and drops any whose content is a comment line --
# shell (#), JS/TS line (//), or block-comment continuation (/* or *) --
# after trimming leading whitespace. `sub` on a copy removes only the FIRST
# two colon-delimited fields (file, line), so a colon inside the content
# itself (a URL, a ternary) never shifts the boundary.
_gaia_strip_comment_matches() {
  awk -F: '
    {
      content = $0
      sub(/^[^:]*:[^:]*:/, "", content)
      trimmed = content
      sub(/^[[:space:]]+/, "", trimmed)
      if (trimmed !~ /^(#|\/\/|\/\*|\*)/) print
    }
  '
}

# _gaia_scan_git_common_dir <repo_root>: prints non-comment matches of the
# literal `--git-common-dir` outside the exclusion set above.
_gaia_scan_git_common_dir() {
  local repo_root="$1"
  git -C "$repo_root" grep -nF -- '--git-common-dir' -- . "${GAIA_MAIN_ROOT_DERIVATION_EXCLUDE[@]}" 2>/dev/null \
    | _gaia_strip_comment_matches
}

# _gaia_scan_worktrees_surgery <repo_root>: prints non-comment matches of
# the parameter-expansion trim pattern.
_gaia_scan_worktrees_surgery() {
  local repo_root="$1"
  git -C "$repo_root" grep -nE -- "$GAIA_WORKTREES_SURGERY_PATTERN" -- . "${GAIA_MAIN_ROOT_DERIVATION_EXCLUDE[@]}" 2>/dev/null \
    | _gaia_strip_comment_matches
}

# _gaia_scan_porcelain_first_line <repo_root>: for every `worktree list
# --porcelain` match, reads the matched line plus the two following lines
# FROM THE FILE ITSELF (not from git grep's own context format, which is
# awkward to re-split reliably) and prints the match when that window also
# contains a first-record-reader token. Covers both a same-line pipe and a
# short continuation.
_gaia_scan_porcelain_first_line() {
  local repo_root="$1"
  local matches
  matches="$(git -C "$repo_root" grep -n -- 'worktree list --porcelain' -- . "${GAIA_MAIN_ROOT_DERIVATION_EXCLUDE[@]}" 2>/dev/null)" \
    || return 0
  [ -n "$matches" ] || return 0

  local line file lineno window
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"
    lineno="${line#*:}"
    lineno="${lineno%%:*}"
    window="$(sed -n "${lineno},$((lineno + 2))p" "$repo_root/$file" 2>/dev/null)"
    if printf '%s\n' "$window" | grep -qE "$GAIA_PORCELAIN_FIRST_LINE_PATTERN"; then
      printf '%s\n' "$line"
    fi
  done <<< "$matches"
}

gaia_check_main_root_derivation() {
  local repo_root="${1:?gaia_check_main_root_derivation requires a repo_root argument}"
  local common_dir_failed=0 surgery_failed=0 porcelain_failed=0

  local common_dir_matches common_dir_count=0
  common_dir_matches="$(_gaia_scan_git_common_dir "$repo_root")"
  if [ -n "$common_dir_matches" ]; then
    printf '%s\n' "$common_dir_matches"
    common_dir_count="$(printf '%s\n' "$common_dir_matches" | wc -l | tr -d ' ')"
    common_dir_failed=1
  fi
  printf 'hand-rolled --git-common-dir uses outside the resolver: %s\n' "$common_dir_count"

  local surgery_matches surgery_count=0
  surgery_matches="$(_gaia_scan_worktrees_surgery "$repo_root")"
  if [ -n "$surgery_matches" ]; then
    printf '%s\n' "$surgery_matches"
    surgery_count="$(printf '%s\n' "$surgery_matches" | wc -l | tr -d ' ')"
    surgery_failed=1
  fi
  printf 'worktrees parameter-expansion string surgery found: %s\n' "$surgery_count"

  local porcelain_matches porcelain_count=0
  porcelain_matches="$(_gaia_scan_porcelain_first_line "$repo_root")"
  if [ -n "$porcelain_matches" ]; then
    printf '%s\n' "$porcelain_matches"
    porcelain_count="$(printf '%s\n' "$porcelain_matches" | wc -l | tr -d ' ')"
    porcelain_failed=1
  fi
  printf 'worktree list --porcelain piped to a first-record reader: %s\n' "$porcelain_count"

  [ "$common_dir_failed" -eq 0 ] && [ "$surgery_failed" -eq 0 ] && [ "$porcelain_failed" -eq 0 ]
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-main-root-derivation: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_main_root_derivation "$repo_root"
  exit $?
fi
