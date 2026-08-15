#!/usr/bin/env bash
# shell-lint.sh: run shellcheck over every tracked shell script, bats suite, and
# husky hook, then four repo-authored guards shellcheck cannot model: the hook
# array-guard (.gaia/scripts/lint-hook-array-guard.sh), the git path-quoting
# guard (.gaia/scripts/lint-git-path-quoting.sh), the workflow
# run-interpolation guard (.gaia/scripts/lint-workflow-run-interpolation.sh),
# and the grep ERE-escape guard (.gaia/scripts/lint-grep-ere-escapes.sh).
# Exit 0 when clean, 1 on any finding at or above the severity floor.
# Run it directly from anywhere: `bash .gaia/tests/shell-lint.sh`.
#
# Maintainer-only. Adopters run GAIA's bash but never author it, so the linter
# guarding the framework's own shell has no adopter surface. Excluded from the
# release tarball by the `.gaia/tests` entry in `.gaia/release-exclude`.
#
# Why a gate and not just the audit agent: the code-audit-maintainer-shell agent
# already treats shellcheck as an authoritative oracle, but it is dispatched by a
# model and is advisory-only, so nothing *enforces* a clean tree. Hand-applied
# linting regresses silently. This is the deterministic backstop; the agent keeps
# the lenses shellcheck cannot model (hook fail-open, stdin-JSON shape,
# `jq -n` injection safety).
#
# Two severity floors over three discovery passes, because the file types carry
# different noise profiles:
#
#   *.sh   -> `style`, the strictest floor. The genuine style/info-tier codes are
#            curated: SC1091/SC1090 (shellcheck cannot follow a dynamically
#            sourced path) are excluded below as pure tooling artifacts, and the
#            intentional single-quoted jq/awk programs (SC2016) carry file-level
#            `# shellcheck disable=SC2016` directives, so the gate stays live to a
#            genuine SC2016 bug in any file that does not opt out.
#
#   .husky/* -> `style` as well, but linted as POSIX `sh` in a pass of its own.
#            The hooks are extensionless, so no glob above reaches them, and
#            husky runs each one as `sh -e`, so bash-only constructs must fail
#            here even though they pass in the *.sh pass.
#
#   *.bats -> `warning`. Errors and warnings are the tiers with live failure
#            modes (a masked `!` assertion that never fails a test [SC2314], a
#            `local x=$(...)` that swallows the command's exit [SC2155], a `cd`
#            with no `|| exit` guard [SC2164]). The `info`/`style` tiers on bats
#            are dominated by structural false positives from the bats execution
#            model (SC2317 unreachable `@test`/`setup`/`teardown` bodies,
#            SC2030/SC2031 subshell state from `run`, SC2016 assertion strings);
#            those sit below the `warning` floor and never fire, so bats needs no
#            blunt per-code exclude list. Run `shellcheck -S style <file>` by hand
#            to see the sub-floor tiers.
#
# Never begin a comment line with the bare word `shellcheck`: a comment of that
# shape is parsed as a directive, and a malformed one (SC1072/SC1073) aborts the
# parse of the whole file, silently leaving it unlinted. Write "Run shellcheck
# ..." or "The shellcheck binary ..." instead. Two lines in this very file tripped
# that trap on the gate's first CI run.
#
# Prerequisites:
#   the shellcheck binary on PATH; install via:
#     brew install shellcheck          (macOS)
#     https://github.com/koalaman/shellcheck/releases  (pinned tarball, as CI does)
#
# CI: .github/workflows/shell-lint.yml
set -euo pipefail

# Per-file-type severity floors (see the block above). *.sh is held to the
# strictest `style` tier; *.bats joins at `warning`, where the structural bats
# false positives sit below the floor.
SH_SEVERITY=style
BATS_SEVERITY=warning

# Tooling-artifact codes disabled for every pass: SC1091/SC1090 are "shellcheck
# cannot resolve a sourced path computed at runtime", which carries no failure
# mode and fires across the tree wherever a script sources a sibling by a derived
# path. Passed on the command line rather than a repo-root .shellcheckrc, so this
# config stays inside the maintainer-only gate and never ships to adopters as a
# newly-distributed file.
TOOLING_EXCLUDE=SC1091,SC1090

# Pin the linter version so the gate's verdict cannot depend on which machine ran
# it. Ubuntu's apt ships 0.9.0 while Homebrew ships newer, and their directive
# parsers disagree: 0.9.0 flags a comment beginning with whitespace + the word
# `shellcheck` and 0.11.0 does not, so this script passed locally and failed in CI
# on its own first run. CI installs exactly this version; a local mismatch warns
# rather than blocks, because CI is the authority.
SHELLCHECK_PIN=0.11.0

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"

echo "==> .gaia/tests/shell-lint.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "ERROR: shellcheck not found on PATH. Install it first:" >&2
  echo "  brew install shellcheck        (macOS)" >&2
  echo "  apt-get install -y shellcheck  (Debian/Ubuntu)" >&2
  exit 1
fi

have_version="$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')"
if [ -n "$have_version" ] && [ "$have_version" != "$SHELLCHECK_PIN" ]; then
  echo "WARN: local shellcheck is $have_version but CI pins $SHELLCHECK_PIN;" >&2
  echo "      verdicts can differ between versions. CI is the authority." >&2
fi

# Tracked files only. Worktrees under .claude/worktrees/ are untracked checkouts
# of these same scripts, so `git ls-files` never double-counts them.
#
# Collected with a read loop rather than `mapfile`: mapfile is bash 4+, and these
# scripts are authored and run on stock macOS /bin/bash (3.2.57).
#
# NUL-delimited, because under git's default `core.quotePath` a tracked path
# carrying a non-ASCII byte prints C-quoted (`"caf\303\251.sh"`). The quoted
# form fails the `[ -f ]` test every consumer applies and is dropped silently,
# so the pass reports clean having never opened the file. The empty-set guard
# below cannot catch that: the other files match normally, so the set is not
# empty. `.gaia/scripts/lint-git-path-quoting.sh` is the check that keeps this
# whole family quoted.
sh_scripts=()
while IFS= read -r -d '' f; do
  sh_scripts+=("$f")
done < <(git -C "$REPO_ROOT" -c core.quotepath=false ls-files -z '*.sh')

bats_scripts=()
while IFS= read -r -d '' f; do
  bats_scripts+=("$f")
done < <(git -C "$REPO_ROOT" -c core.quotepath=false ls-files -z '*.bats')

husky_hooks=()
while IFS= read -r -d '' f; do
  husky_hooks+=("$f")
done < <(git -C "$REPO_ROOT" -c core.quotepath=false ls-files -z '.husky/*')

# Guard the expansion below: on bash 3.2 a bare "${sh_scripts[@]}" over an EMPTY
# array aborts with `unbound variable` under `set -u`. An empty *.sh result also
# means the glob or the repo root resolved wrong, which should fail loudly, not
# lint nothing and report success. The *.bats set is allowed to be empty and is
# simply skipped; only the always-present *.sh set is a hard precondition.
if [ "${#sh_scripts[@]}" -eq 0 ]; then
  echo "ERROR: no tracked *.sh files found under $REPO_ROOT" >&2
  exit 1
fi

# Concurrent shellcheck workers. One shellcheck invocation is single-threaded and
# CPU-bound, so a pass costs the whole file list on one core; splitting the list
# across workers costs the longest chunk. Capped rather than set to the core
# count: on a 12-core machine 6 workers lint the tree in ~8.0s and 12 in ~6.6s,
# so the last doubling buys under two seconds for twice the resident shellcheck
# processes. `getconf _NPROCESSORS_ONLN` is the portable count -- macOS has no
# `nproc` and the CI image has no `sysctl -n hw.ncpu` -- and a machine that
# answers with nothing or with non-digits falls back to 2 rather than failing.
JOBS_CAP=6
detect_jobs() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  case "$n" in
    '' | *[!0-9]*) n=2 ;;
  esac
  if [ "$n" -lt 1 ]; then
    n=1
  fi
  if [ "$n" -gt "$JOBS_CAP" ]; then
    n="$JOBS_CAP"
  fi
  printf '%s\n' "$n"
}
JOBS="$(detect_jobs)"

# Per-worker logs. Removed on every exit path, including the failing one.
LINT_TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/shell-lint.XXXXXX")"
trap 'rm -rf "$LINT_TMP"' EXIT

# Run one shellcheck pass over a file list, split across $JOBS concurrent
# workers. Same fork/log/replay shape as .gaia/tests/run-bats-parallel.sh, and
# for the same reason: concurrent workers cannot write to a shared stdout, or
# findings from different chunks interleave differently on every run. Each
# worker buffers to its own log; the logs replay after every worker is waited
# on. The split is contiguous rather than round-robin so findings replay in the
# same file order one serial invocation over the whole list prints them in. The
# one divergence is cosmetic: shellcheck's trailing `For more information:`
# wiki-link block is per invocation, so a run with findings in more than one
# chunk prints that block more than once.
#
# Args: <slug> <severity> <file>...
# Every pass split this way lets shellcheck read each file's own shebang, so
# there is no dialect argument; the husky pass, which needs an explicit `-s sh`,
# lints a single file and stays serial.
# Returns 0 only when every worker exited 0. A worker's status is collected per
# pid: a bare `wait` returns the last job's status only and would green a
# finding in any other chunk.
run_shellcheck_pass() {
  local slug severity
  slug="$1"
  severity="$2"
  shift 2

  local files
  files=("$@")

  local total workers base rem w start len pids rc worker_rc log
  total="${#files[@]}"
  workers="$JOBS"
  if [ "$workers" -gt "$total" ]; then
    workers="$total"
  fi
  base=$((total / workers))
  rem=$((total % workers))

  # Every worker index below $workers gets at least one file, so no chunk is
  # ever empty. An empty one would reach shellcheck as a bare invocation with no
  # file operands, which exits non-zero on usage -- loud, not lie-green.
  pids=()
  w=0
  while [ "$w" -lt "$workers" ]; do
    start=$((w * base))
    if [ "$w" -lt "$rem" ]; then
      start=$((start + w))
      len=$((base + 1))
    else
      start=$((start + rem))
      len="$base"
    fi
    # Run from the repo root so the paths the linter prints are repo-relative.
    (
      cd "$REPO_ROOT" || exit 2
      shellcheck --severity="$severity" --exclude="$TOOLING_EXCLUDE" "${files[@]:$start:$len}"
    ) >"$LINT_TMP/$slug.$w.log" 2>&1 &
    pids+=("$!")
    w=$((w + 1))
  done

  rc=0
  w=0
  while [ "$w" -lt "$workers" ]; do
    worker_rc=0
    # `|| worker_rc=$?` rather than `if ! wait ...`, because inside an `if !`
    # body $? is the negated status (0), not the command's. Nothing aborts
    # early: every worker is waited on and every log replays even when the
    # first one failed.
    wait "${pids[$w]}" || worker_rc=$?
    if [ "$worker_rc" -ne 0 ]; then
      rc=1
    fi
    w=$((w + 1))
  done

  # Replay in worker order, never completion order.
  w=0
  while [ "$w" -lt "$workers" ]; do
    log="$LINT_TMP/$slug.$w.log"
    if [ -f "$log" ]; then
      cat "$log"
    else
      # A worker that produced no log ran no lint, so its files went unchecked.
      echo "ERROR: missing worker log $log" >&2
      rc=1
    fi
    w=$((w + 1))
  done

  return "$rc"
}

# Run every pass before failing, so one invocation reports every finding across
# all passes rather than hiding a later pass's findings behind an earlier one.
status=0

echo "--> shellcheck *.sh (severity=$SH_SEVERITY, jobs=$JOBS): ${#sh_scripts[@]} tracked scripts"
if ! run_shellcheck_pass sh "$SH_SEVERITY" ${sh_scripts[@]+"${sh_scripts[@]}"}; then
  status=1
fi

if [ "${#bats_scripts[@]}" -gt 0 ]; then
  echo "--> shellcheck *.bats (severity=$BATS_SEVERITY, jobs=$JOBS): ${#bats_scripts[@]} tracked suites"
  if ! run_shellcheck_pass bats "$BATS_SEVERITY" ${bats_scripts[@]+"${bats_scripts[@]}"}; then
    status=1
  fi
fi

# The husky hooks are extensionless, so they match neither glob above and would
# escape the gate entirely. `-s sh` is passed explicitly rather than left to the
# per-file directive: husky runs every hook as `sh -e`, so the dialect is a
# property of the directory, and a newly added hook is linted correctly whether
# or not its author remembered the directive. It has to be its own invocation
# because shellcheck takes one dialect per run.
if [ "${#husky_hooks[@]}" -gt 0 ]; then
  echo "--> shellcheck .husky/* (dialect=sh, severity=$SH_SEVERITY): ${#husky_hooks[@]} tracked hooks"
  if ! (cd "$REPO_ROOT" && shellcheck -s sh --severity="$SH_SEVERITY" --exclude="$TOOLING_EXCLUDE" ${husky_hooks[@]+"${husky_hooks[@]}"}); then
    status=1
  fi
fi

# Fold in the hook array-guard: shellcheck cannot model the bash-3.2.57
# empty-array abort -- a bare "${arr[@]}" over an EMPTY array aborts under
# `set -u`, exiting a hook before it can emit its deny JSON. Running it here
# means every shell-lint caller -- plan per-phase gates, the
# code-audit-maintainer-shell oracle, CI shell-lint.yml, and manual runs --
# enforces the class locally, not only the Audit CI Tests job. Run from
# the repo root so its cwd-relative .claude/hooks/*.sh scan resolves.
echo "--> lint-hook-array-guard (bash-3.2 empty-array class under set -u)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-hook-array-guard.sh"); then
  status=1
fi

# Fold in the git path-quoting guard, for the same reason as the array guard:
# the linter above cannot model it, and the class has been fixed seven times by
# hand and never once by a check. It reaches further than the passes above --
# its scan surface includes .github/workflows/*.yml, whose `run:` blocks are
# shell that no *.sh glob sees. It also guards this file's own three discovery
# loops above, which is how the class reached them in the first place. Run from
# the repo root so its own discovery resolves and the file:line it prints is
# repo-relative.
echo "--> lint-git-path-quoting (C-quoted paths from an unquoted diff or ls-files)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh"); then
  status=1
fi

# Fold in the workflow run-interpolation guard, for the same reason as the two
# above: shellcheck never sees this class at all. A `${{ }}` expression in a
# `run:` body is substituted into the script TEXT before bash parses it, so the
# hazard exists in the YAML layer that no shell linter reads -- shellcheck is
# handed the body only after the expression is already gone. Run from the repo
# root so its `git ls-files` resolves and the file:line it prints is
# repo-relative.
echo "--> lint-workflow-run-interpolation (\${{ }} substituted into run: script text)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-workflow-run-interpolation.sh"); then
  status=1
fi

# Fold in the grep ERE-escape guard, for the same reason as the three above:
# the linter above models the shell AROUND a regex and never the regex itself.
# POSIX leaves a backslash before a letter undefined in an ERE, and BSD grep
# (macOS) expands `\r` `\t` `\d` where GNU grep (the runner) matches the bare
# letter, so a pattern authored and verified locally means something else in CI.
# That is the class this gate reaches that the passes above cannot: it is
# invisible to shellcheck, invisible to a suite run on the authoring platform,
# and it fails toward a check that quietly passes. Run from the repo root so its
# `git ls-files` discovery resolves and the file:line it prints is
# repo-relative.
echo "--> lint-grep-ere-escapes (BSD-vs-GNU regex escapes in a grep -E pattern)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh"); then
  status=1
fi

if [ "$status" -ne 0 ]; then
  echo "==> shell-lint FAILED" >&2
  exit 1
fi

echo "==> shell-lint passed"
